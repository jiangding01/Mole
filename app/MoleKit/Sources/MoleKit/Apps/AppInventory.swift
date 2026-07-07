import Foundation

/// `mole robot apps list` 输出的已安装应用（协议 §4.2 文档型例外：
/// 一次性 JSON 数组，非 NDJSON 事件流）。字段与 bin/uninstall.sh
/// `uninstall_list_apps` 的 JSON 分支逐一对应。
public struct InstalledApp: Codable, Sendable, Identifiable {
    public var name: String
    public var bundleId: String
    /// "App"（手动安装）或 "Homebrew"（cask 管理）。
    public var source: String
    /// 卸载时使用的名称（Homebrew 时为 cask 名）。
    public var uninstallName: String
    public var path: String
    /// 展示用体积字符串（核心 bytes_to_human 输出，如 "1.2GB"；未知为 "N/A"）。
    public var size: String

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, source, path, size
        case bundleId = "bundle_id"
        case uninstallName = "uninstall_name"
    }

    /// 体积近似字节数（排序与合计用；"N/A" → nil）。
    public var sizeBytes: UInt64? {
        Self.parseBytes(size)
    }

    static func parseBytes(_ display: String) -> UInt64? {
        let trimmed = display.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000), ("GB", 1_000_000_000),
            ("MB", 1_000_000), ("KB", 1_000), ("B", 1),
        ]
        let upper = trimmed.uppercased()
        for (suffix, factor) in units {
            if upper.hasSuffix(suffix) {
                let number = upper.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let value = Double(number), value >= 0 {
                    return UInt64(value * factor)
                }
                return nil
            }
        }
        return nil
    }
}

/// 文档型 robot 命令客户端：整体捕获 stdout 再解码（区别于 RobotSession 的行流）。
public struct AppInventoryClient: Sendable {
    private let coreLocator: CoreBundleLocator

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum InventoryError: LocalizedError {
        case robotError(message: String)
        case malformedOutput

        public var errorDescription: String? {
            switch self {
            case let .robotError(message): message
            case .malformedOutput: "apps list 输出无法解析"
            }
        }
    }

    /// 全量扫描已装应用。首次运行核心侧要统计体积，可能需要数秒。
    public func list() async throws -> [InstalledApp] {
        let moleURL = try coreLocator.moleEntrypoint()
        let data = try await Self.capture(executable: moleURL, arguments: ["robot", "apps", "list"])
        return try Self.decode(data)
    }

    /// 解码：优先按应用数组；失败则尝试识别 robot 的 NDJSON error 事件给出可读原因。
    static func decode(_ data: Data) throws -> [InstalledApp] {
        let decoder = JSONDecoder()
        if let apps = try? decoder.decode([InstalledApp].self, from: data) {
            return apps
        }
        if let line = data.split(separator: UInt8(ascii: "\n")).first,
           let robotError = try? decoder.decode(RobotError.self, from: Data(line)),
           !robotError.code.isEmpty {
            throw InventoryError.robotError(message: robotError.message ?? robotError.code)
        }
        throw InventoryError.malformedOutput
    }

    private static func capture(executable: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        // 无人排空的 stderr Pipe 会在 64KB 反压时死锁子进程：直接丢弃
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 先读到 EOF 再等退出：反过来会在输出超过管道缓冲时互相等死。
        let handle = stdout.fileHandleForReading
        let data = await Task.detached { handle.readDataToEndOfFile() }.value
        await Task.detached { process.waitUntilExit() }.value
        return data
    }
}
