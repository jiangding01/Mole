import AppKit
import MoleKit
import Observation

/// 软件页 Store（设计 §5.2）：卸载 tab 的应用清单、搜索、排序、多选，
/// 与卸载执行链（robot apps plan/apply：本体 + 勾选残留 → 废纸篓）。
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

    /// robot apps plan 的产物：计划 id + 全部条目（首项为应用本体，section "app"）。
    struct AppPlan {
        var planId: String
        var items: [RobotItem]
        var leftovers: [RobotItem] { items.filter { $0.section != "app" } }
        var bundleItemId: String? { items.first { $0.section == "app" }?.id }
    }

    enum LeftoverState {
        case loading
        case loaded(AppPlan)
        case failed(String)
    }

    /// 展开的应用（path 集合）。
    var expanded: Set<String> = []
    /// 每个应用的残留发现结果（robot apps plan，只读发现 + 计划文件）。
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
            do {
                let plan = try await Self.runPlan(for: app)
                guard let self else { return }
                self.leftovers[app.id] = .loaded(plan)
                // 默认勾选 = 核心侧 default_selected（系统级需复核项默认不勾）
                self.checkedLeftovers[app.id] = Set(plan.leftovers.filter { $0.defaultSelected ?? true }.map(\.id))
            } catch {
                self?.leftovers[app.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// 跑一次 robot apps plan，要求流以 done（含 plan_id）收尾。
    private static func runPlan(for app: InstalledApp) async throws -> AppPlan {
        var items: [RobotItem] = []
        var planId: String?
        var robotError: RobotError?
        let session = RobotSession()
        let command = RobotSession.Command(
            domain: "apps", verb: "plan",
            arguments: [app.path, app.bundleId, app.name]
        )
        for try await event in session.run(command) {
            switch event {
            case let .item(item): items.append(item)
            case let .done(done): planId = done.planId
            case let .error(error): robotError = error
            default: break
            }
        }
        if let robotError {
            throw PlanError.robot("\(robotError.code): \(robotError.message ?? "")")
        }
        guard let planId else {
            // 流没有以 done 收尾：核心异常退出，不能把空结果当"无残留"
            throw PlanError.robot("协议流异常结束")
        }
        return AppPlan(planId: planId, items: items)
    }

    enum PlanError: LocalizedError {
        case robot(String)
        var errorDescription: String? {
            if case let .robot(message) = self { return message }
            return nil
        }
    }

    func retryLeftovers(for app: InstalledApp) {
        leftovers[app.id] = nil
        fetchLeftovers(for: app)
    }

    /// 不可执行项（系统级复核项，id 前缀 info.）：仅展示，永不进 apply。
    func isReviewOnly(_ item: RobotItem) -> Bool {
        item.id.hasPrefix("info.")
    }

    func toggleLeftover(_ app: InstalledApp, _ item: RobotItem) {
        guard !isReviewOnly(item) else { return }
        var set = checkedLeftovers[app.id] ?? []
        if set.contains(item.id) { set.remove(item.id) } else { set.insert(item.id) }
        checkedLeftovers[app.id] = set
    }

    func loadedLeftovers(for app: InstalledApp) -> [RobotItem]? {
        if case let .loaded(plan) = leftovers[app.id] { return plan.leftovers }
        return nil
    }

    func plan(for app: InstalledApp) -> AppPlan? {
        if case let .loaded(plan) = leftovers[app.id] { return plan }
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

    // MARK: - 卸载执行（确认 → 逐应用 apply → 完成汇总；§3.3 破坏性操作全局串行）

    enum RemovalPhase: Equatable {
        case idle
        case running(app: String, index: Int, total: Int)
        case done(removed: Int, freedBytes: Int64, failedItems: Int)
    }

    var removalPhase: RemovalPhase = .idle
    /// 确认弹层开关（View 的 confirmationDialog 绑定）。
    var confirmRemoval = false
    /// 仍在运行、需先退出的已选应用（非空 → View 弹 alert）。
    var runningBlockers: [InstalledApp] = []

    /// 「移除 N 项」入口：先拦运行中的应用，再进确认。
    func requestRemoval() {
        let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        let blockers = selectedApps.filter { runningPaths.contains($0.path) }
        if blockers.isEmpty {
            confirmRemoval = true
        } else {
            runningBlockers = blockers
        }
    }

    /// 「退出并继续」：请求正常退出（不强杀），随后进确认。
    func quitBlockersAndContinue() {
        for app in runningBlockers {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleURL?.path == app.path }?
                .terminate()
        }
        runningBlockers = []
        confirmRemoval = true
    }

    func executeRemoval() {
        let targets = selectedApps
        guard !targets.isEmpty else { return }
        removalPhase = .running(app: targets[0].name, index: 0, total: targets.count)
        Task { [weak self] in
            var freed: Int64 = 0
            var failedItems = 0
            var removed = 0
            for (index, app) in targets.enumerated() {
                guard let self else { return }
                self.removalPhase = .running(app: app.name, index: index, total: targets.count)
                do {
                    let summary = try await self.removeOne(app)
                    freed += summary.freedBytes ?? 0
                    failedItems += summary.failed ?? 0
                    removed += 1
                } catch {
                    failedItems += 1
                }
            }
            guard let self else { return }
            self.removalPhase = .done(removed: removed, freedBytes: freed, failedItems: failedItems)
            // 清理会话状态并刷新清单（已卸载的应用从列表消失）
            for app in targets {
                self.selection.remove(app.id)
                self.expanded.remove(app.id)
                self.leftovers[app.id] = nil
                self.checkedLeftovers[app.id] = nil
            }
            self.reload()
        }
    }

    func finishRemoval() {
        removalPhase = .idle
    }

    /// 单应用移除：本体 + 勾选残留走 apps apply；计划过期自动重建并重试一次。
    private func removeOne(_ app: InstalledApp) async throws -> RobotSummary {
        var plan: AppPlan
        if let cached = self.plan(for: app) {
            plan = cached
        } else {
            plan = try await Self.runPlan(for: app)
            leftovers[app.id] = .loaded(plan)
        }
        let checked = checkedLeftovers[app.id]
            ?? Set(plan.leftovers.filter { $0.defaultSelected ?? true }.map(\.id))
        do {
            return try await Self.runApply(plan: plan, checked: checked)
        } catch let PlanError.robot(message) where message.contains("E_PLAN_EXPIRED") {
            // 计划 30 分钟 TTL：过期重建一次（路径集合按最新发现为准）
            plan = try await Self.runPlan(for: app)
            leftovers[app.id] = .loaded(plan)
            return try await Self.runApply(plan: plan, checked: checked)
        }
    }

    private static func runApply(plan: AppPlan, checked: Set<String>) async throws -> RobotSummary {
        var ids: [String] = []
        if let bundle = plan.bundleItemId { ids.append(bundle) }
        ids += plan.leftovers.filter { checked.contains($0.id) }.map(\.id)

        var summary: RobotSummary?
        var robotError: RobotError?
        let session = RobotSession()
        let command = RobotSession.Command(
            domain: "apps", verb: "apply",
            arguments: ["--plan", plan.planId],
            stdinPayload: Data((ids.joined(separator: "\n") + "\n").utf8)
        )
        for try await event in session.run(command) {
            switch event {
            case let .done(done): summary = done.summary
            case let .error(error): robotError = error
            default: break
            }
        }
        if let robotError {
            throw PlanError.robot("\(robotError.code): \(robotError.message ?? "")")
        }
        guard let summary else {
            throw PlanError.robot("协议流异常结束")
        }
        return summary
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
