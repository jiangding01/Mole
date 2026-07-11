import Foundation

/// 白名单条目（`mole robot whitelist list|add|remove` 的一条 item）。
/// 白名单中的目录不会被扫描或清理；此列表在 GUI 与 CLI 之间共用（设计 §5.7）。
///
/// 清理白名单与优化白名单是两套独立配置（`--mode clean|optimize`），互不影响。
public struct WhitelistEntry: Sendable, Identifiable, Equatable {
    /// robot id，形如 `wl.clean.1` / `wl.optimize.3`（core 侧按序号生成）。
    public var id: String
    /// 目录 pattern（core 侧原样落盘，展示时中间截断）。
    public var pattern: String
    /// 归属模式（清理 / 优化）。
    public var mode: WhitelistMode

    public init(id: String, pattern: String, mode: WhitelistMode) {
        self.id = id
        self.pattern = pattern
        self.mode = mode
    }

    /// 解析一条 robot item；缺 kind 标识或空 pattern 时返回 nil（跳过不崩）。
    static func parse(_ item: RobotItem, mode: WhitelistMode) -> WhitelistEntry? {
        guard item.kind == "whitelist_pattern" else { return nil }
        let pattern = item.label.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        return WhitelistEntry(id: item.id, pattern: pattern, mode: mode)
    }
}

/// 白名单模式：两套独立配置。
public enum WhitelistMode: String, Sendable, CaseIterable, Equatable {
    case clean
    case optimize
}
