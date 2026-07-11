import Foundation

/// 登录项 / 后台服务客户端（robot 域 `launchitems`）。
/// - `list()`：只读枚举登录项 + LaunchAgents/Daemons。
/// - `setEnabled(ids:enabled:)`：用户级、可逆开关（ids 经 stdin 一行一个）。
///
/// 子进程只在 MoleKit 内发起（架构红线）。系统项与缺失项由 core 侧拒绝并回报
/// skipped_system / skipped_missing，本层原样透传给 Store 决定回滚。
public struct LaunchItemsClient: Sendable {
    private let coreLocator: CoreBundleLocator

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum LaunchItemsError: LocalizedError, Equatable {
        case robotError(String)
        case malformedStream

        public var errorDescription: String? {
            switch self {
            case let .robotError(message): message
            case .malformedStream: "启动项流异常结束"
            }
        }
    }

    /// 枚举全部登录项与后台服务。
    public func list() async throws -> [LaunchItem] {
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(domain: "launchitems", verb: "list")
        var items: [LaunchItem] = []
        var robotError: RobotError?
        for try await event in session.run(command) {
            switch event {
            case let .item(item):
                if let parsed = LaunchItem.parse(item) { items.append(parsed) }
            case let .error(error):
                robotError = error
            default:
                break
            }
        }
        if let robotError {
            throw LaunchItemsError.robotError(robotError.message ?? robotError.code)
        }
        return items
    }

    /// 批量开关。`enabled=true` → `launchitems enable`，否则 `disable`。
    /// ids 走 stdin（bash 3.2 线协议：一行一个，复用 RobotSession 的 stdin 通道，
    /// 与 apps apply 同姿态）。返回逐条 result；done 收尾缺失时抛 malformedStream。
    public func setEnabled(ids: [String], enabled: Bool) async throws -> [LaunchItemResult] {
        guard !ids.isEmpty else { return [] }
        let verb = enabled ? "enable" : "disable"
        let payload = Data((ids.joined(separator: "\n") + "\n").utf8)
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(
            domain: "launchitems", verb: verb, stdinPayload: payload
        )
        var results: [LaunchItemResult] = []
        var done = false
        var robotError: RobotError?
        for try await event in session.run(command) {
            switch event {
            case let .result(result):
                results.append(LaunchItemResult(id: result.id, status: result.status))
            case .done:
                done = true
            case let .error(error):
                robotError = error
            default:
                break
            }
        }
        if let robotError {
            throw LaunchItemsError.robotError(robotError.message ?? robotError.code)
        }
        guard done else { throw LaunchItemsError.malformedStream }
        return results
    }
}
