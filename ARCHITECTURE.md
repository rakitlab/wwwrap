# wwwrap architecture

## Layout

```
Package.swift                     SwiftPM: DownloadCore (library) + wwwrap (app) + tests
Sources/
  DownloadCore/                   UI-free engine. No AppKit/SwiftUI. Unit-testable.
    Models.swift                  SegmentState, RemoteRequest, RemoteResource, TransferProgress
    Errors.swift                  DownloadEngineError + transient/connection-failure classification
    HTTPHeaders.swift             Header hygiene (CR/LF stripping, reserved headers, identity encoding)
    ResourceProber.swift          Range probe (GET bytes=0-0) + per-transfer URLSession configuration
    SegmentPlanner.swift          Initial split + resume-data validation
    SegmentScheduler.swift        Work-stealing scheduler (reserve/commit, split, yield, ramp-up)
    FileSink.swift                F_PREALLOCATE + ftruncate + concurrent pwrite at offsets
    HTTPByteStream.swift          URLSession delegate → AsyncThrowingStream<Data> with backpressure
    RangeDownloader.swift         TaskGroup coordinator: workers + supervisor
  wwwrap/
    App/                          @main, scenes (window, Settings, MenuBarExtra), CI snapshot hooks
    Downloads/                    DownloadManager (queue, persistence, sampling), DownloadItem
    Ingest/                       DownloadRequest + DownloadDispatching, LocalServer (Chromium bridge)
    System/                       SystemActivity (IOKit sleep assertion, App Nap)
    UI/                           SwiftUI views
Tests/DownloadCoreTests/          Unit tests + end-to-end tests against LocalRangeServer
ChromeExtension/                  MV3 extension (talks to LocalServer on 127.0.0.1:9614)
scripts/build_app.sh              Universal build → .app → .dmg (used by CI)
```

The rule: **DownloadCore knows nothing about the app**, and the app talks to the engine through
four calls: `ResourceProber.probe`, `RangeDownloader.init(... resumeFrom:)`, `run()`
(cancel the Task to pause), and `progress` / `snapshot()`.

## Data flow

```
Add sheet / drag & drop / menu bar ─┐
Chromium extension → LocalServer ───┼─► DownloadRequest ─► DownloadDispatching.enqueue
(future) Native Messaging host ─────┤                         (DownloadManager, @MainActor)
(future) Safari Web Extension ──────┘                                   │
                                                                         ▼
                        ResourceProber.probe ─► plan destination (X.ext.mdownload)
                                                                         │
                                RangeDownloader.run()  (cooperative pool, off main)
                                   ├─ worker × N: claim → HTTPByteStream → reserve → pwrite → commit
                                   └─ supervisor: ends when workers finish, ramps connections back up
                                                                         │
                         fsync → rename .mdownload → final name → notify
```

## Engine design decisions

| Decision | Why |
|---|---|
| One `URLSession` (ephemeral, 1 conn/host) **per range request** | A shared session multiplexes all ranges for an HTTP/2 host onto one TCP connection, so N "connections" would share one congestion window and give no speed-up. |
| Delegate API bridged to `AsyncThrowingStream<Data>` instead of `URLSession.bytes` | `AsyncBytes` iterates one byte at a time; at 100 MB/s that burns a core. Chunks of 16–512 KB give one `pwrite` per chunk. |
| Backpressure: suspend task above 4 MB buffered, resume below 1 MB | URLSession delegate delivery has no flow control; this bounds memory per connection if the disk stalls (e.g. external HDD). |
| `pwrite` at offsets into one file, `F_PREALLOCATE` + `ftruncate` up front | No part files and no merge copy (half the disk I/O, no 2× free space). Full disk fails immediately. macOS has no `posix_fallocate`. |
| Temp file next to the destination (`.mdownload`) | Completion is an atomic same-volume `rename`, not a copy. |
| `reserve` / `commit` counters in the scheduler | Splits use reserved bytes (safe against in-flight writes); persistence uses committed bytes only, so a snapshot can never claim bytes that aren't on disk. |
| Work stealing (split the back half of the largest in-flight segment) | Fast connections finish early and take over from slow ones, so the tail of the download isn't one slow connection. |
| `If-Range` with strong ETag / Last-Modified | A file that changed on the server is restarted, never spliced. |
| `Accept-Encoding: identity` | Otherwise gzip/br changes the meaning of Content-Length and byte ranges. |
| Shed a connection on 429/503/connect failure, add one back per quiet interval | AIMD-style: settles at what the server tolerates instead of failing or hammering. |
| Progress is polled, not pushed | Workers update a lock-protected counter; the UI samples at 2 Hz only while something is transferring. No per-chunk main-thread hops. |

## Speed limit

`BandwidthLimiter` (DownloadCore) is one GCRA token scheduler shared by every connection of every
download. A worker calls `acquire(bytes)` after writing a chunk but *before* acknowledging it to
`HTTPByteStream`; while it waits, the stream buffer fills, the URLSession task is suspended and the
TCP window closes, so the cap holds on the wire. Changing the cap bumps a generation counter that
releases current waiters within 0.25 s. The app maps three modes (Penuh/Hemat/Senyap) to caps
stored in UserDefaults.

### Priority and per-download caps (1.8)

