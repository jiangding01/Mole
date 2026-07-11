import Foundation

/// 白名单客户端（robot 域 `whitelist`）。
/// - `list(mode:)`：只读枚举某模式下的全部 pattern。
/// - `add(pattern:mode:)` / `remove(pattern:mode:)`：即时落盘，返回回吐的更新后完整列表。
///
/// 子进程只在 MoleKit 内发起（架构红线）。add/remove 幂等：core 侧对重复 add / 不存在的
/// remove 静默处理，始终回吐当前完整列表。姿态与 LaunchItemsClient 一致。
public struct WhitelistClient: Sendable {
    private let coreLocator: CoreBundleLocator

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum WhitelistError: LocalizedError, Equatable {
        case robotError(String)
        case malformedStream

        public var errorDescription: String? {
            switch self {
            case let .robotError(message): message
            case .malformedStream: "白名单流异常结束"
            }
        }
    }

    /// 枚举某模式下的全部 pattern。
    public func list(mode: WhitelistMode) async throws -> [WhitelistEntry] {
        try await run(verb: "list", mode: mode, pattern: nil)
    }

    /// 新增一条 pattern（core 侧即时落盘），返回更新后的完整列表。
    public func add(pattern: String, mode: WhitelistMode) async throws -> [WhitelistEntry] {
        try await run(verb: "add", mode: mode, pattern: pattern)
    }

    /// 移除一条 pattern（core 侧即时落盘），返回更新后的完整列表。
    public func remove(pattern: String, mode: WhitelistMode) async throws -> [WhitelistEntry] {
        try await run(verb: "remove", mode: mode, pattern: pattern)
    }

    /// 统一执行：三个 verb 都对每个 pattern 回吐 item + 一个 done。
    /// robot error 抛错；缺 done 抛 malformedStream。
    private func run(verb: String, mode: WhitelistMode, pattern: String?) async throws -> [WhitelistEntry] {
        var arguments = ["--mode", mode.rawValue]
        if let pattern { arguments.append(pattern) }
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(domain: "whitelist", verb: verb, arguments: arguments)
        var entries: [WhitelistEntry] = []
        var done = false
        var robotError: RobotError?
        for try await event in session.run(command) {
            switch event {
            case let .item(item):
                if let entry = WhitelistEntry.parse(item, mode: mode) { entries.append(entry) }
            case .done:
                done = true
            case let .error(error):
                robotError = error
            default:
                break
            }
        }
        if let robotError {
            throw WhitelistError.robotError(robotError.message ?? robotError.code)
        }
        guard done else { throw WhitelistError.malformedStream }
        return entries
    }
}
