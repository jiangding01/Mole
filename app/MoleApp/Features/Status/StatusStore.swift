import AppKit
import MoleKit
import Observation

/// 状态页 Store（设计 §5.5）：订阅指标流、维护采样历史、断连自动重连、
/// 进程排序与受控终止。页面可见时启动、离开即停（RootView 驱动）。
@Observable
@MainActor
final class StatusStore {
    enum Phase: Equatable {
        case connecting, live, disconnected
        /// 连续快速失败后停止自动重试，等用户手动重试（附原因）。
        case failed(String)
    }

    enum SortColumn: String { case name, pid, cpu, energy, memory }

    var phase: Phase = .connecting
    var snapshot: MetricsSnapshot?
    var refreshSeconds: Int = 2 {
        didSet { if oldValue != refreshSeconds { restart() } }
    }

    // 近 60 采样历史（图表用）
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    private(set) var netRxHistory: [Double] = []
    private(set) var netTxHistory: [Double] = []

    var sortColumn: SortColumn = .cpu
    var sortDescending = true

    /// 结束进程确认弹窗目标。
    var confirmKill: MetricsSnapshot.ProcessInfo?

    /// 进程详情弹窗目标（设计 §9.6：点击行弹出，系统 / 用户 App / 已退出 三态）。
    var detailProc: MetricsSnapshot.ProcessInfo?

    private var stream: StatusStream?
    private var subscription: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private var watchdog: Task<Void, Never>?
    private var consecutiveFailures = 0

    // MARK: - 就绪门槛（进程表比首个快照晚：ps CPU% 需要采样窗口）

    /// 等进程数据的兜底开关：超时后即便没有进程也进仪表盘（骨架行接住）。
    private(set) var procWaitExpired = false
    private var procWaitTask: Task<Void, Never>?

    var hasProcessData: Bool {
        !(snapshot?.topProcesses?.isEmpty ?? true)
    }

    /// 页面级 loading → 仪表盘的切换条件：有快照且（有进程数据或等待超时）。
    /// 避免"很快进页面但进程表还空着"的割裂体验。
    var ready: Bool {
        guard snapshot != nil else { return false }
        return hasProcessData || procWaitExpired
    }

    func start() {
        guard subscription == nil else { return }
        if case .failed = phase { return } // 失败态只能手动 retry
        phase = snapshot == nil ? .connecting : phase
        subscribe()
        startWatchdog()
    }

    func retry() {
        consecutiveFailures = 0
        phase = .connecting
        stop()
        subscribe()
        startWatchdog()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        watchdog?.cancel()
        watchdog = nil
        procWaitTask?.cancel()
        procWaitTask = nil
        stream?.stop()
        stream = nil
    }

    private func restart() {
        stop()
        start()
    }

