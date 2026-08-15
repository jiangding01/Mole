import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// 诊断报告导出（设计 CHANGELOG §3.2）：收集系统摘要 + mole CLI 日志 + App 自身
/// 错误日志，打包到 `~/Desktop`。Settings 层（Features/）只调这一个 API——
/// 临时目录的创建 / 清理与打包子进程全部封装在 MoleKit（架构红线，同 RobotSession）。
public struct DiagnosticsExporter: Sendable {
    public enum ExportError: LocalizedError, Equatable {
        case desktopUnavailable
        case desktopNotWritable
        case packagingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .desktopUnavailable: "找不到桌面目录"
            case .desktopNotWritable: "桌面目录不可写入（权限不足）"
            case let .packagingFailed(reason): reason
            }
        }
    }

    private let archiver: DiagnosticsArchiver

    public init(archiver: DiagnosticsArchiver = DiagnosticsArchiver()) {
        self.archiver = archiver
    }

    /// 收集素材 + 打包，返回最终 zip 路径（`~/Desktop/Mole-诊断-YYYY-MM-DD.zip`，
    /// 同日重复导出覆盖同名文件）。不含文件内容——只有系统摘要文本与运行日志。
    public func exportReport(date: Date = Date()) async throws -> URL {
        let fileManager = FileManager.default
        guard let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw ExportError.desktopUnavailable
        }
        guard fileManager.isWritableFile(atPath: desktop.path) else {
            throw ExportError.desktopNotWritable
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("mole-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try writeSystemSummary(into: staging)
        copyCLILogs(into: staging)
        copyAppErrorLog(into: staging)

        let destination = desktop.appendingPathComponent(Self.archiveFileName(date: date))
        do {
            try await archiver.archive(sourceDirectory: staging, destination: destination)
        } catch let error as DiagnosticsArchiver.ArchiverError {
            throw ExportError.packagingFailed(error.errorDescription ?? "\(error)")
        }
        return destination
    }

    // MARK: - 文件名

    /// 固定命名格式（设计 §3.2 原文示例），与 App 语言设置无关。
    static func archiveFileName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return "Mole-诊断-\(formatter.string(from: date)).zip"
    }

    // MARK: - 系统摘要

    private func writeSystemSummary(into directory: URL) throws {
        let text = Self.systemSummaryText()
        try text.write(to: directory.appendingPathComponent("system-summary.txt"), atomically: true, encoding: .utf8)
    }

    static func systemSummaryText(date: Date = Date()) -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = sysctlString("hw.model") ?? "unknown"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let generated = ISO8601DateFormatter().string(from: date)
        return """
        Mole Diagnostics Summary
        =========================
        Generated: \(generated)
        macOS: \(osVersion)
        Model: \(model)
        App Version: \(appVersion) (\(appBuild))
        """
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - 日志拷贝（存在才拷，读不到就跳过——不因日志缺失让整个导出失败）

    /// mole CLI 日志目录 `~/Library/Logs/mole/` 下的 `*.log`。
    private func copyCLILogs(into directory: URL) {
        let fileManager = FileManager.default
        let logsDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mole", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else {
            return
        }
        let destDir = directory.appendingPathComponent("cli-logs", isDirectory: true)
        var createdDestDir = false
        for entry in entries where entry.pathExtension == "log" {
            if !createdDestDir {
                guard (try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)) != nil else {
                    return
                }
                createdDestDir = true
            }
            try? fileManager.copyItem(at: entry, to: destDir.appendingPathComponent(entry.lastPathComponent))
        }
    }

    /// App 自身 stderr 落盘日志（v1 尚无专门路径；若未来落地到
    /// `~/Library/Logs/Mole/app.log`，存在即自动纳入，读不到就跳过）。
    private func copyAppErrorLog(into directory: URL) {
        let fileManager = FileManager.default
        let candidate = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mole/app.log")
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        try? fileManager.copyItem(at: candidate, to: directory.appendingPathComponent("app.log"))
    }
}
