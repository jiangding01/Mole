import Foundation

// 操作历史模型（设计 §5.6 历史页）。
//
// 数据全部来自只读 CLI 命令 `mole robot history list`，两路合流：
// - sessions：`operations.log` 会话结束标记（命令、结束时间、项数、释放总量）
// - deletions：`deletions.log` 逐条删除审计（时间戳、模式、大小、状态、路径）
// deletions 按时间戳归入所属会话（join 规则见 `HistoryReader`）。
//
// 只读、不可变：本模块绝不发起任何删除；恢复由用户在废纸篓自行完成。

/// 一次已完成的操作会话（一张历史卡）。
public struct HistorySession: Identifiable, Sendable, Equatable {
    public let id: String
    /// 原始命令名：clean / uninstall / optimize / purge（决定图标与标题）。
    public let command: String
    /// 会话结束时间（operations.log 结束标记的本地时间）。
    public let endedAt: Date
    /// 会话处理项数（结束标记里的 "N items"）。
    public let itemCount: Int
    /// 会话释放总字节数（结束标记里的 SIZE，未知为 0）。
    public let freedBytes: Int64
    /// 归入本会话的逐条删除记录（按时间升序）。
    public var deletions: [HistoryDeletion]

    public init(
        id: String,
        command: String,
        endedAt: Date,
        itemCount: Int,
        freedBytes: Int64,
        deletions: [HistoryDeletion] = []
    ) {
        self.id = id
        self.command = command
        self.endedAt = endedAt
        self.itemCount = itemCount
        self.freedBytes = freedBytes
        self.deletions = deletions
    }
}

/// 一条删除审计记录（会话展开后的明细行）。
public struct HistoryDeletion: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    /// 删除大小字节数。**0 表示未知**（CLI 侧 size_kb 为 "unknown" 时折叠为 0，
    /// GUI 展示 "—" 而非谎报 0），详见 `HistoryReader` 注释。
    public let bytes: Int64
    /// 删除发生时间（deletions.log 的 ISO8601 本地时间戳）。
    public let timestamp: Date
    /// 删除模式：trash / perm 等。
    public let mode: String
    /// 删除状态：ok / skipped_* / failed 等。
    public let status: String

    public init(
        id: String,
        path: String,
        bytes: Int64,
        timestamp: Date,
        mode: String,
        status: String
    ) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.timestamp = timestamp
        self.mode = mode
        self.status = status
    }
}
