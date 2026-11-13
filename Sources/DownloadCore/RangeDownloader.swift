import Foundation

/// Downloads one remote resource into one local file over parallel HTTP range requests.
///
/// Lifecycle
/// - `run()` performs the whole transfer and returns when every byte is on disk and synced.
/// - Pause = cancel the Task that runs `run()`. It throws `CancellationError`; read
///   `snapshot()` afterwards and pass it as `resumeFrom` to a new downloader later.
/// - Progress = poll `progress` (a lock-protected read; no callbacks, no main-thread hops
///   per chunk). Sample it at whatever rate the UI needs.
///
/// Concurrency model: a `TaskGroup` of N workers. Each worker loops
/// `claim → stream → reserve → pwrite → commit` until the scheduler runs out of work.
/// Workers that hit HTTP 429/503 while others are running leave the pool, so the
/// connection count adapts down to what the server tolerates.
public final class RangeDownloader: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Initial parallel connections for range-capable servers.
        public var connections = 8
        /// Measure throughput and add connections while it keeps improving (up to `maxConnections`).
        public var autoScale = true
        public var maxConnections = 32
        /// Measurement window for auto-scaling.
        public var scaleInterval: TimeInterval = 3
        /// Never split below this size: per-request overhead would dominate.
        public var minSplitSize: Int64 = 1 << 20
        /// Consecutive failures the last remaining worker tolerates before the download fails
        /// (about three minutes of exponential back-off at the default).
        public var maxConsecutiveFailures = 10
        /// After connections were shed, try adding one back this often (AIMD-style recovery).
        public var rampUpInterval: TimeInterval = 10
        public var requestTimeout: TimeInterval = 60
        /// Per-connection buffer limit before the network task is suspended.
        public var highWaterMark = 4 << 20
        /// Optional speed cap shared with other downloads (nil = unlimited).
        public var limiter: BandwidthLimiter?
        /// Optional cap for this download only (priority share and/or the user's per-file limit).
        /// Acquired before `limiter`, so a capped download never holds global budget while it waits.
        public var itemLimiter: BandwidthLimiter?

        public init() {}
    }

    public let request: RemoteRequest
    public let resource: RemoteResource
    public let fileURL: URL
    public let configuration: Configuration
    /// True when this run continues a previous one (file kept, not truncated).
    public let isResuming: Bool

    private let scheduler: SegmentScheduler
    private let workerCount: Int

    /// - Parameter resumeFrom: segments from a previous `snapshot()`. Ignored (fresh start)
    ///   when the server can't do ranges or the segments don't match the resource.
    public init(request: RemoteRequest,
                resource: RemoteResource,
                fileURL: URL,
                resumeFrom segments: [SegmentState]? = nil,
                configuration: Configuration = Configuration()) {
        self.request = request
        self.resource = resource
        self.fileURL = fileURL
        self.configuration = configuration

        let resumable = segments.map {
            resource.acceptsRanges && SegmentPlanner.isValidTiling($0, totalBytes: resource.totalBytes)
        } ?? false
        isResuming = resumable
        let plan = resumable ? segments! : SegmentPlanner.plan(totalBytes: resource.totalBytes,
                                                               acceptsRanges: resource.acceptsRanges,
                                                               connections: configuration.connections,
                                                               minSegmentSize: configuration.minSplitSize)
        workerCount = resource.acceptsRanges ? max(1, configuration.connections) : 1
        scheduler = SegmentScheduler(segments: plan, workers: workerCount,
                                     minSplitSize: configuration.minSplitSize)
    }

    public var progress: TransferProgress {
        let p = scheduler.progress
        return TransferProgress(downloadedBytes: p.downloaded,
                                totalBytes: resource.totalBytes,
                                activeConnections: p.connections)
    }

    public func snapshot() -> [SegmentState] { scheduler.snapshot() }

    public func run() async throws {
        let sink = try FileSink(url: fileURL,
                                expectedSize: resource.hasKnownLength ? resource.totalBytes : nil,
                                truncate: !isResuming)
        defer { sink.close() }

        if !scheduler.allDone {
            try await withThrowingTaskGroup(of: Child.self) { group in
                for _ in 0..<workerCount {
                    group.addTask { try await self.workerLoop(sink: sink); return .worker }
                }
                let supervise = resource.acceptsRanges && (workerCount > 1 || configuration.autoScale)
                if supervise {
                    group.addTask { try await self.tick(); return .tick }
                }
                // Supervisor: ends when the last worker leaves. On each tick it
                // 1) auto-scales connections while throughput improves, and
                // 2) adds back connections shed after 429/503 once the server has been quiet.
                var scaler = ConnectionAutoScaler(initial: workerCount,
                                                  maxConnections: configuration.autoScale ? configuration.maxConnections : workerCount)
                var lastBytes = scheduler.progress.downloaded
                var lastTick = Date()
                var lastRecovery = Date()
                while let child = try await group.next() {
                    if scheduler.activeWorkers == 0 {
                        group.cancelAll()
                        break
                    }
                    guard child == .tick else { continue }

                    let now = Date()
                    let bytes = scheduler.progress.downloaded
                    let throughput = Double(bytes - lastBytes) / max(0.001, now.timeIntervalSince(lastTick))
                    lastBytes = bytes
                    lastTick = now

                    let quiet = configuration.rampUpInterval * 2
                    if scheduler.recentlyYielded(within: quiet) { scaler.serverPushedBack() }
                    let canAdd = scheduler.activeWorkers >= scaler.target && scheduler.canScale(quietPeriod: quiet)
                    let delta = scaler.evaluate(throughput: throughput, canAdd: canAdd)
                    if delta < 0 {
                        scheduler.requestRetire(-delta)
                    }
                    for _ in 0..<max(0, delta) {
                        scheduler.registerWorker()
                        group.addTask { try await self.workerLoop(sink: sink); return .worker }
                    }

                    if now.timeIntervalSince(lastRecovery) >= configuration.rampUpInterval,
                       scheduler.shouldRampUp(target: scaler.target, quietPeriod: quiet) {
                        lastRecovery = now
                        scheduler.registerWorker()
                        group.addTask { try await self.workerLoop(sink: sink); return .worker }
                    }
                    group.addTask { try await self.tick(); return .tick }
                }
            }
        }
        try Task.checkCancellation()
        guard scheduler.allDone else { throw DownloadEngineError.prematureEnd }

        if !resource.hasKnownLength {
            try sink.truncate(to: scheduler.progress.downloaded)
        }
        try sink.synchronize()
    }

    private enum Child: Sendable { case worker, tick }
    private struct RetireSignal: Error {}

    private func tick() async throws {
        let interval = configuration.autoScale ? min(configuration.scaleInterval, configuration.rampUpInterval)
                                               : configuration.rampUpInterval
        try await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000))
    }

    // MARK: - Worker

    private func workerLoop(sink: FileSink) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            guard let claim = scheduler.claim() else { return }

            do {
                try await transfer(claim, sink: sink)
                scheduler.release(claim.id)
                failures = 0
            } catch is RetireSignal {
                scheduler.release(claim.id) // another worker continues this segment
                return
            } catch {
                // Without range support a retry re-sends from byte 0, so local progress must restart too.
                let restart = !resource.acceptsRanges
                if Task.isCancelled {
                    scheduler.release(claim.id, resetProgress: restart)
                    throw CancellationError()
                }
                let engineError = error as? DownloadEngineError
                // Server pushback (429/503) or refused/timed-out connections: shed this connection
                // while others are still making progress. The supervisor adds it back later.
                let shed = engineError?.isThrottle == true || error.isConnectionFailure
                if shed && resource.acceptsRanges {
                    if scheduler.releaseAndYield(claim.id) { return }
                } else {
                    scheduler.release(claim.id, resetProgress: restart)
                }

                let retryable = engineError?.isTransient ?? error.isTransientNetworkError
                failures += 1
                guard retryable, failures <= configuration.maxConsecutiveFailures else { throw error }
                try await Task.sleep(nanoseconds: Self.backoff(attempt: failures, throttled: engineError?.isThrottle ?? false))
            }
        }
    }

    /// Exponential backoff with jitter: 1, 2, 4, 8 s (throttled: 2, 4, 8, 16 s), capped.
    static func backoff(attempt: Int, throttled: Bool) -> UInt64 {
        let base = throttled ? 2.0 : 1.0
        let capped = min(throttled ? 30.0 : 15.0, base * pow(2, Double(attempt - 1)))
        let jittered = capped * Double.random(in: 0.8...1.2)
        return UInt64(jittered * 1_000_000_000)
    }

    private func transfer(_ claim: SegmentScheduler.Claim, sink: FileSink) async throws {
        var urlRequest = URLRequest(url: resource.finalURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: configuration.requestTimeout)
        HTTPHeaders.apply(request.headers, to: &urlRequest)
        let ranged = resource.acceptsRanges
        if ranged {
            let end = scheduler.end(of: claim.id)
            urlRequest.setValue("bytes=\(claim.offset)-\(end)", forHTTPHeaderField: "Range")
            if let validator = resource.validator {
                urlRequest.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }

        let stream = HTTPByteStream(request: urlRequest, timeout: configuration.requestTimeout,
                                    highWaterMark: configuration.highWaterMark)
        defer { stream.cancel() }

        for try await event in stream.events {
            switch event {
            case .response(let http):
                try validate(http, ranged: ranged)

            case .data(let data):
                let (offset, length) = scheduler.reserve(claim.id, count: data.count)
                if length > 0 {
                    try sink.write(data, count: length, at: offset)
                }
                let complete = scheduler.commit(claim.id, length: length)
                // Holding the acknowledgement back lets the stream's backpressure slow the socket.
                if let limiter = configuration.itemLimiter { try await limiter.acquire(data.count) }
                if let limiter = configuration.limiter { try await limiter.acquire(data.count) }
                stream.consumed(data.count)
                if !complete, length == data.count, scheduler.consumeRetire() { throw RetireSignal() }
                // Done, or another worker stole the rest of this segment.
                if complete || length < data.count { return }
            }
        }

        try Task.checkCancellation()
        if !scheduler.isDone(claim.id) {
            if !ranged && scheduler.end(of: claim.id) < 0 {
                scheduler.finishUnknownLength(claim.id) // streamed body of unknown length ended cleanly
                return
            }
            throw DownloadEngineError.prematureEnd
        }
    }

    private func validate(_ http: HTTPURLResponse, ranged: Bool) throws {
        switch http.statusCode {
        case 206 where ranged, 200 where !ranged:
            return
        case 200:
            // Range ignored. With If-Range this means the file changed; without, the server regressed.
            throw resource.validator != nil ? DownloadEngineError.remoteChanged : DownloadEngineError.rangeNotHonored
        case 416:
            throw DownloadEngineError.remoteChanged
        case 429, 503:
            throw DownloadEngineError.throttled(http.statusCode)
        default:
            throw DownloadEngineError.httpStatus(http.statusCode)
        }
    }
}

extension DownloadEngineError {
    var isThrottle: Bool {
        if case .throttled = self { return true }
        return false
    }
}