Each running download also gets its own `BandwidthLimiter` (`Configuration.itemLimiter`), acquired
*before* the global one so a held-back download never sits on global budget. Twice a second
`DownloadManager.rebalance()` asks `PriorityAllocator` for each download's cap and applies it with
`retune` (changes the rate without releasing waiters, so frequent retuning can't skip the cap).

`PriorityAllocator`: weights high/normal/low = 3/2/1. Downloads of the highest priority present are
never capped by priority; each lower one is capped at its weighted share of the budget plus what the
others leave unused (so a slow server on the important download doesn't waste the line), moving 30 %
toward the target per update, never below 64 KB/s. Budget = the global limit, or else the highest
recent total speed (decaying, ~70 s half-life). Same priority everywhere → no priority caps. The
user's per-file cap (`speedLimitKB`) always applies. The queue starts highest priority first, then
oldest; "Mulai sekarang" starts a download beyond the concurrent-download setting.

## Localization

Indonesian source text is the lookup key: `L("Batal")` returns the key itself in Indonesian
and `Strings.en["Batal"]` in English. `Strings.generated.swift` (app) and
`ChromeExtension/strings.js` (extension) are generated from `Localization/en.json` by
`scripts/l10n.py`, which also lints for unwrapped UI text, unused or missing entries and
mismatched format specifiers; CI fails on any of these. English plurals are `"one|other"`,
chosen by the first integer argument.

`Lang.code` reads UserDefaults (`appLanguage`: system/id/en) on every lookup, and the App
puts `.id(appLanguage)` on the window and menu bar roots, so a change rebuilds the views
without a restart. DownloadCore error messages go through `EngineLocalization.lookup`,
installed by the app at launch. The extension follows the app: `/hello` replies carry `lang`.
Installs from before 1.6 are pinned to Indonesian on first launch.

## Network outages

The engine retries each connection for about three minutes. A download that still fails with
a connectivity error (no route, DNS, dropped/timed-out connection) is marked
`waitingForNetwork` instead of failed; server-side hiccups (5xx, cut streams) get the same
treatment up to six times. `NetworkWatcher` then probes `captive.apple.com` (5 s, backing off
to 60 s) and resumes waiting items when it answers; each item also has its own backoff
(5 s → 5 min), reset whenever it made real progress. `NWPathMonitor` only triggers an
immediate probe when Wi-Fi/Ethernet returns: on Starlink the path stays "satisfied" while the
uplink is down, so the path alone can't be trusted.

## In-app update

`AppUpdater` downloads the release DMG with `RangeDownloader`, mounts it, checks bundle id,
version and `codesign --verify --deep --strict`, stages the new bundle next to the running one
(same volume) and starts a `/bin/sh` helper that waits for the app to exit, swaps the bundles
(keeping the old one until the new one is in place), clears quarantine and relaunches. IDs of
running downloads are saved and resumed after relaunch. CI exercises the whole path with
`-updateTestDMG`.

## Rename (1.7.0)

MacDownloader became wwwrap: bundle id `com.mubaroksn.wwwrap`, support folder
`~/Library/Application Support/wwwrap`. `LegacyMigration` copies the old defaults domain and
`downloads.json` on first launch (the old folder stays, since unpacked extensions load from it),
then quits and trashes the old app. The extension protocol (`X-MacDL-Client`, port 9614) and
the Firefox add-on id are unchanged so existing extensions keep working.

## Power

`SystemActivity` holds a `PreventUserIdleSystemSleep` IOKit assertion (display may still sleep)
and a `ProcessInfo` activity (opts out of App Nap) **only while a transfer is running**, and
releases both when the last one stops. CI verifies both states with `pmset -g assertions`.
The sampling timer has 200 ms tolerance and is invalidated when idle; the menu bar icon only
changes on state transitions.

## Browser integration roadmap

All entry points build a `DownloadRequest` and call `DownloadDispatching.enqueue`, so new sources
don't touch the queue.

- **Chromium (today):** MV3 extension → `POST 127.0.0.1:9614/add` → `LocalServer`.
- **Chromium Native Messaging (next):** a small command-line target speaking Chrome's
  4-byte-length-prefixed JSON over stdio, installed as
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/<name>.json`. It can forward
  to the running app over the existing localhost endpoint or an XPC service. Fits in SwiftPM as a
  second executable target, copied into `Contents/Helpers`.
- **Safari Web Extension:** requires an app extension (`.appex`) target, which SwiftPM cannot
  build. That is the point to move the app shell to an Xcode project (or XcodeGen/Tuist), keeping
  `DownloadCore` as a local Swift package. The extension's `SafariWebExtensionHandler` forwards to
  the app via an App Group container or XPC, creating `DownloadRequest(origin: .safariExtension)`.

## Testing

`swift test` runs on every CI build:

- Planner/scheduler/sink unit tests (tiling, stealing, reservation discard, yield rules, concurrent `pwrite`, disk-full).
- End-to-end against `LocalRangeServer` (real sockets): byte-exact parallel download with ≥ 4
  concurrent connections, pause/resume fetching only missing bytes, 429 throttling, ramp-up after
  recovery, no-range fallback, remote-change detection, probe failure.

CI then builds the universal app, runs a smoke test against a public server, captures UI
screenshots and checks the power assertion.
