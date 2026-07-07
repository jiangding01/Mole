import AppKit
import MoleKit
import Observation

/// 状态页 Store（设计 §5.5）：订阅指标流、维护采样历史、断连自动重连、
/// 进程排序与受控终止。页面可见时启动、离开即停（RootView 驱动）。
@Observable
@MainActor
final class StatusStore {
    enum Phase { case connecting, live, disconnected }

    enum SortColumn: String { case pid, cpu, energy, memory }

    var phase: Phase = .connecting
    var snapshot: MetricsSnapshot?
    var refreshSeconds: Int = 2 { didSet { if oldValue != refreshSeconds { restart() } } }

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

    private var stream: StatusStream?
    private var subscription: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private var watchdog: Task<Void, Never>?

    func start() {
        guard subscription == nil else { return }
        phase = snapshot == nil ? .connecting : phase
        subscribe()
        startWatchdog()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        watchdog?.cancel()
        watchdog = nil
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
        subscription = Task { [weak self] in
            do {
                for try await snap in stream.snapshots(intervalSeconds: interval) {
                    guard let self, !Task.isCancelled else { return }
                    self.ingest(snap)
                }
            } catch {
                // 启动失败（如内嵌核心缺失）：进入断连态，watchdog 负责重试。
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.subscription = nil
                self.phase = .disconnected
            }
        }
    }

    /// 断连检测（§5.5 AC-2）：超过 3×interval 无快照 → 断连并自动重连。
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if let last = self.lastSnapshotAt,
                   Date().timeIntervalSince(last) > Double(self.refreshSeconds * 3) {
                    self.phase = .disconnected
                    if self.subscription == nil { self.subscribe() }
                }
            }
        }
    }

    private func ingest(_ snap: MetricsSnapshot) {
        snapshot = snap
        lastSnapshotAt = Date()
        phase = .live
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
        let sorted = procs.sorted { a, b in
            let cmp: Bool
            switch sortColumn {
            case .pid: cmp = a.pid < b.pid
            case .cpu: cmp = (a.cpu ?? 0) < (b.cpu ?? 0)
            case .energy: cmp = (a.cpu ?? 0) < (b.cpu ?? 0) // 能耗列 M0 以 CPU 代理，--proc 落地后换真值
            case .memory: cmp = (a.memoryBytes ?? 0) < (b.memoryBytes ?? 0)
            }
            return sortDescending ? !cmp : cmp
        }
        return sorted
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column { sortDescending.toggle() } else {
            sortColumn = column
            sortDescending = true
        }
    }

    /// 系统进程判定（M0 启发式：系统路径或极低 pid；uid 级判定待 status --proc）。
    /// 命中即禁用终止（设计：右键菜单"系统进程"灰置，弹窗按钮禁用）。
    func isSystemProcess(_ p: MetricsSnapshot.ProcessInfo) -> Bool {
        if p.pid < 100 { return true }
        let cmd = p.command ?? ""
        return cmd.hasPrefix("/System/") || cmd.hasPrefix("/usr/libexec/") || cmd.hasPrefix("/usr/sbin/")
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
        } else if let path = executablePath(of: p), FileManager.default.fileExists(atPath: path) {
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
