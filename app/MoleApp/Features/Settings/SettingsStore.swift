import AppKit
import Carbon.HIToolbox
import MoleKit
import Observation
import ServiceManagement
import SwiftUI

/// 设置页 Store（设计 §5.7）。通用/白名单/权限/高级/关于五分区。
///
/// 许可分区 v1 隐藏——设计文档 §5.7 明确许可证商业化开启后才出现。
///
/// 数据策略：
/// - 通用偏好落 UserDefaults（`settings.` 前缀），语言直接代理 L10n（免重启实时切换）。
/// - 开机自动启动以 SMAppService 状态为真相源，不落偏好。
/// - 外观（恒 dark）与缓存删除方式（恒 trash）为锁定态，不落偏好。
/// - 白名单经 robot `whitelist` 域读写；清理 / 优化两套独立配置。
@Observable
@MainActor
final class SettingsStore {
    enum Section: String, CaseIterable, Identifiable {
        case general, whitelist, permissions, advanced, about
        var id: String {
            rawValue
        }
    }

    /// 刷新频率（秒）。
    enum RefreshInterval: Int, CaseIterable, Identifiable {
        case one = 1, two = 2, five = 5
        var id: Int {
            rawValue
        }
    }

    /// 温度单位。
    enum TemperatureUnit: String, CaseIterable, Identifiable {
        case auto, celsius, fahrenheit
        var id: String {
            rawValue
        }
    }

    /// 白名单加载态。
    enum WhitelistPhase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    var section: Section = .general

    // MARK: - 通用偏好（UserDefaults, settings. 前缀）

    private let defaults = UserDefaults.standard
    private static let prefKeyPrefix = "settings."
    private static let refreshKey = "settings.refreshInterval"
    private static let tempKey = "settings.temperatureUnit"
    private static let skipIntroKey = "settings.skipIntro"
    private static let reduceMotionKey = "settings.reduceMotion"

