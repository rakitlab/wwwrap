import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, downloads, integration, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("Umum")
        case .downloads: return L("Download")
        case .integration: return L("Integrasi")
        case .appearance: return L("Tampilan")
        case .about: return L("Tentang")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L("Folder simpan, saat login, tidur")
        case .downloads: return L("Koneksi, antrean, kecepatan")
        case .integration: return L("Ekstensi browser, clipboard")
        case .appearance: return L("Bahasa, tema, menu bar")
        case .about: return L("Versi dan update")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down.circle"
        case .integration: return "puzzlepiece.extension"
        case .appearance: return "circle.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var section: SettingsSection
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Pengaturan"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 56)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { item in
                        SettingsSidebarRow(section: item, selected: section == item,
                                           badge: item == .about && updates.availableVersion != nil) {
                            section = item
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.chrome)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(section.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if badge {
                    Circle().fill(Theme.blue).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Page

struct SettingsPage: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 56)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch section {
                    case .general: GeneralSettings()
                    case .downloads: DownloadSettings()
                    case .integration: IntegrationSettings()
                    case .appearance: AppearanceSettings()
                    case .about: AboutSettings()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows in one bordered card, like the steps card on the browser page.
struct SettingsGroup<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: title, detail: detail)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Label + explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if divider { Hairline().padding(.horizontal, 18) }
        }
    }
}

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// "−  value  +" in the app's bordered style; steps through a fixed list of values.
struct ValueStepper<Value: Equatable>: View {
    @Binding var value: Value
    let values: [Value]
    let label: (Value) -> String

    private var index: Int { values.firstIndex(of: value) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: 28, iconSize: 11))
                .disabled(index == 0)
            Text(label(value))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 76)
            Button { step(1) } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 28, iconSize: 11))
                .disabled(index == values.count - 1)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }

    private func step(_ delta: Int) {
        let next = min(values.count - 1, max(0, index + delta))
        value = values[next]
    }
}

/// The three speed presets as icon segments (downloads page, menu bar, settings).
struct SpeedModePicker: View {
    @EnvironmentObject private var manager: DownloadManager
    var compact = false
    /// Icons only, for narrow spots (the speed card on the downloads page).
    var iconsOnly = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SpeedMode.allCases) { mode in
                let isOn = manager.speedMode == mode
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol).font(.system(size: 12, weight: .medium))
                    if !iconsOnly {
                        Text(mode.label).font(.system(size: compact ? 12 : 12.5, weight: isOn ? .medium : .regular))
                    }
                }
                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: iconsOnly ? nil : .infinity)
                .frame(width: iconsOnly ? 32 : nil)
                .frame(height: compact ? 26 : 28)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.segmentThumb)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: ns)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { manager.speedMode = mode }
                }
                .help(tooltip(for: mode))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.segmentTrack))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private func tooltip(for mode: SpeedMode) -> String {
        let cap = manager.limit(for: mode)
        return cap == 0 ? L("%@ · tanpa batas kecepatan", mode.label)
            : L("%@ · maksimal %@ untuk semua download", mode.label, Format.speed(Double(cap)))
    }
}

enum SpeedPresets {
    /// KB/s values offered for the Hemat and Senyap caps.
    static let valuesKB: [Int] = [256, 512, 1024, 2048, 3072, 5120, 8192, 10240, 15360, 20480, 30720, 51200]

    static func label(_ kb: Int) -> String {
        if kb < 1024 { return "\(kb) KB/s" } // l10n-ignore
        let mb = Double(kb) / 1024
        return mb == mb.rounded() ? "\(Int(mb)) MB/s" : String(format: "%.1f MB/s", mb) // l10n-ignore
    }
}

// MARK: - Umum

private struct GeneralSettings: View {
    @EnvironmentObject private var manager: DownloadManager
    @ObservedObject private var login = LoginItem.shared
    @AppStorage(SettingsKey.folder) private var folder = ""
    @AppStorage(SettingsKey.useCategoryFolders) private var useCategoryFolders = true
    @AppStorage(SettingsKey.notify) private var notify = true
    @AppStorage(SettingsKey.preventSleep) private var preventSleep = true

