import Foundation

/// 应用更新客户端（robot 域 `apps updates` / `apps update`）。
/// - `list()`：只读检测可更新的 Homebrew cask。
/// - `upgrade(id:)`：委托 `brew upgrade --cask`，消费 task_status 流。
///
/// 子进程只在 MoleKit 内发起（架构红线）。无 brew / 无更新都返回空列表、不抛错
/// （CLI 侧诚实降级为 done items:0），空态文案由 App 层区分呈现。
public struct UpdatesClient: Sendable {
    private let coreLocator: CoreBundleLocator

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum UpdateError: LocalizedError, Equatable {
        /// 升级失败：detail 为 stderr 摘要（core 侧 task_status failed 携带）。
        case upgradeFailed(String)
        /// 非 cask id 等不支持场景（robot E_UNSUPPORTED）。
        case unsupported(String)
        /// 协议流异常结束（没有 done 收尾）。
        case malformedStream

        public var errorDescription: String? {
            switch self {
            case let .upgradeFailed(detail): detail
            case let .unsupported(message): message
            case .malformedStream: "更新流异常结束"
            }
        }
    }

    /// 拉取可在 Mole 内完成的更新（v1：Homebrew cask）。
    public func list() async throws -> [AppUpdate] {
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(domain: "apps", verb: "updates", arguments: ["list"])
        var updates: [AppUpdate] = []
        var robotError: RobotError?
        for try await event in session.run(command) {
            switch event {
            case let .item(item):
                if let update = AppUpdate.parse(item) { updates.append(update) }
            case let .error(error):
                robotError = error
            default:
                break
            }
        }
        if let robotError {
            throw UpdateError.unsupported(robotError.message ?? robotError.code)
        }
        return updates
    }

    /// 委托 `brew upgrade --cask <token>` 升级单个 cask。
    /// 消费 task_status 流：running（进行中）→ 终态。仅 `done` 视为成功返回；
    /// `failed` 抛 upgradeFailed(detail)；`skipped`（dry-run，detail=dry_run）与任何
    /// 未知终态一律按「未生效」抛 upgradeFailed，绝不静默当成功（正常运行不会触发）。
    /// 调用方在 await 之前把该项置为「进行中」，故本方法只在完成/失败时返回或抛出。
    public func upgrade(id: String) async throws {
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(domain: "apps", verb: "update", arguments: ["--id", id])
        var lastTerminal: (status: String, detail: String?)?
        var robotError: RobotError?
        for try await event in session.run(command) {
            switch event {
            case let .taskStatus(status) where status.taskId == id:
                switch status.status {
                case "running", "pending":
                    break // 进行中，无需处理
                default:
                    lastTerminal = (status.status, status.detail) // done / failed / skipped / 未知终态
                }
            case let .error(error):
                robotError = error
            default:
                break
            }
        }
        if let robotError {
            throw UpdateError.unsupported(robotError.message ?? robotError.code)
        }
        guard let terminal = lastTerminal else { throw UpdateError.malformedStream }
        if terminal.status == "done" { return }
        // failed / skipped(dry_run) / 未知终态：一律「未生效」，带上 detail 便于诊断。
        let detail = terminal.detail?.isEmpty == false ? terminal.detail! : terminal.status
        throw UpdateError.upgradeFailed(detail)
    }
}
