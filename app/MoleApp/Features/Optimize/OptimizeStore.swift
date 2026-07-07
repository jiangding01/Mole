import Foundation
import MoleKit
import Observation

/// 优化页 Store（设计 §5.4）：任务清单（robot optimize list）→ 勾选 →
/// 执行（robot optimize run，task_status 事件流）→ 报告。
/// 闭合任务枚举：GUI 按 action id 本地化与分组，未知 id 回退核心英文原文。
@Observable
@MainActor
final class OptimizeStore {
    enum Phase: Equatable {
        case loading
        case list
        case running
        case report(done: Int, failed: Int, skipped: Int)
        case failed(String)
    }

    /// 任务分组（设计稿：日常维护 / 修复小毛病 / 深度维护）。
    enum Category: String, CaseIterable, Identifiable {
        case routine, fixes, deep
        var id: String { rawValue }
        var title: String {
            switch self {
            case .routine: L("optimize.cat.routine")
            case .fixes: L("optimize.cat.fixes")
            case .deep: L("optimize.cat.deep")
            }
        }
    }

    enum TaskState: Equatable {
        case pending, running, done(ms: Int?), skipped(String?), failedTask
    }

    struct TaskRow: Identifiable {
        let id: String // action（闭合枚举键）
        let fallbackName: String // 核心英文 label（未知 id 回退）
        let fallbackDesc: String
        var name: String {
            let key = "optimize.task.\(id).name"
            let localized = L(key)
            return localized == key ? fallbackName : localized
        }
        var desc: String {
            let key = "optimize.task.\(id).desc"
            let localized = L(key)
            return localized == key ? fallbackDesc : localized
        }
        var category: Category { OptimizeStore.category(of: id) }
    }

    var phase: Phase = .loading
    private(set) var tasks: [TaskRow] = []
    var checked: Set<String> = []
    private(set) var states: [String: TaskState] = [:]
    private(set) var runStartedAt = Date()

    private var session: RobotSession?
    private var loadTask: Task<Void, Never>?

    // MARK: - 清单

    /// 首次进入加载；清单已在（或在途）则复用——Store 挂在会话层（RootView），
    /// 切走再回不重新读清单。
    func loadIfNeeded() {
        guard loadTask == nil, tasks.isEmpty, phase == .loading || isFailed else { return }
        load()
    }

    func load() {
        phase = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // 被 cancel 的旧任务不得动状态、也不得清掉新任务的句柄
            defer { if !Task.isCancelled { self?.loadTask = nil } }
            var items: [RobotItem] = []
            var finished = false
            var robotError: RobotError?
            do {
                let session = RobotSession()
                for try await event in session.run(.init(domain: "optimize", verb: "list")) {
                    switch event {
                    case let .item(item): items.append(item)
                    case .done: finished = true
                    case let .error(error): robotError = error
                    default: break
                    }
                }
            } catch {
                if !Task.isCancelled { self?.phase = .failed(error.localizedDescription) }
                return
            }
            guard let self, !Task.isCancelled else { return }
            if let robotError {
                self.phase = .failed("\(robotError.code): \(robotError.message ?? "")")
                return
            }
            guard finished else {
                self.phase = .failed("协议流异常结束")
                return
            }
            self.tasks = items.map {
                TaskRow(id: $0.id, fallbackName: $0.label, fallbackDesc: $0.detail ?? "")
            }
            self.checked = Set(self.tasks.map(\.id))
            self.phase = .list
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func grouped() -> [(category: Category, rows: [TaskRow])] {
        Category.allCases.compactMap { category in
            let rows = tasks.filter { $0.category == category }
            return rows.isEmpty ? nil : (category, rows)
        }
    }

    func toggle(_ task: TaskRow) {
        if checked.contains(task.id) { checked.remove(task.id) } else { checked.insert(task.id) }
    }

    // MARK: - 执行

    /// 执行进度（环 tending 段：已结束任务数 / 总数）。
    var finishedCount: Int {
        states.values.filter {
            if case .running = $0 { return false }
            if case .pending = $0 { return false }
            return true
        }.count
    }

    var runTotal: Int { states.count }

    var currentTaskName: String {
        guard let id = states.first(where: { if case .running = $0.value { return true }; return false })?.key
        else { return "" }
        return tasks.first { $0.id == id }?.name ?? id
    }

    func execute() {
        guard phase == .list, !checked.isEmpty else { return }
        let ids = tasks.map(\.id).filter { checked.contains($0) }
        states = Dictionary(uniqueKeysWithValues: ids.map { ($0, TaskState.pending) })
        runStartedAt = Date()
        phase = .running
        let session = RobotSession()
        self.session = session
        Task { [weak self] in
            var summary: RobotSummary?
            var robotError: RobotError?
            do {
                let command = RobotSession.Command(
                    domain: "optimize", verb: "run",
                    stdinPayload: Data((ids.joined(separator: "\n") + "\n").utf8)
                )
                for try await event in session.run(command) {
                    guard let self else { return }
                    switch event {
                    case let .taskStatus(status):
                        switch status.status {
                        case "running": self.states[status.taskId] = .running
                        case "done": self.states[status.taskId] = .done(ms: status.durationMs)
                        case "skipped": self.states[status.taskId] = .skipped(status.detail)
                        default: self.states[status.taskId] = .failedTask
                        }
                    case let .done(done): summary = done.summary
                    case let .error(error): robotError = error
                    default: break
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard let self else { return }
            if let robotError {
                self.phase = .failed("\(robotError.code): \(robotError.message ?? "")")
                return
            }
            guard let summary else {
                self.phase = .failed("协议流异常结束")
                return
            }
            let failed = summary.failed ?? 0
            let skipped = summary.skipped ?? 0
            let done = (summary.items ?? ids.count) - failed - skipped
            self.phase = .report(done: max(0, done), failed: failed, skipped: skipped)
        }
    }

    func backToList() {
        states = [:]
        phase = tasks.isEmpty ? .loading : .list
    }

    // MARK: - 分组表（闭合枚举，与 lib/optimize/tasks.sh 的 case 表对齐）

    // 纯查表，与主线程无关；nonisolated 使 TaskRow（非隔离上下文）可同步调用
    nonisolated static func category(of action: String) -> Category {
        switch action {
        case "cache_refresh", "saved_state_cleanup", "sqlite_vacuum",
             "memory_pressure_relief", "dock_refresh", "notification_cleanup",
             "coreduet_cleanup":
            return .routine
        case "fix_broken_configs", "launch_services_rebuild", "shared_file_list_repair",
             "quarantine_cleanup", "prevent_network_dsstore", "spotlight_orphan_rules_cleanup",
             "launch_agents_cleanup", "login_items_audit":
            return .fixes
        default:
            // system_maintenance / periodic_maintenance / network_* /
            // disk_* / spotlight_index_optimize 及未来新增 → 深度维护
            return .deep
        }
    }
}