    private func subscribe() {
        let stream = StatusStream()
        self.stream = stream
        let interval = refreshSeconds
        let startedAt = Date()
        subscription = Task { [weak self] in
            var failureMessage: String?
            do {
                for try await snap in stream.snapshots(intervalSeconds: interval) {
                    guard let self, !Task.isCancelled else { return }
                    ingest(snap)
                }
            } catch {
                failureMessage = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                subscription = nil
                // 快速失败（<2s 且无数据）计数；连续 3 次停止自动重试并报告原因，
                // 避免"无限转圈"（如旧 status-go 不认识新 flag、核心路径错误）。
                if Date().timeIntervalSince(startedAt) < 2, snapshot == nil {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        phase = .failed(failureMessage ?? L("status.failed.launch"))
                        stop()
                        return
                    }
                }
                phase = snapshot == nil ? .connecting : .disconnected
            }
        }
    }

    /// 断连检测（§5.5 AC-2）：超过 3×interval 无快照 → 断连并自动重连。
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if case .failed = phase { return }
                if let last = lastSnapshotAt,
                   Date().timeIntervalSince(last) > Double(refreshSeconds * 3) {
                    phase = .disconnected
                }
                if subscription == nil { subscribe() }
            }
        }
    }

    private func ingest(_ snap: MetricsSnapshot) {
        snapshot = snap
        lastSnapshotAt = Date()
        phase = .live
        consecutiveFailures = 0
        if hasProcessData {
            procWaitTask?.cancel()
            procWaitTask = nil
        } else if procWaitTask == nil, !procWaitExpired {
            procWaitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.procWaitExpired = true
            }
        }
        push(&cpuHistory, snap.cpu?.usage ?? 0)
        push(&gpuHistory, snap.gpu?.first?.usage ?? 0)
        push(&memHistory, snap.memory?.usedPercent ?? 0)
        push(&netRxHistory, snap.network?.reduce(0) { $0 + ($1.rxRateMBs ?? 0) } ?? 0)
        push(&netTxHistory, snap.network?.reduce(0) { $0 + ($1.txRateMBs ?? 0) } ?? 0)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > 60 { arr.removeFirst(arr.count - 60) }
    }

    // MARK: - 进程表

    var sortedProcesses: [MetricsSnapshot.ProcessInfo] {
        let procs = snapshot?.topProcesses ?? []
        return procs.sorted { a, b in
            let cmp: Bool = switch sortColumn {
            case .name: (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
            case .pid: a.pid < b.pid
            case .cpu: (a.cpu ?? 0) < (b.cpu ?? 0)
            case .energy: (a.cpu ?? 0) < (b.cpu ?? 0) // 能耗列 M0 以 CPU 代理，--proc 落地后换真值
            case .memory: (a.memoryBytes ?? 0) < (b.memoryBytes ?? 0)
            }
            return sortDescending ? !cmp : cmp
        }
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column { sortDescending.toggle() } else {
            sortColumn = column
            sortDescending = column != .name // 名称升序、数值列降序为首击默认
        }
    }

    /// 系统进程判定（M0 启发式：系统路径或极低 pid；uid 级判定待 status --proc）。
    /// 命中即禁用终止（设计：右键菜单"系统进程"灰置，弹窗按钮禁用）。
    func isSystemProcess(_ p: MetricsSnapshot.ProcessInfo) -> Bool {
        if p.pid < 100 { return true }
        let cmd = p.command ?? ""
        return cmd.hasPrefix("/System/") || cmd.hasPrefix("/usr/libexec/") || cmd.hasPrefix("/usr/sbin/")
    }

    /// 弹窗打开后进程可能已退出（设计三态之"已退出"）：kill(pid, 0) 探活。
    nonisolated func isGone(_ p: MetricsSnapshot.ProcessInfo) -> Bool {
        Darwin.kill(pid_t(p.pid), 0) != 0 && errno == ESRCH
    }

    /// 用户 App 判定：有对应 NSRunningApplication 且带 bundle（弹窗给完整操作区）。
    func runningApp(for p: MetricsSnapshot.ProcessInfo) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid_t(p.pid))
    }

    /// 快照里的父进程（进程树行：parent > child）。
    func parent(of p: MetricsSnapshot.ProcessInfo) -> MetricsSnapshot.ProcessInfo? {
        guard let ppid = p.ppid, ppid > 0 else { return nil }
        return snapshot?.topProcesses?.first { $0.pid == ppid }
    }

    /// 快照可见范围内的子进程数（诚实口径：仅 top 50 内）。
    func childCount(of p: MetricsSnapshot.ProcessInfo) -> Int {
        snapshot?.topProcesses?.filter { $0.ppid == p.pid }.count ?? 0
    }

    /// 原生探测（libproc/sysctl）：线程数、打开文件、磁盘 I/O、工作目录、
    /// 完整祖先链、真实可执行路径。弹窗打开时取一次。
    func probe(_ p: MetricsSnapshot.ProcessInfo) -> ProcessProbe {
        ProcessProber.probe(pid: Int32(p.pid))
    }

    /// 祖先链的友好名：GUI 应用用 localizedName（"SunBrowser"），其余用可执行名。
    func friendlyChain(_ probe: ProcessProbe) -> [(pid: Int32, name: String)] {
        probe.chain.map { link in
            if let app = NSRunningApplication(processIdentifier: link.pid),
               app.bundleURL != nil, let name = app.localizedName {
                return (link.pid, name)
            }
            return (link.pid, link.name)
        }
    }

    /// 「来自 X」：链上最近的 GUI 祖先应用（helper 归属感知）。
    func origin(of probe: ProcessProbe, selfPid: Int) -> String? {
        for link in probe.chain.reversed() where link.pid != Int32(selfPid) {
            if let app = NSRunningApplication(processIdentifier: link.pid),
               app.bundleURL != nil {
                return app.localizedName
            }
        }
        return nil
    }

    /// 「显示」：在 Finder 中定位 App bundle / 可执行文件。
    /// 用 proc_pidpath 真实路径（command 里带空格的路径解析不可靠）。
    func reveal(_ p: MetricsSnapshot.ProcessInfo) {
        if let url = runningApp(for: p)?.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let path = ProcessProber.executablePath(Int32(p.pid)) ?? executablePath(of: p)
        if let path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// 「复制摘要」：官方 Mole 格式——名称(pid) + 来自 + 完整链路 + 指标。
    func copySummary(_ p: MetricsSnapshot.ProcessInfo) {
        let probed = probe(p)
        var lines = ["\(p.name ?? "?") (\(p.pid))"]
        if let from = origin(of: probed, selfPid: p.pid) {
            lines.append(L("status.summary.from", from))
        }
        let chain = friendlyChain(probed)
        if chain.count > 1 {
            lines.append(chain.map { "\($0.name)(\($0.pid))" }.joined(separator: " -> "))
        }
        var metrics: [String] = []
        if let cpu = p.cpu { metrics.append(String(format: "CPU %.1f%%", cpu)) }
        if let mem = p.memoryBytes {
            metrics.append("MEM " + ByteCountFormatter.string(fromByteCount: Int64(mem), countStyle: .memory))
        }
        if !metrics.isEmpty { lines.append(metrics.joined(separator: " · ")) }
        if let exec = probed.executablePath { lines.append(exec) }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// 终止：NSRunningApplication.terminate 优先，回退 SIGTERM；force = SIGKILL。
    /// 二次确认由 View 层的 confirmKill 弹窗保证（§5.5）。
    func kill(_ p: MetricsSnapshot.ProcessInfo, force: Bool) {
        guard !isSystemProcess(p) else { return }
        if !force, let app = NSRunningApplication(processIdentifier: pid_t(p.pid)) {
            app.terminate()
            return
        }
        Darwin.kill(pid_t(p.pid), force ? SIGKILL : SIGTERM)
    }

    // MARK: - 进程图标（按 pid 缓存；GUI app 用真实图标，二进制用可执行文件图标）

    private var iconCache: [Int: NSImage] = [:]

    func icon(for p: MetricsSnapshot.ProcessInfo) -> NSImage? {
        if let cached = iconCache[p.pid] { return cached }
        var image: NSImage?
        if let app = NSRunningApplication(processIdentifier: pid_t(p.pid)), let icon = app.icon {
            image = icon
        } else if let ppid = p.ppid, ppid > 1,
                  let parent = NSRunningApplication(processIdentifier: pid_t(ppid)), let icon = parent.icon {
            // helper 子进程（渲染器等）挂到父应用图标
            image = icon
        } else if let path = ProcessProber.executablePath(Int32(p.pid)) ?? executablePath(of: p),
                  FileManager.default.fileExists(atPath: path) {
            // 优先 proc_pidpath：command 字段里带空格的路径没法按空格切
            image = NSWorkspace.shared.icon(forFile: path)
        }
        if let image {
            image.size = NSSize(width: 16, height: 16)
            iconCache[p.pid] = image
            if iconCache.count > 300 { iconCache.removeAll() } // 简单防涨
        }
        return image
    }

    private func executablePath(of p: MetricsSnapshot.ProcessInfo) -> String? {
        guard let command = p.command, command.hasPrefix("/") else { return nil }
        // command 可能带参数，取首个空格前的路径 token。
        return String(command.split(separator: " ", maxSplits: 1)[0])
    }
}
