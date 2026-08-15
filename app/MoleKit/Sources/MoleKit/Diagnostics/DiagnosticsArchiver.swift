import Foundation

/// 诊断报告打包（设计 CHANGELOG §3.2）：把一个已收集好素材的目录用 `/usr/bin/zip`
/// 打包成一个 zip 文件。子进程仅在 MoleKit 内发起（架构红线，同 RobotSession）——
/// Settings 层（Features/）不得直接调用 Process()。
public struct DiagnosticsArchiver: Sendable {
    public enum ArchiverError: LocalizedError, Equatable {
        case sourceNotFound
        case zipUnavailable
        case zipFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound: "诊断素材目录不存在"
            case .zipUnavailable: "系统 zip 工具不可用"
            case let .zipFailed(code): "打包失败（zip 退出码 \(code)）"
            }
        }
    }

    private static let zipExecutable = "/usr/bin/zip"

    public init() {}

    /// 把 `sourceDirectory` 下的全部内容打包为 `destination`（覆盖同名文件）。
    /// `sourceDirectory` 必须已存在，否则抛 `sourceNotFound`（不存在的路径可复现测试）。
    public func archive(sourceDirectory: URL, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.runZip(sourceDirectory: sourceDirectory, destination: destination)
        }.value
    }

    private static func runZip(sourceDirectory: URL, destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ArchiverError.sourceNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: zipExecutable) else {
            throw ArchiverError.zipUnavailable
        }
        // 目标若已存在先移除，避免 zip 对旧内容做增量合并（同日重复导出应得到全新压缩包）。
        try? FileManager.default.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zipExecutable)
        // cwd 设到源目录内部，令压缩包内条目为相对路径（"." 而不是绝对路径）。
        // -r 递归 / -X 不含额外 mac 扩展属性 / -q 静默。
        process.currentDirectoryURL = sourceDirectory
        process.arguments = ["-r", "-X", "-q", destination.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiverError.zipFailed(process.terminationStatus)
        }
    }
}
