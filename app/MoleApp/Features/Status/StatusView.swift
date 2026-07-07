import MoleKit
import SwiftUI

/// 状态页（设计稿 status 页 / 方案 §5.5）：8 指标卡 + 进程表。
/// 严格只读（除受控终止进程）。数据：status-go --watch NDJSON 流。
/// 进程详情弹窗待 CLI 侧 `status-go --proc` 落地后接入。
struct StatusView: View {
    @State private var store = StatusStore()
    private let look = Look.ink
    private let accent = ModuleAccent.status

    var body: some View {
        Group {
            if store.snapshot == nil {
                connectingView
            } else {
                dashboard
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .confirmationDialog(
            "结束进程 \(store.confirmKill?.name ?? "")？",
            isPresented: Binding(get: { store.confirmKill != nil }, set: { if !$0 { store.confirmKill = nil } })
        ) {
            if let p = store.confirmKill {
                Button("终止") { store.kill(p, force: false); store.confirmKill = nil }
                Button("强制退出", role: .destructive) { store.kill(p, force: true); store.confirmKill = nil }
                Button("取消", role: .cancel) { store.confirmKill = nil }
            }
        } message: {
            Text("终止会请求进程正常退出；强制退出立即结束，未保存内容将丢失。")
        }
    }

    // MARK: - 连接中

    private var connectingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在读取系统指标")
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 仪表盘

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: Metrics.gridGap) {
                headerBar
                if store.phase == .disconnected { disconnectBanner }
                cardGrid
                processTable
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var headerBar: some View {
        HStack {
            Fonts.eyebrow("System Status")
                .foregroundStyle(look.textMute)
            livePill
            Spacer()
            Picker("", selection: $store.refreshSeconds) {
                Text("1s").tag(1)
                Text("2s").tag(2)
                Text("5s").tag(5)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(store.phase == .live ? Semantic.success : Semantic.warn)
                .frame(width: 6, height: 6)
            Text(store.phase == .live ? "实时" : "重连中")
                .font(Fonts.mono(10, .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(look.chrome))
        .foregroundStyle(look.textDim)
    }

    private var disconnectBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(Semantic.warn).frame(width: 6, height: 6)
            Text("数据流中断，正在重连…")
                .font(Fonts.ui(12))
                .foregroundStyle(look.textDim)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Semantic.warn.opacity(0.1)))
    }

    private var cardGrid: some View {
        let snap = store.snapshot
        let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridGap), count: 4)
        return LazyVGrid(columns: columns, spacing: Metrics.gridGap) {
            healthCard(snap)
            cpuCard(snap)
            gpuCard(snap)
            memoryCard(snap)
            batteryCard(snap)
            diskCard(snap)
            networkCard(snap)
            fanCard(snap)
        }
        .opacity(store.phase == .disconnected ? 0.55 : 1)
    }

    // MARK: - 卡片

