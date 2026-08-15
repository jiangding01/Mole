import AppKit
import Foundation
import MoleKit
import Observation

/// 清理页 Store（设计 §5.1 / 设计稿 clean 页状态机）：
/// idle → scanning（robot clean plan 流式进度）→ confirm（分组勾选，安全三承诺）
/// → executing（robot clean apply 逐项结果流）→ done ；无可清理走 empty 愉悦态。
/// 扫描/执行均可取消：SIGTERM，apply 侧核心完成当前单项后以 done(cancelled:n) 收尾。
@Observable
@MainActor
final class CleanStore {
    enum Phase: Equatable {
        case idle
        case scanning
        case confirm
        case executing
        case done(freed: Int64, failed: Int, skipped: Int, cancelled: Int)
        case empty
        case failed(String)
    }

    struct Group: Identifiable {
        let section: String
        var items: [RobotItem]
        var id: String {
            section
        }

        var bytes: Int64 {
            items.compactMap(\.bytes).reduce(0, +)
        }
    }

    struct LogEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let bytes: Int64
        let ok: Bool
        /// trashed / deleted / dry_run / skipped_* / failed（非 ok 行的说明徽标）
        let status: String
    }

    var phase: Phase = .idle

    // MARK: 扫描进度（progress 事件驱动）

    private(set) var scanBytesFound: Int64 = 0
    private(set) var scanCurrent = ""
    private(set) var scanSection = ""
    private(set) var scanStartedAt = Date()

    // MARK: 计划（confirm 态数据）

    private(set) var planId: String?
    private(set) var groups: [Group] = []

    // MARK: 确认页折叠态（设计 r2 §P1：千级条目的可复核形态）

    /// 展开的组（默认全折叠——摘要卡先给"总量+每组贡献"的一眼结论）。
    private(set) var expandedGroups: Set<String> = []
    /// 每组当前可见条数（首屏 12，"再显示"每次 +50；未记录 = 首屏值）。
    private(set) var visibleCounts: [String: Int] = [:]
    /// 组内展示序缓存（ingest 时算一次，渲染只读）：有尺寸项体积降序 →
    /// 大小未知 → 0 B 沉底。未知项排在 0 B 分隔线**之前**——原型把 size===0
    /// 全部沉底，但"以下 N 项为 0 B · 空目录"对未知项是错误陈述（r2 §P1.4
    /// 明确两者是两回事），这里按设计意图对原型代码做有意偏差。
    private(set) var sortedItemsByGroup: [String: [RobotItem]] = [:]
    /// 每组真 0 B 项数（分隔线文案与全 0 B 变体卡用；未知项不计入）。
    private(set) var zeroCountByGroup: [String: Int] = [:]

    static let initialVisible = 12
    static let revealStep = 50

    /// 因应用运行被跳过的家族名（守卫提示条，r2 §P2）。红线：不承诺字节数。
    private(set) var guardBlockedApps: [String] = []
    /// × = 本次会话（本份 plan）不再提示；新扫描重置。
    var guardBarDismissed = false
    private(set) var insights: [RobotInsight] = []
    var checked: Set<String> = []
    /// 协议推荐集（r3 §P6）：default_selected 为真的项（safe 勾 / caution 不勾）。
    /// ingest 时算一次；「推荐」按钮回到这个集合，选择恰等时按钮高亮。
    private(set) var recommendedIds: Set<String> = []
    /// 本次会话内已加白名单的项（r3 §P3 可撤销状态机）：不从清单移除，
    /// 置灰 + 徽标 + 取消勾选 + 除名统计；再点盾牌撤销。持久化在 CLI 侧
    /// （robot whitelist add --mode clean 即时落盘），下次扫描核心自动跳过。
    private(set) var whitelistedIds: Set<String> = []
    /// 白名单往返在途的项（防连点；成功/失败都会移除）。
    private(set) var whitelistBusyIds: Set<String> = []
    private(set) var confirmRevealStart = Date()

    // MARK: 执行（result 事件驱动）

    private(set) var log: [LogEntry] = []
    private(set) var freed: Int64 = 0
    private(set) var plannedBytes: Int64 = 0

    private var session: RobotSession?
    private var itemsById: [String: RobotItem] = [:]
    private var cancelRequested = false

    /// 会话资产（由 CleanView 注入）：智能扫描的 clean 域 plan 可零重扫复用，
    /// 本页自扫结果也写回，供其它入口复用（设计 §5.0 数据一份、两处视图）。
    var scanSession: ScanSession?

    // MARK: - 会话复用（§5.0 正向闭环）

    /// 进入清理页时：若会话里已有未过期的 clean plan（多来自智能扫描），
    /// 直接摊到 confirm 态复用，不重扫。仅在 idle 态生效，避免打断进行中的流程。
    func adoptSessionPlanIfAvailable() {
        guard phase == .idle, let plan = scanSession?.activePlan(for: .clean) else { return }
        ingestPlan(planId: plan.planId, items: plan.items, insights: plan.insights)
    }

    // MARK: - 扫描

    func startScan() {
        guard phase != .scanning, phase != .executing else { return }
        resetPlan()
        phase = .scanning
        scanStartedAt = Date()
        cancelRequested = false
        let session = RobotSession()
        self.session = session
        Task { [weak self] in
            var items: [RobotItem] = []
            var collectedInsights: [RobotInsight] = []
            var donePlanId: String?
            var robotError: RobotError?
            do {
                let command = RobotSession.Command(domain: "clean", verb: "plan")
                for try await event in session.run(command) {
                    guard let self else { return }
                    switch event {
                    case let .progress(progress):
                        if let bytes = progress.bytesFound { scanBytesFound = bytes }
                        if let current = progress.current { scanCurrent = current }
                        if let section = progress.section { scanSection = section }
                    case let .item(item):
                        items.append(item)
                    case let .insight(insight):
                        collectedInsights.append(insight)
                    case let .done(done):
                        donePlanId = done.planId
                    case let .error(error):
                        robotError = error
                    default: break
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard let self else { return }
            if cancelRequested {
                phase = .idle
                return
            }
            if let robotError {
                phase = .failed("\(robotError.code): \(robotError.message ?? "")")
                return
            }
            guard let donePlanId else {
                phase = .failed("协议流异常结束")
                return
            }
            ingestPlan(planId: donePlanId, items: items, insights: collectedInsights)
            // 自扫结果写回会话：其它入口（智能页/再入本页）零重扫复用（§5.0）。
            scanSession?.store(
                ScanSession.DomainPlan(
                    planId: donePlanId, items: items,
                    insights: collectedInsights, createdAt: Date()
                ),
                for: .clean
            )
        }
    }

    func cancelScan() {
        cancelRequested = true
        session?.cancel()
    }

    private func ingestPlan(planId: String, items: [RobotItem], insights allInsights: [RobotInsight]) {
        self.planId = planId
        // 守卫事件（section=guard_skipped）与空间洞察分流（r2 §P2）：
        // 前者进提示条，后者进洞察卡——混着渲染两边都错。
        guardBlockedApps = allInsights
            .filter { $0.section == "guard_skipped" }
            .map(\.label)
        guardBarDismissed = false
        let insights = allInsights.filter { $0.section != "guard_skipped" }
        self.insights = insights
        itemsById = [:]
        var order: [String] = []
        var buckets: [String: [RobotItem]] = [:]
        for item in items {
            itemsById[item.id] = item
            let section = item.section ?? "other"
            if buckets[section] == nil { order.append(section) }
            buckets[section, default: []].append(item)
        }
        groups = order.map { Group(section: $0, items: buckets[$0] ?? []) }
        recommendedIds = Set(items.filter { $0.defaultSelected ?? true }.map(\.id))
        checked = recommendedIds
        // 折叠态初始化（自扫与会话复用两个入口共用本方法，状态必然归零）
        expandedGroups = []
        visibleCounts = [:]
        whitelistedIds = []
        sortedItemsByGroup = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.section, Self.displayOrder(group.items))
        })
        zeroCountByGroup = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.section, group.items.count(where: { $0.bytes == 0 }))
        })
        confirmRevealStart = Date()
        phase = items.isEmpty ? .empty : .confirm
    }

    /// 展示序（r2 §P1.2）：有尺寸项体积降序 → 大小未知 → 0 B。
    private static func displayOrder(_ items: [RobotItem]) -> [RobotItem] {
        func rank(_ item: RobotItem) -> Int {
            guard let bytes = item.bytes else { return 1 } // 未知：分隔线之前
            return bytes == 0 ? 2 : 0
        }
        return items.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            let ba = a.element.bytes ?? 0, bb = b.element.bytes ?? 0
            if ba != bb { return ba > bb }
            return a.offset < b.offset // 同值保持扫描序，排序稳定
        }.map(\.element)
    }

    // MARK: - 折叠/分页（确认页摘要卡）

    func isExpanded(_ group: Group) -> Bool {
        expandedGroups.contains(group.section)
    }

    func toggleExpand(_ group: Group) {
        if expandedGroups.contains(group.section) {
            expandedGroups.remove(group.section)
        } else {
            expandedGroups.insert(group.section)
        }
    }

    func visibleCount(_ group: Group) -> Int {
        min(visibleCounts[group.section] ?? Self.initialVisible, group.items.count)
    }

    func revealMore(_ group: Group) {
        visibleCounts[group.section] = visibleCount(group) + Self.revealStep
    }

    func sortedItems(_ group: Group) -> [RobotItem] {
        sortedItemsByGroup[group.section] ?? group.items
    }

    func zeroCount(_ group: Group) -> Int {
        zeroCountByGroup[group.section] ?? 0
    }

    /// 全 0 B 组（r2 §P1.5 边界态）：无贡献条，摘要卡直接告知无可释放。
    func isAllZero(_ group: Group) -> Bool {
        !group.items.isEmpty && zeroCount(group) == group.items.count
    }

    func groupSelectedCount(_ group: Group) -> Int {
        group.items.count(where: { checked.contains($0.id) })
    }

    func groupSelectedBytes(_ group: Group) -> Int64 {
        group.items.filter { checked.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
    }

    /// 贡献条基准：最大组体积（已知项之和）。
    var maxGroupBytes: Int64 {
        groups.map(\.bytes).max() ?? 0
    }

    #if DEBUG
        /// 单测入口：ingestPlan 是私有实现细节，测试经此走真实摄入路径。
        func ingestPlanForTesting(planId: String, items: [RobotItem], insights: [RobotInsight]) {
            ingestPlan(planId: planId, items: items, insights: insights)
        }

        /// 单测入口：真实 toggleWhitelist 走 robot 子进程往返，
        /// 测试只验证加白后的选择联动，经此直接置位。
        func markWhitelistedForTesting(_ id: String) {
            whitelistedIds.insert(id)
            checked.remove(id)
        }
    #endif

    private func resetPlan() {
        planId = nil
        groups = []
        insights = []
        checked = []
        recommendedIds = []
        whitelistedIds = []
        itemsById = [:]
        log = []
        freed = 0
        plannedBytes = 0
        scanBytesFound = 0
        scanCurrent = ""
        scanSection = ""
        expandedGroups = []
        visibleCounts = [:]
        sortedItemsByGroup = [:]
        zeroCountByGroup = [:]
    }

    // MARK: - 勾选

    func toggle(_ item: RobotItem) {
        guard !whitelistedIds.contains(item.id) else { return } // 白名单行不可勾（§P3）
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    /// 组全选态：白名单行除名——"全部可勾项已勾"即视为全选。
    func groupChecked(_ group: Group) -> Bool {
        group.items.allSatisfy { checked.contains($0.id) || whitelistedIds.contains($0.id) }
    }

    func toggleGroup(_ group: Group) {
        if groupChecked(group) {
            for item in group.items {
                checked.remove(item.id)
            }
        } else {
            for item in group.items where !whitelistedIds.contains(item.id) {
                checked.insert(item.id)
            }
        }
    }

    // MARK: - 选择预设（r3 §P6：全选 · 清空 · 推荐）

    func selectAll() {
        checked = Set(groups.flatMap(\.items).map(\.id)).subtracting(whitelistedIds)
    }

    func selectNone() {
        checked = []
    }

    func selectRecommended() {
        checked = effectiveRecommended
    }

    /// 当前选择恰等推荐集：「推荐」字色高亮为 accent，作无声状态指示（§P6）。
    var isRecommendedSelection: Bool {
        checked == effectiveRecommended
    }

    /// 推荐集扣除已加白的项：白名单行不可勾，「推荐」不应试图勾它。
    private var effectiveRecommended: Set<String> {
        recommendedIds.subtracting(whitelistedIds)
    }

    // MARK: - 行内动作（r3 §P3）

    func isWhitelisted(_ item: RobotItem) -> Bool {
        whitelistedIds.contains(item.id)
    }

    func isWhitelistBusy(_ item: RobotItem) -> Bool {
        whitelistBusyIds.contains(item.id)
    }

    /// 在 Finder 中显示（只读动作，不动文件）。
    func revealInFinder(_ item: RobotItem) {
        guard let path = item.path ?? (item.label.isEmpty ? nil : item.label) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 盾牌开关（§P3 可撤销状态机）：加白 = CLI 即时落盘 + 行灰置 + 取消勾选；
    /// 再点 = 从白名单移除，行重新可勾（不自动回勾，由用户决定）。
    /// 失败保持原状态不变（下次点击重试），不做乐观更新——落盘成败即真相。
    func toggleWhitelist(_ item: RobotItem) {
        guard let path = item.path ?? (item.label.isEmpty ? nil : item.label) else { return }
        guard !whitelistBusyIds.contains(item.id) else { return }
        whitelistBusyIds.insert(item.id)
        let removing = whitelistedIds.contains(item.id)
        Task { [weak self] in
            defer { self?.whitelistBusyIds.remove(item.id) }
            do {
                let client = WhitelistClient()
                if removing {
                    _ = try await client.remove(pattern: path, mode: .clean)
                    self?.whitelistedIds.remove(item.id)
                } else {
                    _ = try await client.add(pattern: path, mode: .clean)
                    self?.whitelistedIds.insert(item.id)
                    self?.checked.remove(item.id)
                }
            } catch {
                // 静默保持原状：按钮状态未变即"没成"，可重试；不弹阻断错误。
            }
        }
    }

    var totalBytes: Int64 {
        groups.reduce(0) { $0 + $1.bytes }
    }

    var checkedCount: Int {
        checked.count
    }

    var checkedBytes: Int64 {
        groups.flatMap(\.items).filter { checked.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
    }

    /// 已勾选但尺寸未知（bytes == nil）的项数：总计只累加已知项，
    /// 未知项在确认条上单独声明（设计 CHANGELOG-2026-08-15 §1.2）。
    var checkedUnknownCount: Int {
        groups.flatMap(\.items).filter { checked.contains($0.id) && $0.bytes == nil }.count
    }

    // MARK: - 执行

    func execute() {
        guard let planId, phase == .confirm, !checked.isEmpty else { return }
        // 与确认清单展示同序执行（体积降序）：结果日志与用户刚复核的顺序一致，
        // 且大项先删——中途取消时已释放的空间最大化。
        let ids = groups.flatMap { sortedItems($0) }.map(\.id).filter { checked.contains($0) }
        plannedBytes = checkedBytes
        log = []
        freed = 0
        phase = .executing
        cancelRequested = false
        let session = RobotSession()
        self.session = session
        Task { [weak self] in
            var summary: RobotSummary?
            var robotError: RobotError?
            do {
                let command = RobotSession.Command(
                    domain: "clean", verb: "apply",
                    arguments: ["--plan", planId],
                    stdinPayload: Data((ids.joined(separator: "\n") + "\n").utf8)
                )
                for try await event in session.run(command) {
                    guard let self else { return }
                    switch event {
                    case let .result(result):
                        let item = itemsById[result.id]
                        let path = item?.path ?? item?.label ?? result.id
                        let bytes = result.freedBytes ?? item?.bytes ?? 0
                        let ok = ["trashed", "deleted", "dry_run"].contains(result.status)
                        if ok { freed += bytes }
                        log.append(.init(
                            id: result.id,
                            name: (path as NSString).abbreviatingWithTildeInPath,
                            bytes: bytes, ok: ok, status: result.status
                        ))
                    case let .done(done):
                        summary = done.summary
                    case let .error(error):
                        robotError = error
                    default: break
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard let self else { return }
            if let robotError {
                phase = .failed("\(robotError.code): \(robotError.message ?? "")")
                return
            }
            guard let summary else {
                // 取消时核心保证发 done 再退出；连 done 都没有说明异常终止
                phase = .failed("协议流异常结束")
                return
            }
            phase = .done(
                freed: summary.freedBytes ?? freed,
                failed: summary.failed ?? 0,
                skipped: summary.skipped ?? 0,
                cancelled: summary.cancelled ?? 0
            )
            self.planId = nil // 计划已消费
        }
    }

    /// 执行中取消：SIGTERM，核心完成当前单项后以 done(cancelled:n) 收尾（§4.4）。
    func cancelExecute() {
        cancelRequested = true
        session?.cancel()
    }

    var executeProgress: Double {
        guard plannedBytes > 0 else { return 0 }
        return min(1, Double(freed) / Double(plannedBytes))
    }

    // MARK: - 完成后

    func backToIdle() {
        resetPlan()
        phase = .idle
    }

    // MARK: - 文案辅助

    /// section slug → 中文组名（未知 slug 人性化兜底）。
    static func sectionLabel(_ slug: String) -> String {
        let table: [String: String] = [
            "user_essentials": "用户缓存",
            "app_caches": "应用缓存",
            "browsers": "浏览器缓存",
            "developer_tools": "开发者工具",
            "development": "开发者工具",
            "logs": "日志",
            "system_logs": "系统日志",
            "trash": "废纸篓",
            "downloads": "下载残留",
            "installers": "安装包",
            "app_leftovers": "卸载残留",
            "leftovers": "卸载残留",
            // slug 规则（robot_section_slug）："&" → "and"，非字母数字折叠为 "_"
            "apps_and_utilities": "应用与工具",
            "application_support": "应用支持文件",
            "cloud_and_office": "云盘与 Office",
            "large_files": "大文件",
            "system_maintenance": "系统维护",
            "external_volumes": "外置卷",
            "other": "其他",
        ]
        if let label = table[slug] { return label }
        return slug.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func statusLabel(_ status: String) -> String? {
        switch status {
        case "skipped_whitelisted": "白名单保护"
        case "skipped_protected": "受保护"
        case "skipped_missing": "已不存在"
        case "failed": "失败"
        case "dry_run": "演练"
        default: nil
        }
    }
}
