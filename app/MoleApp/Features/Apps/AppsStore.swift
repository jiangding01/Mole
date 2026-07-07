import AppKit
import MoleKit
import Observation

/// 软件页 Store（设计 §5.2）：卸载 tab 的应用清单、搜索、排序与多选。
/// M0 为只读清单——卸载执行等机器人层 apps plan/apply 落地后接入，
/// 在那之前批量条的移除按钮保持禁用并说明原因（不做假按钮）。
@Observable
@MainActor
final class AppsStore {
    enum Phase: Equatable {
        case idle, loading
        case loaded
        case failed(String)
    }

    enum SortKey: String { case name, size, source }

    enum Tab: String, CaseIterable, Identifiable {
        case uninstall, update, startup
        var id: String { rawValue }
        var title: String {
            switch self {
            case .uninstall: L("apps.tab.uninstall")
            case .update: L("apps.tab.update")
            case .startup: L("apps.tab.startup")
            }
        }
    }

    var phase: Phase = .idle
    var tab: Tab = .uninstall
    var apps: [InstalledApp] = []
    var search = ""
    var sortKey: SortKey = .size
    var sortDescending = true
    var selection: Set<String> = [] // InstalledApp.id（path）

    // MARK: - 残留清单（设计稿：行展开显示分组残留，逐项可勾选）

    enum LeftoverState {
        case loading
        case loaded([RobotItem])
        case failed(String)
    }

    /// 展开的应用（path 集合）。
    var expanded: Set<String> = []
    /// 每个应用的残留发现结果（robot apps files，只读）。
    private(set) var leftovers: [String: LeftoverState] = [:]
    /// 每个应用勾选的残留 item id（默认 = default_selected）。
    var checkedLeftovers: [String: Set<String>] = [:]

    private let client = AppInventoryClient()
    private var loadTask: Task<Void, Never>?

    /// 首次进入页面时加载；已有数据则不重扫（会话内清单复用，设计 §5.0 同源）。
    func loadIfNeeded() {
        guard phase == .idle || isFailed else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task { [weak self] in
            do {
                let apps = try await self?.client.list() ?? []
                guard let self, !Task.isCancelled else { return }
                self.apps = apps
                self.phase = .loaded
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - 派生列表

    var visibleApps: [InstalledApp] {
        var list = apps
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.bundleId.localizedCaseInsensitiveContains(query)
            }
        }
        let sorted = list.sorted { a, b in
            let ascending: Bool
            switch sortKey {
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: ascending = (a.sizeBytes ?? 0) < (b.sizeBytes ?? 0)
            case .source: ascending = a.source < b.source
            }
            return sortDescending ? !ascending : ascending
        }
        return sorted
    }

    var totalSizeText: String {
        let total = apps.compactMap(\.sizeBytes).reduce(0, +)
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortDescending.toggle() } else {
            sortKey = key
            sortDescending = key != .name
        }
    }

    // MARK: - 选择

    /// 勾选应用同时触发残留发现（选中态要展示"移除本体 + 残留 x/y 项"摘要）。
    func toggleSelection(_ app: InstalledApp) {
        if selection.contains(app.id) { selection.remove(app.id) } else {
            selection.insert(app.id)
            fetchLeftovers(for: app)
        }
    }

    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.id) } }

    /// 批量条总量 = 已选应用本体 + 各自勾选残留。
    var selectedSizeText: String {
        var total = selectedApps.compactMap(\.sizeBytes).reduce(0, +)
        for app in selectedApps {
            total += UInt64(checkedLeftoverBytes(for: app))
        }
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: - 展开与残留

    /// 点击行主体展开/收起；首次展开触发发现。
    func toggleExpanded(_ app: InstalledApp) {
        if expanded.contains(app.id) { expanded.remove(app.id) } else {
            expanded.insert(app.id)
            fetchLeftovers(for: app)
        }
    }

    func fetchLeftovers(for app: InstalledApp) {
        guard leftovers[app.id] == nil else { return }
        leftovers[app.id] = .loading
        Task { [weak self] in
            var items: [RobotItem] = []
            do {
                let session = RobotSession()
                let command = RobotSession.Command(
                    domain: "apps", verb: "files",
                    arguments: [app.path, app.bundleId, app.name]
                )
                for try await event in session.run(command) {
                    if case let .item(item) = event { items.append(item) }
                }
                guard let self else { return }
                self.leftovers[app.id] = .loaded(items)
                // 默认勾选 = 核心侧 default_selected（系统级需复核项默认不勾）
                self.checkedLeftovers[app.id] = Set(items.filter { $0.defaultSelected ?? true }.map(\.id))
            } catch {
                self?.leftovers[app.id] = .failed(error.localizedDescription)
            }
        }
    }

    func retryLeftovers(for app: InstalledApp) {
        leftovers[app.id] = nil
        fetchLeftovers(for: app)
    }

    func toggleLeftover(_ app: InstalledApp, _ item: RobotItem) {
        var set = checkedLeftovers[app.id] ?? []
        if set.contains(item.id) { set.remove(item.id) } else { set.insert(item.id) }
        checkedLeftovers[app.id] = set
    }

    func loadedLeftovers(for app: InstalledApp) -> [RobotItem]? {
        if case let .loaded(items) = leftovers[app.id] { return items }
        return nil
    }

    func checkedLeftoverCount(for app: InstalledApp) -> Int {
        checkedLeftovers[app.id]?.count ?? 0
    }

    func checkedLeftoverBytes(for app: InstalledApp) -> Int64 {
        guard let items = loadedLeftovers(for: app), let checked = checkedLeftovers[app.id] else { return 0 }
        return items.filter { checked.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
    }

    /// 未勾选的需复核项总量（摘要行的琥珀提示）。
    func uncheckedReviewBytes(for app: InstalledApp) -> Int64 {
        guard let items = loadedLeftovers(for: app) else { return 0 }
        let checked = checkedLeftovers[app.id] ?? []
        return items.filter { $0.risk == "caution" && !checked.contains($0.id) }
            .compactMap(\.bytes).reduce(0, +)
    }

    /// 展开区分组：按路径归类（Application Support / Caches / Preferences…），
    /// 与设计稿的分组眉题一致；未命中的按 section 兜底。
    func groupedLeftovers(for app: InstalledApp) -> [(group: String, items: [RobotItem])] {
        guard let items = loadedLeftovers(for: app) else { return [] }
        var order: [String] = []
        var buckets: [String: [RobotItem]] = [:]
        for item in items {
            let group = Self.groupLabel(for: item)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private static func groupLabel(for item: RobotItem) -> String {
        let path = item.path ?? ""
        if path.contains("/Application Support/") { return "APPLICATION SUPPORT" }
        if path.contains("/Caches/") || path.contains("/HTTPStorages/") { return "CACHES" }
        if path.contains("/Preferences/") { return "PREFERENCES" }
        if path.contains("/Logs/") || path.contains("DiagnosticReports") { return "LOGS" }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return "LAUNCH AGENTS" }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return "CONTAINERS" }
        if path.contains("/Saved Application State/") { return "SAVED STATE" }
        if item.section == "system" { return "SYSTEM" }
        return "OTHER"
    }

    // MARK: - 行为

    func reveal(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    // MARK: - 图标（按 path 缓存）

    private var iconCache: [String: NSImage] = [:]

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconCache[app.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 36, height: 36)
        iconCache[app.path] = image
        return image
    }
}
