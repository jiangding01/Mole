import Foundation

/// 登录项 / 后台服务的一条记录（`mole robot launchitems list` 的一条 item）。
/// 契约见 docs/MAC_APP_DESIGN.md §5.2.3：
///   id 前缀 → 类别（login: / agent: 可操作，agent-sys: / daemon: 只读）
///   detail 四段 " · " = `<type> · <enabled> · <sys> · <owner|->`
public struct LaunchItem: Sendable, Identifiable, Equatable {
    /// 类别（由 id 前缀决定，比 detail 的 type 更细：区分用户/系统 LaunchAgent）。
    public enum Category: String, Sendable, Equatable {
        case login // 登录项（osascript 管理，可操作）
        case agent // 用户 LaunchAgent（可操作）
        case agentSystem // 系统 LaunchAgent（只读）
        case daemon // 系统 LaunchDaemon（只读）

        /// 归入 UI 的哪一组：login → 登录项；其余 → 后台服务。
        public var isLogin: Bool {
            self == .login
        }
    }

    /// robot id，形如 `login:<name>` / `agent:<label>` / `agent-sys:<label>` / `daemon:<label>`。
    public var id: String
    /// 展示名。
    public var label: String
    /// plist 或 app 路径（可空）。
    public var path: String
    public var category: Category
    /// 是否启用（登录项恒 true；用户 agent 依据 launchctl disabled map）。
    public var enabled: Bool
    /// 是否系统项（任意 /Library 项或 com.apple.* label）。系统项整行只读。
    public var sys: Bool
    /// 归属应用名（core 侧从程序绝对路径推导；"-" → nil）。
    public var owner: String?

    public init(
        id: String,
        label: String,
        path: String,
        category: Category,
        enabled: Bool,
        sys: Bool,
        owner: String?
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.category = category
        self.enabled = enabled
        self.sys = sys
        self.owner = owner
    }

    /// 是否可开关：只有用户级 login / agent 且非系统项才可变（镜像 CLI `_li_is_system_id` 守卫）。
    public var mutable: Bool {
        (category == .login || category == .agent) && !sys
    }

    /// 解析一条 robot item；字段缺失/未知前缀时返回 nil（跳过不崩）。
    static func parse(_ item: RobotItem) -> LaunchItem? {
        let category: Category
        if item.id.hasPrefix("login:") {
            category = .login
        } else if item.id.hasPrefix("agent-sys:") {
            category = .agentSystem
        } else if item.id.hasPrefix("agent:") {
            category = .agent
        } else if item.id.hasPrefix("daemon:") {
            category = .daemon
        } else {
            return nil
        }
        let label = item.label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        // detail 四段以 " · " 分隔：type / enabled / sys / owner。owner 可能为空字符串。
        let parts = (item.detail ?? "").components(separatedBy: " · ")
        guard parts.count >= 4 else { return nil }
        let enabled = parts[1].trimmingCharacters(in: .whitespaces) == "true"
        let sys = parts[2].trimmingCharacters(in: .whitespaces) == "true"
        let ownerRaw = parts[3].trimmingCharacters(in: .whitespaces)
        let owner = (ownerRaw.isEmpty || ownerRaw == "-") ? nil : ownerRaw
        return LaunchItem(
            id: item.id, label: label, path: item.path ?? "",
            category: category, enabled: enabled, sys: sys, owner: owner
        )
    }
}

/// 一次 disable/enable 的逐条结果（robot result 事件）。
public struct LaunchItemResult: Sendable, Equatable {
    /// 状态：disabled / enabled / skipped_system / skipped_missing / failed。
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }

    /// 请求 enable 时期望 "enabled"，disable 时期望 "disabled"；据此判定乐观更新是否成立。
    public func succeeded(forEnabling enabling: Bool) -> Bool {
        status == (enabling ? "enabled" : "disabled")
    }
}
