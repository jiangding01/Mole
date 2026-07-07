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

    /// silent = 后台静默校准：不翻转 loading（页面不闪加载态），失败保留现有列表。
    func reload(silent: Bool = false) {
        loadTask?.cancel()
        if !silent || phase != .loaded {
            phase = .loading
        }
        loadTask = Task { [weak self] in
            do {
                let apps = try await self?.client.list() ?? []
                guard let self, !Task.isCancelled else { return }
                self.apps = apps
                self.phase = .loaded
            } catch {
                guard let self, !Task.isCancelled else { return }
                if silent, self.phase == .loaded { return } // 静默失败：下次进页再试
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
        case done(removed: Int, freedBytes: Int64, failedItems: Int, relatedFiles: Int)
    }

    /// 执行期逐项结果（设计稿：光谱环下方的打勾清单）。
    struct RemovalLogEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let bytes: Int64
        let ok: Bool
    }

    var removalPhase: RemovalPhase = .idle
    /// 实时清单与读数（设计稿 REMOVING 态：环心字节数 + 逐项 ✓）。
    private(set) var removalLog: [RemovalLogEntry] = []
    private(set) var removalFreed: Int64 = 0
    private(set) var removalPlannedBytes: Int64 = 0
    private(set) var removalAppNames: [String] = []
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
        removalLog = []
        removalFreed = 0
        removalPlannedBytes = 0
        removalAppNames = targets.map(\.name)
        removalPhase = .running(app: targets[0].name, index: 0, total: targets.count)
        Task { [weak self] in
            guard let self else { return }
            // 先确保每个目标的计划就绪并累计"将移除总字节"（环进度分母）
            var plans: [(InstalledApp, AppPlan, Set<String>)] = []
            for app in targets {
                do {
                    let plan = try await self.ensurePlan(for: app)
                    let checked = self.checkedLeftovers[app.id]
                        ?? Set(plan.leftovers.filter { $0.defaultSelected ?? true }.map(\.id))
                    var bytes = plan.items.first { $0.section == "app" }?.bytes ?? 0
                    bytes += plan.leftovers.filter { checked.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
                    self.removalPlannedBytes += bytes
                    plans.append((app, plan, checked))
                } catch {
                    self.removalLog.append(.init(id: app.id, name: app.name, bytes: 0, ok: false))
                }
            }

            var failedItems = targets.count - plans.count
            var removed = 0
            for (index, entry) in plans.enumerated() {
                let (app, plan, checked) = entry
                self.removalPhase = .running(app: app.name, index: index, total: plans.count)
                do {
                    let summary = try await self.applyWithRetry(app: app, plan: plan, checked: checked)
                    failedItems += summary.failed ?? 0
                    removed += 1
                } catch {
                    failedItems += 1
                    self.removalLog.append(.init(id: app.id, name: app.name, bytes: 0, ok: false))
                }
            }
            let related = self.removalLog.filter { $0.ok && !$0.id.hasSuffix("|app") }.count
            self.removalPhase = .done(removed: removed, freedBytes: self.removalFreed,
                                      failedItems: failedItems, relatedFiles: related)
            // 清理会话状态
            for app in targets {
                self.selection.remove(app.id)
                self.expanded.remove(app.id)
                self.leftovers[app.id] = nil
                self.checkedLeftovers[app.id] = nil
            }
            // 本地先删行：本体确认移除的应用立即从内存清单剔除（返回列表即时
            // 呈现），随后后台静默重扫校准体积与来源——不闪加载页。
            let succeededIds = Set(
                self.removalLog
                    .filter { $0.ok && $0.id.hasSuffix("|app") }
                    .map { String($0.id.dropLast("|app".count)) }
            )
            self.apps.removeAll { succeededIds.contains($0.id) }
            self.reload(silent: true)
        }
    }

    func finishRemoval() {
        removalPhase = .idle
        removalLog = []
        removalFreed = 0
        removalPlannedBytes = 0
        removalAppNames = []
    }

    /// 环进度（0…1）：已释放 / 计划总量。
    var removalProgress: Double {
        guard removalPlannedBytes > 0 else { return 0 }
        return min(1, Double(removalFreed) / Double(removalPlannedBytes))
    }

    private func ensurePlan(for app: InstalledApp) async throws -> AppPlan {
        if let cached = plan(for: app) { return cached }
        let plan = try await Self.runPlan(for: app)
        leftovers[app.id] = .loaded(plan)
        return plan
    }

    /// 单应用 apply；计划过期（30 分钟 TTL）自动重建并重试一次。
    private func applyWithRetry(app: InstalledApp, plan initial: AppPlan, checked: Set<String>) async throws -> RobotSummary {
        do {
            return try await runApply(app: app, plan: initial, checked: checked)
        } catch let PlanError.robot(message) where message.contains("E_PLAN_EXPIRED") {
            let fresh = try await Self.runPlan(for: app)
            leftovers[app.id] = .loaded(fresh)
            return try await runApply(app: app, plan: fresh, checked: checked)
        }
    }

    private func runApply(app: InstalledApp, plan: AppPlan, checked: Set<String>) async throws -> RobotSummary {
        var ids: [String] = []
        if let bundle = plan.bundleItemId { ids.append(bundle) }
        ids += plan.leftovers.filter { checked.contains($0.id) }.map(\.id)

        // id → 条目映射（结果事件回填名称与体积）
        var itemsById: [String: RobotItem] = [:]
        for item in plan.items { itemsById[item.id] = item }

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
            case let .result(result):
                let item = itemsById[result.id]
                let isBundle = item?.section == "app"
                let name = isBundle
                    ? "\(app.name).app"
                    : ((item?.path ?? item?.label ?? result.id) as NSString).lastPathComponent
                let bytes = result.freedBytes ?? item?.bytes ?? 0
                let ok = ["trashed", "deleted", "dry_run"].contains(result.status)
                if ok { removalFreed += bytes }
                removalLog.append(.init(
                    id: isBundle ? "\(app.id)|app" : "\(app.id)|\(result.id)",
                    name: name, bytes: bytes, ok: ok
                ))
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