    var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Self.refreshKey) }
    }

    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Self.tempKey) }
    }

    var skipIntro: Bool {
        didSet { defaults.set(skipIntro, forKey: Self.skipIntroKey) }
    }

    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Self.reduceMotionKey) }
    }

    /// 界面语言：直接代理 L10n（其自带持久化 + 免重启实时切换）。
    var language: L10n.Language {
        get { L10n.shared.language }
        set { L10n.shared.language = newValue }
    }

    // MARK: - 开机自动启动（SMAppService 为真相源）

    private(set) var launchAtLogin = false
    /// 注册 / 注销失败时的错误文案（供 UI 以 .help 呈现）。
    private(set) var launchAtLoginError: String?

    // MARK: - 白名单

    private(set) var whitelistMode: WhitelistMode = .clean
    private(set) var whitelistPhase: WhitelistPhase = .idle
    private(set) var entries: [WhitelistEntry] = []
    /// 正在删除的 id（期间禁用该行交互）。
    private(set) var pendingRemove: Set<String> = []
    /// 添加进行中（期间禁用添加按钮，避免连点竞态）。
    private(set) var isAdding = false

    private let whitelistClient = WhitelistClient()
    private var whitelistTask: Task<Void, Never>?

    // MARK: - 权限中心

    /// 默认假定已授权，探测回来再决定徽标，避免首帧闪现。
    private(set) var hasFullDiskAccess = true
    private let probe = PermissionProbe()

    /// 后台助手：v1 恒未安装（helper 尚未落地）。
    let helperInstalled = false

    // MARK: - 生命周期

    init() {
        let storedRefresh = defaults.object(forKey: Self.refreshKey) as? Int
        refreshInterval = RefreshInterval(rawValue: storedRefresh ?? 2) ?? .two
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Self.tempKey) ?? "") ?? .auto
        skipIntro = defaults.bool(forKey: Self.skipIntroKey)
        reduceMotion = defaults.bool(forKey: Self.reduceMotionKey)
        refreshLaunchAtLoginStatus()
    }

    // MARK: - 开机自动启动

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 写开关：乐观翻转 → register/unregister；失败回滚并记录错误。
    func setLaunchAtLogin(_ enabled: Bool) {
        let previous = launchAtLogin
        launchAtLogin = enabled
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = previous
            launchAtLoginError = error.localizedDescription
        }
    }

    // MARK: - 白名单

    /// 首次进入白名单分区才加载（lazy）。
    func loadWhitelistIfNeeded() {
        guard whitelistPhase == .idle else { return }
        reloadWhitelist()
    }

    /// 切换模式：重拉对应列表。
    func selectMode(_ mode: WhitelistMode) {
        guard mode != whitelistMode else { return }
        whitelistMode = mode
        reloadWhitelist()
    }

    /// 拉取当前模式的白名单（loading 保留旧数据不闪）。
    func reloadWhitelist() {
        whitelistTask?.cancel()
        whitelistPhase = .loading
        let mode = whitelistMode
        whitelistTask = Task { [weak self] in
            do {
                let list = try await self?.whitelistClient.list(mode: mode) ?? []
                guard let self, !Task.isCancelled, whitelistMode == mode else { return }
                entries = list
                whitelistPhase = .loaded
            } catch {
                guard let self, !Task.isCancelled, whitelistMode == mode else { return }
                whitelistPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// 添加一条 pattern（View 层已把目录路径转 `~/` 缩写）。用返回的新列表覆盖。
    func addPattern(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAdding else { return }
        let mode = whitelistMode
        isAdding = true
        Task { [weak self] in
            do {
                let list = try await self?.whitelistClient.add(pattern: trimmed, mode: mode) ?? []
                guard let self else { return }
                isAdding = false
                guard whitelistMode == mode else { return }
                entries = list
                whitelistPhase = .loaded
            } catch {
                guard let self else { return }
                isAdding = false
                whitelistPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// 移除一条 pattern（乐观禁用该行）。用返回的新列表覆盖。
    func removePattern(_ entry: WhitelistEntry) {
        guard !pendingRemove.contains(entry.id) else { return }
        let mode = whitelistMode
        pendingRemove.insert(entry.id)
        Task { [weak self] in
            do {
                let list = try await self?.whitelistClient.remove(pattern: entry.pattern, mode: mode) ?? []
                guard let self else { return }
                pendingRemove.remove(entry.id)
                guard whitelistMode == mode else { return }
                entries = list
                whitelistPhase = .loaded
            } catch {
                guard let self else { return }
                pendingRemove.remove(entry.id)
                whitelistPhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 权限中心

    /// 进入权限分区时探测 FDA（后台线程，避免主线程文件读阻塞）。
    func probeFullDiskAccess() {
        let probe = probe
        Task { [weak self] in
            let granted = await Task.detached { probe.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = granted
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PermissionProbe.fullDiskAccessSettingsURL)
    }

    // MARK: - 高级：重置

    /// 重置所有偏好：清掉 `settings.` 前缀 key 并恢复默认。白名单与授权不受影响；
    /// launchAtLogin 注册态不变。
    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        refreshInterval = .two
        temperatureUnit = .auto
        skipIntro = false
        reduceMotion = false
        L10n.shared.language = .system
    }

    // MARK: - 全局快捷键（设计 CHANGELOG §3.1）

    /// 录制态状态机：idle（展示已保存组合或「未设置」）/ recording（等待按键，esc 取消）。
    enum HotkeyRecordingState: Equatable {
        case idle, recording
    }

    private(set) var hotkeyRecording: HotkeyRecordingState = .idle
    /// 捕获后若与系统快捷键冲突，行下方展示琥珀提示；仍允许保存，提示不阻断。
    private(set) var hotkeyConflictMessage: String?
    private var hotkeyMonitor: Any?

    /// 已保存的快捷键（真相源 = HotkeyManager，其自带 UserDefaults 持久化）。
    var currentHotkey: HotkeyCombo? { HotkeyManager.shared.current }

    /// 进入录制态：挂一个仅录制期存在的本地按键监听，捕获后立即移除。
    func startHotkeyRecording() {
        guard hotkeyRecording == .idle else { return }
        hotkeyRecording = .recording
        hotkeyConflictMessage = nil
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                cancelHotkeyRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // 必须包含至少一个修饰键，否则忽略此次按键（继续等待下一次）。
            guard !modifiers.isEmpty else { return nil }
            applyHotkey(HotkeyCombo(keyCode: Int(event.keyCode), modifierFlags: modifiers))
            return nil
        }
    }

    /// esc 取消录制，不改动已保存的快捷键。
    func cancelHotkeyRecording() {
        stopHotkeyMonitor()
        hotkeyRecording = .idle
    }

    /// 清除已保存的快捷键（行内 × 按钮），即时注销 Carbon 注册。
    func clearHotkey() {
        stopHotkeyMonitor()
        hotkeyRecording = .idle
        hotkeyConflictMessage = nil
        HotkeyManager.shared.update(nil)
    }

    private func applyHotkey(_ combo: HotkeyCombo) {
        stopHotkeyMonitor()
        hotkeyRecording = .idle
        HotkeyManager.shared.update(combo)
        hotkeyConflictMessage = HotkeyConflicts.conflict(for: combo).map {
            L("settings.general.hotkey.conflict", $0.localizedName)
        }
    }

    private func stopHotkeyMonitor() {
        if let hotkeyMonitor { NSEvent.removeMonitor(hotkeyMonitor) }
        hotkeyMonitor = nil
    }

    // MARK: - 诊断日志导出（设计 CHANGELOG §3.2）

    enum DiagnosticsExportPhase: Equatable {
        case idle, exporting
        case succeeded(URL)
        case failed(String)
    }

    private(set) var diagnosticsPhase: DiagnosticsExportPhase = .idle
    private var diagnosticsToastTask: Task<Void, Never>?
    private let diagnosticsExporter = DiagnosticsExporter()

    /// 「导出…」按钮触发；进行中不重入（重试按钮走同一入口）。
    func startDiagnosticsExport() {
        guard diagnosticsPhase != .exporting else { return }
        diagnosticsToastTask?.cancel()
        diagnosticsPhase = .exporting
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await diagnosticsExporter.exportReport()
                diagnosticsPhase = .succeeded(url)
                scheduleDiagnosticsToastAutoDismiss()
            } catch {
                diagnosticsPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// toast 关闭按钮（成功/失败态均可手动关闭）。
    func dismissDiagnosticsToast() {
        diagnosticsToastTask?.cancel()
        diagnosticsPhase = .idle
    }

    /// 「在 Finder 中显示」。
    func revealDiagnosticsExport() {
        guard case let .succeeded(url) = diagnosticsPhase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 成功态 6 秒后自动消失（设计 §3.2）。
    private func scheduleDiagnosticsToastAutoDismiss() {
        diagnosticsToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.diagnosticsPhase = .idle
        }
    }

    // MARK: - 关于

    /// 内嵌核心版本（读 bundle 内 mole 脚本 VERSION=）；读不到返回 nil。
    func coreVersion() -> String? {
        CoreBundleLocator().coreVersion()
    }

    /// 应用版本串（CFBundleShortVersionString + build）。
    var appShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
