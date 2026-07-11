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
        // override 必须真实可执行才采用：LSEnvironment 注入的开发路径在别的机器
        // /发布环境下不存在，此时静默落回内嵌核心而不是拿着坏路径去起子进程。
        if let overridePath, FileManager.default.isExecutableFile(atPath: overridePath) {
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

    /// Go 二进制位置：打包核心里在 mole 同级；开发模式（MOLE_CORE_PATH 指向
    /// 源码树）在 `bin/` 子目录（Makefile BIN_DIR）。两处依次探测。
    private func goBinary(_ name: String) throws -> URL {
        let root = try moleEntrypoint().deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent(name),
            root.appendingPathComponent("bin/\(name)"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw LocatorError.coreNotBundled
    }

    /// 读取内嵌核心（mole 脚本）首部的 `VERSION="x.y.z"` 行（关于页展示）。
    /// 纯文件读取，无子进程；核心未打包或读不到时返回 nil（UI 显示 "—"）。
    public func coreVersion() -> String? {
        guard let url = try? moleEntrypoint(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("VERSION=") else { continue }
            let value = trimmed.dropFirst("VERSION=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    public func statusBinary() throws -> URL {
        try goBinary("status-go")
    }

    public func analyzeBinary() throws -> URL {
        try goBinary("analyze-go")
    }
}
