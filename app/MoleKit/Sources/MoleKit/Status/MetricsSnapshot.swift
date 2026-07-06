import Foundation

/// `status-go --watch` / `--json` 输出的指标快照（子集）。
/// 字段与 `cmd/status/metrics.go` 的 JSON tag 一一对应；
/// GUI 只解码渲染所需字段，未列字段被 JSONDecoder 忽略（前向兼容）。
/// 状态页规格：设计 §5.5。
public struct MetricsSnapshot: Codable, Sendable {
    public var host: String?
    public var uptime: String?
    public var healthScore: Int?
    public var healthScoreMsg: String?
    public var cpu: CPUStatus?
    public var memory: MemoryStatus?
    public var disks: [DiskStatus]?
    public var trashSize: UInt64?
    public var network: [NetworkStatus]?
    public var batteries: [BatteryStatus]?
    public var thermal: ThermalStatus?
    public var bluetooth: [BluetoothDevice]?
    public var topProcesses: [ProcessInfo]?

    enum CodingKeys: String, CodingKey {
        case host, uptime, cpu, memory, disks, network, batteries, thermal, bluetooth
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case trashSize = "trash_size"
        case topProcesses = "top_processes"
    }

    public struct CPUStatus: Codable, Sendable {
        public var usagePercent: Double?
        public var cores: Int?
        public var load1: Double?

        enum CodingKeys: String, CodingKey {
            case cores, load1
            case usagePercent = "usage_percent"
        }
    }

    public struct MemoryStatus: Codable, Sendable {
        public var usedPercent: Double?
        public var pressurePercent: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case pressurePercent = "pressure_percent"
        }
    }

    public struct DiskStatus: Codable, Sendable {
        public var mountpoint: String?
        public var total: UInt64?
        public var free: UInt64?
    }

    public struct NetworkStatus: Codable, Sendable {
        public var name: String?
        public var uploadRate: Double?
        public var downloadRate: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case uploadRate = "upload_rate"
            case downloadRate = "download_rate"
        }
    }

    public struct BatteryStatus: Codable, Sendable {
        public var percent: Double?
        public var cycleCount: Int?
        public var health: String?

        enum CodingKeys: String, CodingKey {
            case percent, health
            case cycleCount = "cycle_count"
        }
    }

    public struct ThermalStatus: Codable, Sendable {
        public var cpuTemp: Double?
        public var fanSpeed: Int?
        public var fanCount: Int?

        enum CodingKeys: String, CodingKey {
            case cpuTemp = "cpu_temp"
            case fanSpeed = "fan_speed"
            case fanCount = "fan_count"
        }
    }

    public struct BluetoothDevice: Codable, Sendable {
        public var name: String?
        public var connected: Bool?
        public var battery: String?
    }

    public struct ProcessInfo: Codable, Sendable {
        public var pid: Int
        public var ppid: Int?
        public var name: String?
        public var command: String?
        public var cpu: Double?
        public var memoryBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case pid, ppid, name, command, cpu
            case memoryBytes = "memory_bytes"
        }
    }
}

// 注意：Go 侧部分字段名需在 Phase 1 对照 `cmd/status/metrics.go` 校准
// （本文件字段以契约测试锁定，golden 样本取自真实 `status-go --json` 输出）。
