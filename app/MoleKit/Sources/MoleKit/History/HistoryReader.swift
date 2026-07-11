import Foundation

/// 操作历史读取器：并发跑两路只读 robot 命令，解析 NDJSON item 事件，
/// 把 deletions 归入所属会话后按新→旧返回（设计 §5.6）。
///
/// 子进程只在 MoleKit 内发起（架构红线）；robot 定位复用 `CoreBundleLocator`。
public struct HistoryReader: Sendable {
    private let coreLocator: CoreBundleLocator

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum HistoryError: LocalizedError {
        case robotError(message: String)

        public var errorDescription: String? {
            switch self {
            case let .robotError(message): message
            }
        }
    }

    /// 拉取历史。两路命令并发执行（各自独立子进程），完成后本地合流。
    /// - Parameters:
    ///   - sessionLimit: 会话取最近 N 条。
    ///   - deletionLimit: 删除明细取最近 N 条。须远大于会话数——单次清理
    ///     常删数百项，太小会截断明细、令较旧会话展开后为空；CLI 侧是
    ///     `tail -n`，大值无额外成本。
    /// - Returns: 会话列表，最新的排在最前。
    public func load(sessionLimit: Int = 100, deletionLimit: Int = 5000) async throws -> [HistorySession] {
        let locator = coreLocator
        async let sessionItems = Self.collectItems(
            coreLocator: locator,
            arguments: ["--limit", String(sessionLimit)]
        )
        async let deletionItems = Self.collectItems(
            coreLocator: locator,
            arguments: ["--limit", String(deletionLimit), "--deletions"]
        )

        let sessions = try await sessionItems.compactMap(Self.parseSession)
        let deletions = try await deletionItems.compactMap(Self.parseDeletion)
        return Self.join(sessions: sessions, deletions: deletions)
    }

    // MARK: - 子进程收集

    /// 跑一路 `mole robot history list …`，收集全部 item 事件；遇 error 事件抛出。
    /// 每次调用创建独立 `RobotSession`，避免跨并发任务共享非 Sendable 状态。
    private static func collectItems(
        coreLocator: CoreBundleLocator,
        arguments: [String]
    ) async throws -> [RobotItem] {
        let session = RobotSession(coreLocator: coreLocator)
        let command = RobotSession.Command(domain: "history", verb: "list", arguments: arguments)
        var items: [RobotItem] = []
        for try await event in session.run(command) {
            switch event {
            case let .item(item): items.append(item)
            case let .error(error):
                throw HistoryError.robotError(message: error.message ?? error.code)
            default: break
            }
        }
        return items
    }

    // MARK: - 解析

    /// 会话结束时间格式：`operations.log` 用本地 `date` 无时区偏移（如 "2026-07-08 00:21:27"）。
    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 删除时间戳格式：`deletions.log` 用 `date '+%Y-%m-%dT%H:%M:%S%z'`（如 "2026-07-08T00:21:27+0800"）。
    private static let deletionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    /// sessions item：label=命令；bytes=释放总量；detail="<ts> · <N> items"。
    private static func parseSession(_ item: RobotItem) -> HistorySession? {
        // detail 用 " · " 分隔（ts 内部只含一个普通空格，不会误切）。
        let parts = (item.detail ?? "").components(separatedBy: " · ")
        guard parts.count >= 1 else { return nil }
        let tsString = parts[0].trimmingCharacters(in: .whitespaces)
        guard let endedAt = sessionDateFormatter.date(from: tsString) else { return nil }
        // "N items" → 取前导整数。
        let count = parts.count >= 2 ? Int(parts[1].prefix { $0.isNumber }) ?? 0 : 0
        return HistorySession(
            id: item.id,
            command: item.label,
            endedAt: endedAt,
            itemCount: count,
            freedBytes: item.bytes ?? 0
        )
    }

    /// deletions item：path=路径；bytes=大小（unknown→0）；detail="<ts> <mode> <status>"。
    private static func parseDeletion(_ item: RobotItem) -> HistoryDeletion? {
        guard let path = item.path, !path.isEmpty else { return nil }
        // detail 三段以空格分隔：ts / mode / status（三者本身都不含空格）。
        let fields = (item.detail ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard let tsField = fields.first,
              let timestamp = deletionDateFormatter.date(from: String(tsField))
        else { return nil }
        let mode = fields.count >= 2 ? String(fields[1]) : ""
        let status = fields.count >= 3 ? String(fields[2]) : ""
        return HistoryDeletion(
            id: item.id,
            path: path,
            bytes: item.bytes ?? 0,
            timestamp: timestamp,
            mode: mode,
            status: status
        )
    }

    // MARK: - 合流（join）

    /// 把 deletions 归入所属会话，返回最新在前的会话列表。
    ///
    /// join 规则：会话只有结束时间（operations.log 无独立开始时间），故用相邻会话
    /// 边界推断——一条删除归入「结束时间 ≥ 删除时间」的**最早**会话（删除发生在该
    /// 次运行期间、早于结束标记；上界即本会话结束，下界即上一会话结束）。
    /// 排在最后一个会话结束之后的孤儿删除无从归属，直接丢弃（设计约定）。
    static func join(sessions: [HistorySession], deletions: [HistoryDeletion]) -> [HistorySession] {
        // 按结束时间升序，便于「最早满足」判定。
        var ordered = sessions.sorted { $0.endedAt < $1.endedAt }
        for deletion in deletions {
            guard let idx = ordered.firstIndex(where: { $0.endedAt >= deletion.timestamp }) else {
                continue // 孤儿：晚于所有会话，丢弃。
            }
            ordered[idx].deletions.append(deletion)
        }
        // 组内删除按时间升序稳定排列。
        for i in ordered.indices {
            ordered[i].deletions.sort { $0.timestamp < $1.timestamp }
        }
        // 展示：最新会话在最前。
        return ordered.reversed()
    }
}