    private func healthCard(_ s: MetricsSnapshot?) -> some View {
        let score = Double(s?.healthScore ?? 0)
        return MetricCard(title: "健康度", badge: s?.hardware?.model, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Int(score))")
                    .font(Fonts.serif(52, .semibold))
                    .foregroundStyle(Semantic.health(score))
                Text(s?.healthScoreMsg ?? "—")
                    .font(Fonts.ui(11.5))
                    .foregroundStyle(look.textDim)
                    .lineLimit(1)
                Text("已运行 \(s?.uptime ?? "—")")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func cpuCard(_ s: MetricsSnapshot?) -> some View {
        let cpu = s?.cpu
        let temp = s?.thermal?.cpuTemp
        return MetricCard(title: "CPU", badge: temp.map { String(format: "%.0f°C", $0) }, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                bigPercent(cpu?.usage ?? 0)
                BarHistoryChart(values: store.cpuHistory, color: Semantic.success)
                    .frame(height: 34)
                Text(String(format: "负载 %.1f / %d 核", cpu?.load1 ?? 0, cpu?.coreCount ?? 0))
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func gpuCard(_ s: MetricsSnapshot?) -> some View {
        let gpu = s?.gpu?.first
        let temp = s?.thermal?.gpuTemp
        return MetricCard(title: "GPU", badge: temp.map { String(format: "%.0f°C", $0) }, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                bigPercent(gpu?.usage ?? 0)
                LineHistoryChart(values: store.gpuHistory, color: accent.b)
                    .frame(height: 34)
                Text("\(gpu?.coreCount ?? 0) GPU 核")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func memoryCard(_ s: MetricsSnapshot?) -> some View {
        let mem = s?.memory
        let pressure = mem?.pressure ?? "normal"
        let pressureLabel = ["normal": "正常", "warn": "偏高", "critical": "告急"][pressure] ?? pressure
        return MetricCard(title: "内存", badge: "压力 \(pressureLabel)", look: look) {
            VStack(alignment: .leading, spacing: 6) {
                bigPercent(mem?.usedPercent ?? 0)
                AreaHistoryChart(values: store.memHistory, color: accent.a)
                    .frame(height: 34)
                Text("\(fmtBytes(mem?.used)) · 交换 \(fmtBytes(mem?.swapUsed))")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func batteryCard(_ s: MetricsSnapshot?) -> some View {
        let bat = s?.batteries?.first
        return MetricCard(title: "电池", badge: bat?.health, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                bigPercent(bat?.percent ?? 0)
                Text(bat?.status ?? "—")
                    .font(Fonts.ui(11.5))
                    .foregroundStyle(look.textDim)
                Text("\(bat?.cycleCount ?? 0) 次循环 · 容量 \(bat?.capacity ?? 0)%")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func diskCard(_ s: MetricsSnapshot?) -> some View {
        let disk = s?.disks?.first
        let free = (disk?.total ?? 0) &- (disk?.used ?? 0)
        return MetricCard(title: "磁盘", badge: fmtBytes(disk?.total), look: look) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmtBytes(free))
                        .font(Fonts.serif(30, .semibold))
                    Text("可用").font(Fonts.ui(11)).foregroundStyle(look.textDim)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(look.line)
                        Capsule().fill(accent.gradient)
                            .frame(width: geo.size.width * CGFloat((disk?.usedPercent ?? 0) / 100))
                    }
                }
                .frame(height: 5)
                Text(String(format: "已用 %@ · %.0f%% · R %.1f W %.1f MB/s",
                            fmtBytes(disk?.used), disk?.usedPercent ?? 0,
                            s?.diskIO?.readRate ?? 0, s?.diskIO?.writeRate ?? 0))
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
            }
        }
    }

    private func networkCard(_ s: MetricsSnapshot?) -> some View {
        let iface = s?.network?.first?.name ?? "—"
        let down = store.netRxHistory.last ?? 0
        return MetricCard(title: "网络", badge: iface, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                Text(fmtRate(down)).font(Fonts.serif(30, .semibold))
                DualLineChart(a: store.netRxHistory, b: store.netTxHistory,
                              colorA: Color(hex: 0x63BB95), colorB: Color(hex: 0x5AB4CE))
                    .frame(height: 34)
                Text("↑ \(fmtRate(store.netTxHistory.last ?? 0))")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func fanCard(_ s: MetricsSnapshot?) -> some View {
        let fan = s?.thermal
        return MetricCard(title: "风扇", badge: nil, look: look) {
            VStack(alignment: .leading, spacing: 6) {
                if let speed = fan?.fanSpeed, speed > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(speed)").font(Fonts.serif(30, .semibold))
                        Text("RPM").font(Fonts.mono(10)).foregroundStyle(look.textDim)
                    }
                    Text("自动 · 由 macOS 调节")
                        .font(Fonts.ui(11.5))
                        .foregroundStyle(look.textDim)
                } else {
                    Text("—").font(Fonts.serif(30, .semibold)).foregroundStyle(look.textMute)
                    Text("无风扇或不可读")
                        .font(Fonts.ui(11.5))
                        .foregroundStyle(look.textMute)
                }
                if let power = fan?.systemPower, power > 0 {
                    Text(String(format: "功耗 %.1fW", power))
                        .font(Fonts.mono(10)).foregroundStyle(look.textMute)
                }
            }
        }
    }

    // MARK: - 进程表

    private var processTable: some View {
        VStack(spacing: 0) {
            processHeader
            Divider().overlay(look.line)
            ForEach(store.sortedProcesses.prefix(30)) { proc in
                ProcessRow(proc: proc, look: look,
                           isSystem: store.isSystemProcess(proc),
                           maxCPU: store.sortedProcesses.first?.cpu ?? 100) {
                    store.confirmKill = proc
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(look.surfaceSolid.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(look.line, lineWidth: 1))
    }

    private var processHeader: some View {
        HStack(spacing: 0) {
            Text("进程（\(store.sortedProcesses.count)）")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("PID", .pid).frame(width: 70, alignment: .trailing)
            sortHeader("CPU", .cpu).frame(width: 120, alignment: .trailing)
            sortHeader("能耗", .energy).frame(width: 70, alignment: .trailing)
            sortHeader("内存", .memory).frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 40)
        }
        .font(Fonts.mono(10.5, .semibold))
        .foregroundStyle(look.textMute)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sortHeader(_ label: String, _ column: StatusStore.SortColumn) -> some View {
        Button {
            store.toggleSort(column)
        } label: {
            HStack(spacing: 2) {
                Text(label)
                if store.sortColumn == column {
                    Image(systemName: store.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7))
                }
            }
            .foregroundStyle(store.sortColumn == column ? look.text : look.textMute)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 小工具

    private func bigPercent(_ v: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int(v))").font(Fonts.serif(34, .semibold))
            Text("%").font(Fonts.mono(12)).foregroundStyle(look.textDim)
        }
    }

    private func fmtBytes(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
    }

    private func fmtRate(_ mbs: Double) -> String {
        mbs >= 1 ? String(format: "%.1f MB/s", mbs) : String(format: "%.0f KB/s", mbs * 1024)
    }
}

// MARK: - 组件

private struct MetricCard<Content: View>: View {
    var title: String
    var badge: String?
    var look: Look
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Fonts.eyebrow(title, size: 9.5).foregroundStyle(look.textDim)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(Fonts.mono(9, .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(look.line))
                        .foregroundStyle(look.textDim)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(look.surfaceSolid.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(look.line, lineWidth: 1))
    }
}

private struct ProcessRow: View {
    var proc: MetricsSnapshot.ProcessInfo
    var look: Look
    var isSystem: Bool
    var maxCPU: Double
    var onKill: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if (proc.cpu ?? 0) > 80 {
                    Image(systemName: "flame.fill").font(.system(size: 9))
                        .foregroundStyle(Semantic.danger)
                }
                Text(proc.name ?? "?").font(Fonts.ui(12, .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(proc.pid)").frame(width: 70, alignment: .trailing)
            HStack(spacing: 6) {
                Capsule().fill(look.line)
                    .overlay(alignment: .leading) {
                        Capsule().fill((proc.cpu ?? 0) > 80 ? Semantic.danger : Semantic.warnAlt)
                            .frame(width: 44 * min(1, (proc.cpu ?? 0) / max(1, maxCPU)))
                    }
                    .frame(width: 44, height: 3)
                Text(String(format: "%.1f", proc.cpu ?? 0)).frame(width: 50, alignment: .trailing)
            }
            .frame(width: 120, alignment: .trailing)
            Text("--").frame(width: 70, alignment: .trailing)
            Text(fmtMem(proc.memoryBytes)).frame(width: 90, alignment: .trailing)
            Menu {
                Button("结束进程…", action: onKill).disabled(isSystem)
                Button("在活动监视器中打开") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                if isSystem { Text("系统进程") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(look.textMute)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .font(Fonts.mono(11.5))
        .foregroundStyle(look.text)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func fmtMem(_ v: UInt64?) -> String {
        guard let v else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }
}

// MARK: - 微型图表（自绘，贴设计稿的 canvas 图）

private struct BarHistoryChart: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let n = max(1, values.count)
            let barW = geo.size.width / CGFloat(max(12, n)) - 2
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(0.75))
                        .frame(width: max(2, barW), height: max(2, geo.size.height * CGFloat(min(100, v) / 100)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct LineHistoryChart: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(min(100, v) / 100))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}

private struct AreaHistoryChart: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                path.move(to: CGPoint(x: 0, y: geo.size.height))
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(min(100, v) / 100))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.05)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct DualLineChart: View {
    var a: [Double]
    var b: [Double]
    var colorA: Color
    var colorB: Color

    var body: some View {
        let peak = max(0.1, max(a.max() ?? 0, b.max() ?? 0))
        GeometryReader { geo in
            ZStack {
                line(a, peak: peak, in: geo.size).stroke(colorA, lineWidth: 1.5)
                line(b, peak: peak, in: geo.size).stroke(colorB, lineWidth: 1.5)
            }
        }
    }

    private func line(_ values: [Double], peak: Double, in size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat(v / peak))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}
