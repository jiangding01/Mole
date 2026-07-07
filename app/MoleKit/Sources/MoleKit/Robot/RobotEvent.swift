import Foundation

// Robot Protocol v1 事件模型。
// 规范：docs/MAC_APP_DESIGN.md §4.3（协议演进只加字段不改语义）。
// 契约测试：MoleKitTests/RobotEventDecodingTests 与 CLI 侧共享 golden NDJSON。

/// 一行 NDJSON 解码出的协议事件。
public enum RobotEvent: Sendable, Equatable {
    case progress(RobotProgress)
    case item(RobotItem)
    case insight(RobotInsight)
    case result(RobotResult)
    case taskStatus(RobotTaskStatus)
    case done(RobotDone)
    case error(RobotError)
}

public struct RobotProgress: Codable, Sendable, Equatable {
    public var phase: String?
    public var section: String?
    public var current: String?
    public var done: Int?
    /// 总数未知时核心侧发 -1。
    public var total: Int?
    public var bytesFound: Int64?
    /// 无 FDA 时被拒目录计数（设计 §7.1）。
    public var deniedDirs: Int?

    enum CodingKeys: String, CodingKey {
        case phase, section, current, done, total
        case bytesFound = "bytes_found"
        case deniedDirs = "denied_dirs"
    }
}

public struct RobotItem: Codable, Sendable, Equatable {
    public var id: String
    public var section: String?
    public var label: String
    public var path: String?
    public var bytes: Int64?
    public var kind: String?
    public var reversible: Bool?
    public var defaultSelected: Bool?
    /// safe / caution / info（§4.3 风险三级）。
    public var risk: String?
    public var detail: String?
    /// i18n 稳定键（§4.3）：GUI 优先按 key 本地化，未知 key 回退 detail 原文。
    public var detailKey: String?
    public var detailParams: [String: String]?
    /// 因应用运行被锁定时的归属应用（§5.1 运行应用提示）。
    public var blockedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, section, label, path, bytes, kind, reversible, risk, detail
        case defaultSelected = "default_selected"
        case detailKey = "detail_key"
        case detailParams = "detail_params"
        case blockedBy = "blocked_by"
    }
}

public struct RobotInsight: Codable, Sendable, Equatable {
    public var section: String?
    public var label: String
    public var detail: String?
    public var bytes: Int64?
}

public struct RobotResult: Codable, Sendable, Equatable {
    public var id: String
    /// trashed / deleted / skipped_whitelisted / skipped_protected / skipped_missing / failed
    public var status: String
    public var freedBytes: Int64?
    public var phase: String?
    public var error: RobotErrorPayload?

    enum CodingKeys: String, CodingKey {
        case id, status, phase, error
        case freedBytes = "freed_bytes"
    }
}

public struct RobotTaskStatus: Codable, Sendable, Equatable {
    public var taskId: String
    /// pending / running / done / skipped / failed / needs_admin
    public var status: String
    public var category: String?
    public var detail: String?
    public var durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case status, category, detail
        case taskId = "task_id"
        case durationMs = "duration_ms"
    }
}

public struct RobotDone: Codable, Sendable, Equatable {
    public var ok: Bool
    public var planId: String?
    public var summary: RobotSummary?

    enum CodingKeys: String, CodingKey {
        case ok, summary
        case planId = "plan_id"
    }
}

public struct RobotSummary: Codable, Sendable, Equatable {
    public var items: Int?
    public var bytesTotal: Int64?
    public var selectedDefault: Int?
    public var failed: Int?
    public var skipped: Int?
    public var freedBytes: Int64?
    /// 取消时未处理的剩余项数（apply 优雅取消：完成当前项 → 汇总退出）。
    public var cancelled: Int?

    enum CodingKeys: String, CodingKey {
        case items, failed, skipped, cancelled
        case bytesTotal = "bytes_total"
        case selectedDefault = "selected_default"
        case freedBytes = "freed_bytes"
    }
}

public struct RobotError: Codable, Sendable, Equatable {
    /// 错误码全表：设计 §14.1（E_PLAN_EXPIRED / E_PATH_PROTECTED / …）。
    public var code: String
    public var message: String?
    public var fatal: Bool?
}

public struct RobotErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String?
}

// MARK: - NDJSON 行解码

public enum RobotEventDecodingError: Error, Equatable {
    case notJSON
    case unknownEvent(String)
    case unsupportedVersion(Int)
}

public enum RobotEventDecoder {
    /// 协议版本：仅接受 v1；未来版本按 §4.3 向后兼容策略处理。
    public static let supportedVersion = 1

    public static func decode(line: Data) throws -> RobotEvent {
        struct Envelope: Codable { var v: Int; var event: String }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            throw RobotEventDecodingError.notJSON
        }
        guard envelope.v == supportedVersion else {
            throw RobotEventDecodingError.unsupportedVersion(envelope.v)
        }
        switch envelope.event {
        case "progress": return .progress(try decoder.decode(RobotProgress.self, from: line))
        case "item": return .item(try decoder.decode(RobotItem.self, from: line))
        case "insight": return .insight(try decoder.decode(RobotInsight.self, from: line))
        case "result": return .result(try decoder.decode(RobotResult.self, from: line))
        case "task_status": return .taskStatus(try decoder.decode(RobotTaskStatus.self, from: line))
        case "done": return .done(try decoder.decode(RobotDone.self, from: line))
        case "error": return .error(try decoder.decode(RobotError.self, from: line))
        default: throw RobotEventDecodingError.unknownEvent(envelope.event)
        }
    }
}
