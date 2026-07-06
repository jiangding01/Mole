import Foundation

/// 定位 App 内嵌的 mole-core（设计 §3.2 / §7.5）。
/// 完整性校验：启动子进程前比对入口脚本与二进制 SHA256 清单（Phase 1 落地）。
public struct CoreBundleLocator: Sendable {
    public enum LocatorError: Error {
        case coreNotBundled
    }

    /// 覆盖用：测试/开发期指向源码树的 mole（MOLE_CORE_PATH 环境变量）。
    private let overridePath: String?

    public init(overridePath: String? = ProcessInfo.processInfo.environment["MOLE_CORE_PATH"]) {
        self.overridePath = overridePath
    }

    public func moleEntrypoint() throws -> URL {
        if let overridePath {
            return URL(fileURLWithPath: overridePath)
        }
        guard let resourceURL = Bundle.main.resourceURL else {
            throw LocatorError.coreNotBundled
        }
        let candidate = resourceURL.appendingPathComponent("mole-core/mole")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw LocatorError.coreNotBundled
        }
        // TODO(Phase 1): SHA256 清单校验（§7.5），不匹配即拒绝执行并提示重装。
        return candidate
    }

    public func statusBinary() throws -> URL {
        try moleEntrypoint().deletingLastPathComponent().appendingPathComponent("status-go")
    }

    public func analyzeBinary() throws -> URL {
        try moleEntrypoint().deletingLastPathComponent().appendingPathComponent("analyze-go")
    }
}
