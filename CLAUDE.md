# wwwrap (dulu MacDownloader) — handoff for Claude

Status per 18 Okt 2026. Pemilik: mubaroksn (berkomunikasi dalam bahasa Indonesia, santai; bukan engineer Swift — jelaskan hasil, bukan proses).

## Apa ini
Download manager ala IDM untuk macOS. Native Swift/SwiftUI, SwiftPM (tanpa .xcodeproj), macOS 13+, universal.
Repo: https://github.com/rakitlab/wwwrap (org perusahaan rakitlab; sebelumnya mubaroksn/wwwrap dan mubaroksn/MacDownloader — URL lama di-redirect GitHub, JANGAN buat repo baru bernama sama di akun lama) · Rilis terbaru: **v1.7.0**.
Detail arsitektur: `ARCHITECTURE.md`. Ringkasan pengguna: `README.md`.

## Yang sudah ada
- `Sources/DownloadCore` (engine tanpa UI): probe Range, TaskGroup workers, work-stealing scheduler,
  1 URLSession per range request (koneksi TCP terpisah), pwrite + F_PREALLOCATE, If-Range,
  shed koneksi saat 429/503, **auto-scale koneksi** (8 awal → maks 32, lepas lagi kalau tidak menambah speed),
  `LinkResolver` (Drive/Docs/Dropbox/GitHub/SharePoint/Pixeldrain + halaman virus-scan Drive, MediaFire),
  `DriveFolder` (folder Drive publik via `window['_DRIVE_ivd']`, diverifikasi Okt 2026; `embeddedfolderview` sudah mati).
- `Sources/wwwrap`: UI monokrom (rail, sidebar tree, kartu folder, tabel), menu bar, IOKit sleep assertion,
  clipboard monitor, ekstensi browser (pause → hand-off → resume kalau app menolak; heartbeat 30 dtk).
- Ekstensi: satu sumber `ChromeExtension/` untuk Chromium + Firefox; `scripts/build_extensions.sh` menurunkan manifest
  Firefox (event page, gecko id `macdownloader@mubaroksn.github.io`). CI menjalankan `web-ext lint` dan, saat rilis,
  `web-ext sign` (unlisted) **jika** secret `AMO_JWT_ISSUER`/`AMO_JWT_SECRET` ada → `.xpi` di Release.
- Distribusi: ad-hoc signed, tidak dinotarisasi. `install.sh` (curl → /Applications, tanpa karantina); versi terbaru via
  redirect `/releases/latest`, aset `wwwrap-<v>.dmg` (fallback `MacDownloader-<v>.dmg` untuk rilis < 1.7); memensiunkan
  MacDownloader.app lama ke Sampah. Update dalam app: `System/Updater.swift` (RangeDownloader → hdiutil → cek bundle id,
  versi, codesign → helper sh tukar bundle → relaunch, download aktif dilanjutkan). CI: `-updateTestDMG`.
- v1.5: `DashboardStrip`, mode kecepatan (`BandwidthLimiter`), Pengaturan di jendela utama (`UI/SettingsPage.swift`).
- v1.6: dua bahasa. Teks Indonesia = kunci `L("...")`/`t("...")`; kamus `Localization/en.json` → `python3 scripts/l10n.py`
  (generate + cek; CI gagal kalau ada teks tanpa terjemahan). Smoke test CI dipin `-appLanguage id`.
- Bundle id `com.mubaroksn.wwwrap` dan gecko id sengaja tetap memakai "mubaroksn" walau repo di org rakitlab.
- v1.7: rename → wwwrap (bundle id `com.mubaroksn.wwwrap`, folder `~/Library/Application Support/wwwrap`,
  `System/LegacyMigration.swift` menyalin defaults + downloads.json lama). Protokol ekstensi (`X-MacDL-Client`, port 9614)
  dan gecko id Firefox sengaja TIDAK diganti. Auto-lanjut saat internet putus: `Downloads/NetworkWatcher.swift`
  (`waitingForNetwork`, probe captive.apple.com — Starlink: Wi-Fi tetap "satisfied" walau uplink mati).
- `Sources/mdl-bench`: CLI benchmark throughput/CPU. `Tests/DownloadCoreTests`: 43 tes (server range lokal).

## Cara kerja dari sesi Claude (penting)
- Workspace Claude = Linux, **tidak bisa compile Swift**. Semua build/tes lewat GitHub Actions (macos-15; macos-14 sudah tidak didukung per Nov 2026).
- Log Actions & artifact **tidak bisa diunduh** dari proxy. Workflow sengaja menulis hasil sebagai **annotations**
  (`gh api repos/rakitlab/wwwrap/check-runs/<job>/annotations`) — error compiler, hasil tes, smoke test.
- Screenshot UI: step CI mem-push PNG ke branch `ci-screenshots` → `git fetch origin ci-screenshots`.
- Rilis: `gh api -X POST repos/rakitlab/wwwrap/actions/workflows/build.yml/dispatches -f ref=main -f 'inputs[release]=X.Y.Z'`
  (push tag diblokir proxy). PR/merge lewat REST (`gh api .../pulls`), GraphQL diblokir. Hapus branch tidak bisa.
- Alur biasa: branch → PR → CI hijau (tes + smoke + screenshot) → squash merge → dispatch rilis.
- Benchmark: push ke branch `perf-*` menjalankan `.github/workflows/bench.yml`.

## Konteks pengguna
- Browser: **Dia** (Chromium). Ekstensi sudah aktif dan bekerja. Internet: **Starlink ~200 Mbps**.
- Keluhan terakhir: ZIP folder Google Drive (`takeout-download…`) hanya ~4,3 MB/s (≈1 koneksi Starlink).
  Benchmark: engine sanggup 570–920 Mbps ke Google Drive di datacenter → batasnya server/jaringan, bukan engine.

## Terbuka / langkah berikutnya
1. Speed **link folder** Drive di Starlink: awal ~12 MB/s lalu turun ke 4-5 MB/s. Dugaan: 3 file paralel di awal,
   akhirnya tinggal 1 file besar. Menunggu link folder / screenshot (koneksi per baris, ukuran file) dari pengguna.
1b. Rilis masih tanpa `.xpi` bertanda tangan — pengguna belum memasang secret AMO. Setelah dipasang, rilis ulang.
3. Kandidat fitur: Native Messaging host (Chromium), Safari Web Extension (butuh migrasi ke Xcode project),
   video grabber (yt-dlp), jadwal + tidurkan Mac, ambil semua link dari halaman, deteksi duplikat,
   ekstensi di Chrome Web Store — sudah diusulkan, belum diminta.
3b. **Backlog dari feedback tester (Bilal, Okt 2026)** — sudah disetujui masuk backlog, belum dikerjakan:
   - Link yang tidak tertangkap ekstensi: tangkap via `downloads.onCreated` + `Content-Disposition`
     (bukan cuma klik link), drag-and-drop link ke ikon/jendela app.
   - In-app browser (WKWebView + `WKDownload`, cookie/login ikut) — kerjakan setelah poin di atas.
   - Batas: `blob:`, HLS/DASH, DRM tetap tidak bisa (wilayah video grabber).
   - Torrent: tidak direncanakan.
4. Branch sisa yang bisa dihapus pemilik: `probe-drive`, `perf-speed`, `engine-v2`, `drive-folders`.
