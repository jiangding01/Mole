import Foundation

/// `status-go --watch` / `--json` 输出的指标快照。
/// 字段与 `cmd/status/metrics.go` 的 JSON tag **逐一校准**（2026-07-07 对照源码）；
/// GUI 只解码渲染所需字段，未列字段被 JSONDecoder 忽略（前向兼容）。
/// 状态页规格：设计稿 status 页 + docs/MAC_APP_DESIGN.md §5.5。
public struct MetricsSnapshot: Codable, Sendable {
    public var host: String?
    public var uptime: String?
    public var healthScore: Int?
    public var healthScoreMsg: String?
    public var hardware: HardwareInfo?
    public var cpu: CPUStatus?
    public var gpu: [GPUStatus]?
    public var memory: MemoryStatus?
    public var disks: [DiskStatus]?
    public var trashSize: UInt64?
    public var diskIO: DiskIOStatus?
    public var network: [NetworkStatus]?
    public var batteries: [BatteryStatus]?
    public var thermal: ThermalStatus?
    public var bluetooth: [BluetoothDevice]?
    public var topProcesses: [ProcessInfo]?
    /// 持续高 CPU 告警（status-go --proc-cpu-alerts，默认开：阈值 100%、窗口 5 分钟）。
    public var processAlerts: [ProcessAlert]?

    enum CodingKeys: String, CodingKey {
        case host, uptime, hardware, cpu, gpu, memory, disks, network, batteries, thermal, bluetooth
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case trashSize = "trash_size"
        case diskIO = "disk_io"
        case topProcesses = "top_processes"
        case processAlerts = "process_alerts"
    }

    /// 单条持续告警。`triggeredAt` 保持 RFC3339 字符串：快照解码器无日期策略，
    /// 用 Date 会让整帧快照解码失败；换算持续时长由展示层惰性解析。
    public struct ProcessAlert: Codable, Sendable {
        public var pid: Int
        public var name: String?
        public var command: String?
        public var cpu: Double?
        public var threshold: Double?
        public var window: String?
        public var triggeredAt: String?
        public var status: String?

        public init(
            pid: Int, name: String? = nil, command: String? = nil,
            cpu: Double? = nil, threshold: Double? = nil, window: String? = nil,
            triggeredAt: String? = nil, status: String? = nil
        ) {
            self.pid = pid
            self.name = name
            self.command = command
            self.cpu = cpu
            self.threshold = threshold
            self.window = window
            self.triggeredAt = triggeredAt
            self.status = status
        }

        enum CodingKeys: String, CodingKey {
            case pid, name, command, cpu, threshold, window, status
            case triggeredAt = "triggered_at"
        }

        /// 告警已持续的分钟数（triggered_at → 现在），解析失败返回 nil。
        public var sustainedMinutes: Int? {
            guard let triggeredAt else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = iso.date(from: triggeredAt) ?? {
                iso.formatOptions = [.withInternetDateTime]
                return iso.date(from: triggeredAt)
            }()
            guard let date else { return nil }
            return max(0, Int(Date().timeIntervalSince(date) / 60))
        }
    }

    public struct HardwareInfo: Codable, Sendable {
        public var model: String?
        public var cpuModel: String?
        public var totalRAM: String?
        public var osVersion: String?

        enum CodingKeys: String, CodingKey {
            case model
            case cpuModel = "cpu_model"
            case totalRAM = "total_ram"
            case osVersion = "os_version"
        }
    }

    public struct CPUStatus: Codable, Sendable {
        public var usage: Double?
        public var load1: Double?
        public var coreCount: Int?
        public var pCoreCount: Int?
        public var eCoreCount: Int?

        enum CodingKeys: String, CodingKey {
            case usage, load1
            case coreCount = "core_count"
            case pCoreCount = "p_core_count"
            case eCoreCount = "e_core_count"
        }
    }

    public struct GPUStatus: Codable, Sendable {
        public var name: String?
        public var usage: Double?
        public var coreCount: Int?

        enum CodingKeys: String, CodingKey {
            case name, usage
            case coreCount = "core_count"
        }
    }

    public struct MemoryStatus: Codable, Sendable {
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var swapUsed: UInt64?
        /// macOS 内存压力档位：normal / warn / critical（字符串，非百分比）。
        public var pressure: String?

        enum CodingKeys: String, CodingKey {
            case used, total, pressure
            case usedPercent = "used_percent"
            case swapUsed = "swap_used"
        }
    }

    public struct DiskStatus: Codable, Sendable {
        public var mount: String?
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var external: Bool?

        enum CodingKeys: String, CodingKey {
            case mount, used, total, external
            case usedPercent = "used_percent"
        }
    }

    public struct DiskIOStatus: Codable, Sendable {
        public var readRate: Double?
        public var writeRate: Double?

        enum CodingKeys: String, CodingKey {
            case readRate = "read_rate"
            case writeRate = "write_rate"
        }
    }

    public struct NetworkStatus: Codable, Sendable {
        public var name: String?
        /// MB/s（Go 侧已换算）。
        public var rxRateMBs: Double?
        public var txRateMBs: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case rxRateMBs = "rx_rate_mbs"
            case txRateMBs = "tx_rate_mbs"
        }
    }

    public struct BatteryStatus: Codable, Sendable {
        public var percent: Double?
        /// charging / discharging / charged …
        public var status: String?
        public var health: String?
        public var cycleCount: Int?
        /// 最大容量相对出厂的百分比（如 95）。
        public var capacity: Int?

        enum CodingKeys: String, CodingKey {
            case percent, status, health, capacity
            case cycleCount = "cycle_count"
        }
    }

    public struct ThermalStatus: Codable, Sendable {
        public var cpuTemp: Double?
        public var gpuTemp: Double?
        public var fanSpeed: Int?
        public var fanCount: Int?
        public var systemPower: Double?

        enum CodingKeys: String, CodingKey {
            case cpuTemp = "cpu_temp"
            case gpuTemp = "gpu_temp"
            case fanSpeed = "fan_speed"
            case fanCount = "fan_count"
            case systemPower = "system_power"
        }
    }

    public struct BluetoothDevice: Codable, Sendable {
        public var name: String?
        public var connected: Bool?
        public var battery: String?
    }

    public struct ProcessInfo: Codable, Sendable, Identifiable {
        public var pid: Int
        public var ppid: Int?
        public var name: String?
        public var command: String?
        public var cpu: Double?
        public var memoryBytes: UInt64?

        public var id: Int { pid }

        enum CodingKeys: String, CodingKey {
            case pid, ppid, name, command, cpu
            case memoryBytes = "memory_bytes"
        }
    }
}
