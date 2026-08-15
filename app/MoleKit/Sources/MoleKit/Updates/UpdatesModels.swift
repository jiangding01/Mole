import Foundation

/// 可更新的应用（`mole robot apps updates list` 的一条 item）。
/// 契约见 docs/MAC_APP_DESIGN.md §5.2.2：v1 只检测 Homebrew cask，
/// id=`cask:<token>`，detail 三段 " · " = `<source> · <installed> · <latest>`。
public struct AppUpdate: Sendable, Identifiable, Equatable {
    /// robot id，形如 `cask:<token>`；升级时原样回传。
    public var id: String
    /// cask token（= item.label），展示名与升级名。
    public var token: String
    /// 原始来源标记（v1 恒为 `brew-cask`）。
    public var sourceRaw: String
    /// 已安装版本。
    public var installed: String
    /// 可升级到的最新版本。
    public var latest: String

    public init(id: String, token: String, sourceRaw: String, installed: String, latest: String) {
        self.id = id
        self.token = token
        self.sourceRaw = sourceRaw
        self.installed = installed
        self.latest = latest
    }

    /// 展示用来源徽标（v1 只有 Homebrew：`brew-cask` → "Homebrew"）。
    public var sourceDisplay: String {
        sourceRaw == "brew-cask" ? "Homebrew" : sourceRaw
    }

    /// 能否在 Mole 内一键更新（委托 brew）。跳转类来源（App Store /
    /// Sparkle / Electron，v1.2+ 检测）只做引导，Mole 不代为执行。
    public var isBrewManaged: Bool {
        sourceRaw == "brew-cask"
    }

    /// 解析一条 robot item 为更新条目。字段缺失/格式异常时返回 nil（跳过，不崩）。
    /// detail 以 " · " 分三段；版本号本身不含 " · "，切分无歧义（与 HistoryReader 同姿态）。
    static func parse(_ item: RobotItem) -> AppUpdate? {
        guard item.id.hasPrefix("cask:") else { return nil }
        let token = item.label.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        let parts = (item.detail ?? "").components(separatedBy: " · ")
        guard parts.count >= 3 else { return nil }
        let source = parts[0].trimmingCharacters(in: .whitespaces)
        let installed = parts[1].trimmingCharacters(in: .whitespaces)
        let latest = parts[2].trimmingCharacters(in: .whitespaces)
        guard !installed.isEmpty, !latest.isEmpty else { return nil }
        return AppUpdate(id: item.id, token: token, sourceRaw: source, installed: installed, latest: latest)
    }
}
