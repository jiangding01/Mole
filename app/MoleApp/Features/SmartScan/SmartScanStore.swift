import Foundation
import MoleKit
import Observation

/// 智能扫描首页 Store（设计 §5.0 / §6.1）。
///
/// 状态机：idle → scanning（一次 `robot clean plan` 流式扫描）→ results（四结论卡）/ failed。
///
/// 数据来源（已核对 CLI 侧 `lib/core/robot.sh` 与 `bin/robot.sh`）：
/// - 一次 `robot clean plan` 即产出全部四卡所需的原料，按 section slug 分桶：
///   - 卡01 可安全清理：除 `app_leftovers` 外全部可删 item 的 bytes 之和。
///   - 卡02 卸载残留：`app_leftovers` section 的 item 计数 + bytes（→ 软件页）。
///   - 卡03 安装包：clean 域**不产出**安装包 section（robot 也无 installer 域），
///     故默认降级；若未来 CLI 新增 installers/downloads section 会自动点亮。
///   - 卡04 空间洞察：`large_files` / `system_data_clues` 的 insight 事件（取最大者）；
///     无 insight（磁盘无达标大文件）则降级。
/// - done 时组装 DomainPlan 写入 ScanSession(.clean)，清理页可零重扫复用。
@Observable
@MainActor
final class SmartScanStore {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case failed(String)
    }

    /// 卡04 空间洞察数据（最大目录）。
    struct Insight: Equatable {
        /// insight.label 即路径（CLI `robot_emit_insight` 以 path 作 label）。
        var path: String
        /// nil = 协议里的"大小未知"（测量超时），显示为 "—" 而不是 0。
        var bytes: Int64?
    }

    /// results 态的四卡 + 甜甜圈数据（一次扫描组装，UI 只读）。
    struct Results: Equatable {
        var safeBytes: Int64 = 0
        var leftoverCount: Int = 0
        var leftoverBytes: Int64 = 0
        var installerCount: Int = 0
        var installerBytes: Int64 = 0
        /// clean 域当前不产出安装包 section；为 false 时卡03 走降级态。
        var hasInstallers: Bool = false
        var insight: Insight?
        /// 洞察事件总数（results 头部 "N insight found"）。
        var insightCount: Int = 0
        /// 环心总量 = safe + leftover + installer。
        var totalReclaimableBytes: Int64 = 0
        /// plan 0 项：诚实呈现零值 results，不造假。
        var isEmpty: Bool = true
    }

    var phase: Phase = .idle

    // MARK: 扫描中（progress 事件驱动）

    /// 环心大数字：实时累计可回收字节（progress.bytes_found）。
    private(set) var reclaimableBytes: Int64 = 0
    /// 当前扫描路径（progress.current），scanning 态路径轮播行。
    private(set) var currentPath: String = ""
    private(set) var scanStartedAt = Date()

    // MARK: results

    private(set) var results = Results()
    /// 甜甜圈 750ms reveal 起点。
    private(set) var resultsRevealStart = Date()

    // MARK: idle 元信息条（全部真实，缺则 UI 显示 "—"）

    private(set) var lastScan: Date?
    private(set) var lastFreedBytes: Int64?
    private(set) var diskFreeBytes: Int64?
    private(set) var diskTotalBytes: Int64?

    /// 由 SmartScanView 在 .task 注入（写回扫描结果供跨页复用）。
    var scanSession: ScanSession?

    private var session: RobotSession?
    private var cancelRequested = false

    private static let lastScanKey = "smart.lastScanAt"
    private static let lastDurationKey = "smart.lastScanDuration"

    /// 上次完整扫描的真实用时（秒）。idle 文案用它替代设计 mock 的
    /// "约需 30 秒"——真机是分钟量级，承诺要用真实历史说话（信任承诺①）。
    private(set) var lastScanDuration: TimeInterval?

    init() {
        if let ts = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Double {
            lastScan = Date(timeIntervalSince1970: ts)
        }
        if let dur = UserDefaults.standard.object(forKey: Self.lastDurationKey) as? Double, dur > 0 {
            lastScanDuration = dur
        }
    }

    // MARK: - 扫描

    func startScan() {
        guard phase != .scanning else { return }
        reset()
        phase = .scanning
        scanStartedAt = Date()
        cancelRequested = false
        let session = RobotSession()
        self.session = session
        Task { [weak self] in
            var items: [RobotItem] = []
            var insights: [RobotInsight] = []
            var donePlanId: String?
            var robotError: RobotError?
            do {
                let command = RobotSession.Command(domain: "clean", verb: "plan")
                for try await event in session.run(command) {
                    guard let self else { return }
                    switch event {
                    case let .progress(progress):
                        if let bytes = progress.bytesFound { reclaimableBytes = bytes }
                        if let current = progress.current, !current.isEmpty { currentPath = current }
                    case let .item(item):
                        items.append(item)
                    case let .insight(insight):
                        insights.append(insight)
                    case let .done(done):
                        donePlanId = done.planId
                    case let .error(error):
                        robotError = error
                    default: break
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard let self else { return }
            if cancelRequested {
                phase = .idle
                return
            }
            if let robotError {
                phase = .failed("\(robotError.code): \(robotError.message ?? "")")
                return
            }
            guard let donePlanId else {
                phase = .failed("协议流异常结束")
                return
            }
            ingest(planId: donePlanId, items: items, insights: insights)
        }
    }

    /// 停止扫描：SIGTERM，回 idle（§4.4）。
    func stopScan() {
        cancelRequested = true
        session?.cancel()
    }

    /// 重新扫描：作废旧 plan 后重跑（§5.0 规则 3）。
    func rescan() {
        scanSession?.invalidate(.clean)
        startScan()
    }

    private func ingest(planId: String, items: [RobotItem], insights: [RobotInsight]) {
        var r = Results()
        for item in items {
            let bytes = item.bytes ?? 0
            switch item.section {
            case "app_leftovers", "leftovers":
                r.leftoverCount += 1
                r.leftoverBytes += bytes
            case "installers", "installer", "downloads":
                r.installerCount += 1
                r.installerBytes += bytes
                r.hasInstallers = true
            default:
                r.safeBytes += bytes
            }
        }
        // 守卫事件（guard_skipped）不是空间洞察：它属于清理确认页的提示条，
        // 混进结论卡会把"被挡应用名"当成最大目录展示。
        let spaceInsights = insights.filter { $0.section != "guard_skipped" }
        if let top = spaceInsights.max(by: { ($0.bytes ?? 0) < ($1.bytes ?? 0) }) {
            r.insight = Insight(path: top.label, bytes: top.bytes)
        }
        r.insightCount = spaceInsights.count
        r.totalReclaimableBytes = r.safeBytes + r.leftoverBytes + r.installerBytes
        r.isEmpty = items.isEmpty
        results = r
        reclaimableBytes = r.totalReclaimableBytes

        // 写入会话资产：清理页可零重扫复用同一 plan（§5.0）。
        scanSession?.store(
            ScanSession.DomainPlan(planId: planId, items: items, insights: insights, createdAt: Date()),
            for: .clean
        )

        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastScanKey)
        lastScan = now
        // 只有真实完整扫描记录用时（会话 plan 复用不走这里）。
        let duration = now.timeIntervalSince(scanStartedAt)
        if duration > 1 {
            UserDefaults.standard.set(duration, forKey: Self.lastDurationKey)
            lastScanDuration = duration
        }
        resultsRevealStart = now
        phase = .results
    }

    private func reset() {
        reclaimableBytes = 0
        currentPath = ""
        results = Results()
    }

    // MARK: - idle 元信息加载（纯只读，无子进程/删除）

    /// 进入 idle 时刷新元信息条：磁盘容量（Foundation 只读）+ 最近一次释放量（历史）。
    func loadIdleMeta() {
        loadDiskCapacity()
        loadLastFreed()
    }

    private func loadDiskCapacity() {
        Task { [weak self] in
            let caps = await Task.detached { () -> (Int64, Int64)? in
                let path = NSHomeDirectory()
                guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
                      let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
                      let total = (attrs[.systemSize] as? NSNumber)?.int64Value
                else { return nil }
                return (free, total)
            }.value
            guard let self, let caps else { return }
            diskFreeBytes = caps.0
            diskTotalBytes = caps.1
        }
    }

    private func loadLastFreed() {
        Task { [weak self] in
            let reader = HistoryReader()
            let sessions = try? await reader.load(sessionLimit: 1)
            guard let self else { return }
            lastFreedBytes = sessions?.first?.freedBytes
        }
    }
}