    var body: some View {
        SettingsGroup(title: L("Simpan")) {
            SettingsRow(title: L("Folder download"), detail: manager.downloadFolder.path) {
                HStack(spacing: 8) {
                    Button(L("Buka")) { NSWorkspace.shared.open(manager.downloadFolder) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button(L("Pilih…"), action: chooseFolder)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsRow(title: L("Pisahkan per kategori"),
                        detail: L("Video, Musik, Dokumen, dan lainnya masuk ke subfolder masing-masing."),
                        divider: false) {
                SettingsToggle(isOn: $useCategoryFolders)
            }
        }

        SettingsGroup(title: L("Sistem")) {
            SettingsRow(title: L("Buka saat login"),
                        detail: login.needsApproval
                            ? L("Menunggu izin di System Settings › General › Login Items.")
                            : (login.lastError ?? L("wwwrap berjalan di latar saat Mac menyala, siap menerima download dari browser."))) {
                HStack(spacing: 8) {
                    if login.needsApproval {
                        Button(L("Buka System Settings")) { login.openSystemSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    SettingsToggle(isOn: Binding(get: { login.isEnabled || login.needsApproval },
                                                 set: { login.set($0) }))
                }
            }
            SettingsRow(title: L("Cegah Mac tidur saat mengunduh"),
                        detail: L("Layar tetap boleh mati. Kembali normal begitu semua download selesai.")) {
                SettingsToggle(isOn: $preventSleep)
                    .onChange(of: preventSleep) { _ in manager.refreshSystemActivity() }
            }
            SettingsRow(title: L("Notifikasi saat selesai"), detail: L("Tampilkan notifikasi macOS untuk setiap file yang selesai."),
                        divider: false) {
                SettingsToggle(isOn: $notify)
            }
        }
        .onAppear { login.refresh() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = manager.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Download

private struct DownloadSettings: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage(SettingsKey.connections) private var connections = 8
    @AppStorage(SettingsKey.autoScale) private var autoScale = true
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(SettingsKey.saverLimitKB) private var saverKB = SpeedMode.defaultSaverKB
    @AppStorage(SettingsKey.quietLimitKB) private var quietKB = SpeedMode.defaultQuietKB

    var body: some View {
        SettingsGroup(title: L("Koneksi")) {
            SettingsRow(title: L("Koneksi awal per file"),
                        detail: L("Berlaku untuk download berikutnya. 8 sudah cukup untuk kebanyakan server.")) {
                ValueStepper(value: $connections, values: Array(1...32)) { "\($0)" }
            }
            SettingsRow(title: L("Tambah koneksi otomatis"),
                        detail: L("Selama kecepatan masih naik, sampai 32 koneksi. Dilepas lagi kalau tidak menambah speed.")) {
                SettingsToggle(isOn: $autoScale)
            }
            SettingsRow(title: L("Download bersamaan"), detail: L("Sisanya menunggu di antrean."), divider: false) {
                ValueStepper(value: $maxConcurrent, values: Array(1...10)) { L("%ld file", $0) }
            }
        }

        SettingsGroup(title: L("Batas kecepatan"), detail: L("untuk semua download sekaligus")) {
            SettingsRow(title: L("Mode sekarang"),
                        detail: L("Bisa juga diganti dari halaman Download atau ikon menu bar.")) {
                SpeedModePicker()
                    .frame(width: 300)
            }
            SettingsRow(title: L("Hemat"), detail: L("Sisakan bandwidth untuk video call dan streaming.")) {
                ValueStepper(value: $saverKB, values: SpeedPresets.valuesKB, label: SpeedPresets.label)
                    .onChange(of: saverKB) { _ in manager.applySpeedLimit() }
            }
            SettingsRow(title: L("Senyap"), detail: L("Hampir tidak terasa, cocok saat meeting atau main game online."),
                        divider: false) {
                ValueStepper(value: $quietKB, values: SpeedPresets.valuesKB, label: SpeedPresets.label)
                    .onChange(of: quietKB) { _ in manager.applySpeedLimit() }
            }
        }
    }
}

// MARK: - Integrasi

private struct IntegrationSettings: View {
    @EnvironmentObject private var ui: UIState
    @ObservedObject private var server = LocalServer.shared
    @AppStorage(SettingsKey.monitorClipboard) private var monitorClipboard = true

    var body: some View {
        SettingsGroup(title: L("Ekstensi browser")) {
            SettingsRow(title: status.title, detail: status.detail) {
                Button(L("Panduan pasang")) { ui.page = .browser }
                    .buttonStyle(SecondaryButtonStyle())
            }
            SettingsRow(title: L("Server lokal"),
                        detail: server.isRunning
                            ? L("Menerima download dari ekstensi di 127.0.0.1:%@.", String(LocalServer.port))
                            : L("Tidak berjalan. Port %@ mungkin dipakai aplikasi lain.", String(LocalServer.port)),
                        divider: false) {
                Circle().fill(server.isRunning ? Theme.green : Theme.red).frame(width: 8, height: 8)
            }
        }

        SettingsGroup(title: L("Tanpa ekstensi")) {
            SettingsRow(title: L("Tawarkan download saat link disalin"),
                        detail: L("Berlaku di semua browser termasuk Safari, dan di app apa pun."),
                        divider: false) {
                SettingsToggle(isOn: $monitorClipboard)
                    .onChange(of: monitorClipboard) { ClipboardMonitor.shared.setEnabled($0) }
            }
        }
    }

    private var status: (title: String, detail: String) {
        if server.extensionConnected {
            return (L("Ekstensi terhubung") + (server.extensionBrowser.map { " · \($0)" } ?? ""),
                    L("Download di browser otomatis diambil alih wwwrap."))
        }
        return (L("Ekstensi belum terhubung"), L("Pasang untuk Chrome, Edge, Brave, Arc, Dia, atau Firefox."))
    }
}

// MARK: - Tampilan

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.themeMode) private var themeMode = ThemeMode.system.rawValue
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true
    @AppStorage(Lang.key) private var language = AppLanguage.system.rawValue

    var body: some View {
        SettingsGroup(title: L("Bahasa")) {
            SettingsRow(title: L("Bahasa aplikasi"),
                        detail: L("Ikut sistem memakai bahasa Indonesia kalau macOS berbahasa Indonesia, selain itu English. Berlaku juga untuk ekstensi browser."),
                        divider: false) {
                SegmentedSwitch(selection: Binding(get: { AppLanguage(rawValue: language) ?? .system },
                                                   set: { choose($0) }),
                                options: AppLanguage.allCases.map { ($0, $0.label) })
                    .frame(width: 300)
            }
        }

        SettingsGroup(title: L("Tema")) {
            SettingsRow(title: L("Tampilan"), detail: L("Ikut sistem berganti otomatis bersama mode gelap macOS."),
                        divider: false) {
                SegmentedSwitch(selection: Binding(get: { ThemeMode(rawValue: themeMode) ?? .system },
                                                   set: { themeMode = $0.rawValue; $0.apply() }),
                                options: ThemeMode.allCases.map { ($0, $0.label) })
                    .frame(width: 300)
            }
        }

        SettingsGroup(title: L("Menu bar")) {
            SettingsRow(title: L("Tampilkan ikon di menu bar"),
                        detail: L("Lihat progres, ganti mode kecepatan, dan jeda semua tanpa membuka jendela."),
                        divider: false) {
                SettingsToggle(isOn: $showMenuBar)
            }
        }
    }

    /// Every view is rebuilt with the new language (App's `.id`); the notification buttons
    /// are registered with the system, so they are re-registered here.
    @MainActor
    private func choose(_ choice: AppLanguage) {
        language = choice.rawValue
        LinkOffer.registerCategories()
    }
}

// MARK: - Tentang

private struct AboutSettings: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheck = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.primary)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.onPrimary))
            VStack(alignment: .leading, spacing: 4) {
                Text("wwwrap")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(L("Versi %@", updates.currentVersion) + (updates.currentBuild.isEmpty ? "" : " (\(updates.currentBuild))"))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }

        SettingsGroup(title: L("Update")) {
            SettingsRow(title: statusTitle, detail: statusDetail) {
                Button {
                    updates.check(force: true)
                } label: {
                    if updates.state == .checking {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text(L("Cek sekarang"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(updates.state == .checking)
            }
            if let version = updates.availableVersion {
                SettingsRow(title: L("Pasang versi %@", version), detail: installDetail) {
                    UpdateButton(version: version)
                }
                SettingsRow(title: L("Lewat Terminal"),
                            detail: L("Kalau update otomatis gagal, tempel perintah ini di Terminal.")) {
                    HStack(spacing: 8) {
                        Button(copied ? L("Tersalin") : L("Salin perintah")) {
                            updates.copyInstallCommand()
                            copied = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button(L("Halaman rilis")) { updates.openReleasesPage() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            SettingsRow(title: L("Cek update otomatis"), detail: L("Sekali sehari saat app dibuka."), divider: false) {
                SettingsToggle(isOn: $autoCheck)
            }
        }

        SettingsGroup(title: L("Tentang pengembang")) {
            SettingsRow(title: L("Dibuat oleh RakitLab"), detail: "rakitlab.space", divider: false) { // l10n-ignore
                Button(L("Kunjungi situs")) { NSWorkspace.shared.open(URL(string: "https://rakitlab.space")!) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var installDetail: String {
        if case .failed(let message) = updater.phase { return message }
        return L("Sekali klik: diunduh, dipasang, lalu app dibuka lagi. Download yang berjalan dilanjutkan.")
    }

    private var statusTitle: String {
        switch updates.state {
        case .idle: return L("Belum dicek")
        case .checking: return L("Mengecek…")
        case .upToDate: return L("Sudah versi terbaru")
        case .available(let v): return L("Versi %@ tersedia", v)
        case .failed(let message): return message
        }
    }

    private var statusDetail: String {
        guard let date = updates.lastChecked else { return L("Rilis baru diambil dari GitHub.") }
        return L("Terakhir dicek %@.", date.formatted(date: .omitted, time: .shortened))
    }
}
