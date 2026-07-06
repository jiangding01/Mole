import Foundation

/// 完全磁盘访问（FDA）探测（设计 §7.2）。
/// 探测法：尝试读取若干 TCC 保护路径，任一可读即视为已授权。
/// Onboarding 轮询 1s；其余场景进入页面时检一次。
public struct PermissionProbe: Sendable {
    public init() {}

    /// TCC 保护探测点（§7.2）。路径存在但 open 被拒 = 未授权；
    /// 路径不存在则跳过该探测点。
    static let probePaths: [String] = [
        NSString(string: "~/Library/Safari/CloudTabs.db").expandingTildeInPath,
        NSString(string: "~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath,
    ]

    public func hasFullDiskAccess() -> Bool {
        for path in Self.probePaths where FileManager.default.fileExists(atPath: path) {
            if FileManager.default.isReadableFile(atPath: path),
               FileHandle(forReadingAtPath: path) != nil {
                return true
            }
        }
        return false
    }

    /// 系统设置深链（§5.7 权限中心）。
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
