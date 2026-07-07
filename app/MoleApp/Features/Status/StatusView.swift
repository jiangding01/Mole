import MoleKit
import SwiftUI

/// 状态页（设计稿 status 页 / 方案 §5.5）：8 指标卡固定区 + 进程表撑满剩余高度。
/// 严格只读（除受控终止进程）。数据：status-go --watch --top-procs 50。
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

    @ViewBuilder
    private var connectingView: some View {
        if case let .failed(reason) = store.phase {
            // 启动失败态：说清原因 + 手动重试，绝不无限转圈。
            VStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(Semantic.warn)
                Text("无法读取系统指标")
                    .font(Fonts.ui(14, .semibold))
                    .foregroundStyle(look.text)
                Text(reason)
                    .font(Fonts.mono(11))
                    .foregroundStyle(look.textMute)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("重试") { store.retry() }
                    .buttonStyle(.plain)
                    .font(Fonts.ui(12, .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Capsule().fill(accent.gradient))
                    .foregroundStyle(accent.onAccent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                RingSpinner(accent: accent)
                Text("正在读取系统指标")
                    .font(Fonts.ui(13))
                    .foregroundStyle(look.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 布局：卡片固定，进程表吃掉剩余全部高度

    private var dashboard: some View {
        VStack(spacing: Metrics.gridGap) {
            headerBar
            if store.phase == .disconnected { disconnectBanner }
            cardGrid
            processTable
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Fonts.eyebrow("System Status", size: 10)
                .foregroundStyle(look.textDim)
            livePill
            Spacer()
            refreshSegment
        }
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(store.phase == .live ? Semantic.success : Semantic.warn)
                .frame(width: 6, height: 6)
            Text(store.phase == .live ? "实时" : "重连中")
                .font(Fonts.mono(10, .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(look.line))
        .foregroundStyle(look.textDim)
    }

    /// 自定义刷新率段控（系统 segmented 在深底上对比度不够）。
    private var refreshSegment: some View {
        HStack(spacing: 2) {
            ForEach([1, 2, 5], id: \.self) { s in
                Button {
                    store.refreshSeconds = s
                } label: {
                    Text("\(s)s")
                        .font(Fonts.mono(10.5, .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(store.refreshSeconds == s ? AnyShapeStyle(look.text) : AnyShapeStyle(.clear)))
                        .foregroundStyle(store.refreshSeconds == s ? AnyShapeStyle(Color(hex: 0x181410)) : AnyShapeStyle(look.textDim))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(look.line))
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
        return MetricCard(title: "健康度", icon: "sun.max.fill", tint: Semantic.warnAlt, badge: s?.hardware?.model, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(Int(score))")
                    .font(Fonts.serif(44, .semibold))
                    .foregroundStyle(Semantic.health(score))
                Text(healthMsg(s?.healthScoreMsg))
                    .font(Fonts.ui(11))
                    .foregroundStyle(look.textDim)
                    .lineLimit(2)
                Text("已运行 \(s?.uptime ?? "—")")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func cpuCard(_ s: MetricsSnapshot?) -> some View {
        let cpu = s?.cpu
        return MetricCard(title: "CPU", icon: "cpu", tint: Semantic.success, badge: tempBadge(s?.thermal?.cpuTemp), look: look) {
            VStack(alignment: .leading, spacing: 5) {
                bigPercent(cpu?.usage)
                BarHistoryChart(values: store.cpuHistory, color: Semantic.success)
                    .frame(height: 32)
                Text(String(format: "负载 %.1f / %d 核", cpu?.load1 ?? 0, cpu?.coreCount ?? 0))
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func gpuCard(_ s: MetricsSnapshot?) -> some View {
        let gpu = s?.gpu?.first
        let usage = validPercent(gpu?.usage)
        return MetricCard(title: "GPU", icon: "display", tint: Color(hex: 0xDD8464),
                          badge: tempBadge(s?.thermal?.gpuTemp), look: look) {
            VStack(alignment: .leading, spacing: 5) {
                bigPercent(usage)
                if usage != nil {
                    LineHistoryChart(values: store.gpuHistory, color: accent.b)
                        .frame(height: 32)
                } else {
                    // powermetrics 需要 root：helper（Phase 3）落地前使用率不可读。
                    Text("使用率需要管理员组件")
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textMute)
                        .frame(height: 32, alignment: .center)
                }
                Text("\(gpu?.coreCount ?? 0) GPU 核")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func memoryCard(_ s: MetricsSnapshot?) -> some View {
        let mem = s?.memory
        let pressureLabel = ["normal": "正常", "warn": "偏高", "critical": "告急"][mem?.pressure ?? ""]
        return MetricCard(title: "内存", icon: "memorychip", tint: Color(hex: 0xE6C078), badge: pressureLabel.map { "压力 \($0)" }, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                bigPercent(mem?.usedPercent)
                AreaHistoryChart(values: store.memHistory, color: accent.a)
                    .frame(height: 32)
                Text("\(fmtBytes(mem?.used)) · 交换 \(fmtBytes(mem?.swapUsed))")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func batteryCard(_ s: MetricsSnapshot?) -> some View {
        let bat = s?.batteries?.first
        return MetricCard(title: "电池", icon: "battery.75percent", tint: Semantic.successAlt, badge: healthLabel(bat?.health), look: look) {
            VStack(alignment: .leading, spacing: 5) {
                bigPercent(bat?.percent)
                Text(batteryStatusLabel(bat?.status))
                    .font(Fonts.ui(11))
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
        return MetricCard(title: "磁盘", icon: "internaldrive", tint: Color(hex: 0x5AB4CE), badge: fmtDisk(disk?.total), look: look) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmtDisk(free))
                        .font(Fonts.serif(28, .semibold))
                        .foregroundStyle(look.text)
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
                Text(String(format: "已用 %@ · %.0f%%", fmtDisk(disk?.used), disk?.usedPercent ?? 0))
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                Text(String(format: "R %.1f · W %.1f MB/s",
                            s?.diskIO?.readRate ?? 0, s?.diskIO?.writeRate ?? 0))
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func networkCard(_ s: MetricsSnapshot?) -> some View {
        let iface = s?.network?.first?.name
        return MetricCard(title: "网络", icon: "globe", tint: Color(hex: 0x5AB4CE), badge: iface, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                Text(fmtRate(store.netRxHistory.last ?? 0))
                    .font(Fonts.serif(28, .semibold))
                    .foregroundStyle(look.text)
                DualLineChart(a: store.netRxHistory, b: store.netTxHistory,
                              colorA: Color(hex: 0x63BB95), colorB: Color(hex: 0x5AB4CE))
                    .frame(height: 32)
                Text("↑ \(fmtRate(store.netTxHistory.last ?? 0))")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func fanCard(_ s: MetricsSnapshot?) -> some View {
        let fan = s?.thermal
        let hasFan = (fan?.fanSpeed ?? 0) > 0
        return MetricCard(title: "风扇", icon: "fan.fill", tint: Color(hex: 0xC9C0B0), badge: hasFan ? "自动" : nil, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                if hasFan {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(fan?.fanSpeed ?? 0)")
                            .font(Fonts.serif(28, .semibold))
                            .foregroundStyle(look.text)
                        Text("RPM").font(Fonts.mono(10)).foregroundStyle(look.textDim)
                    }
                } else {
                    Text("静音")
                        .font(Fonts.serif(28, .semibold))
                        .foregroundStyle(look.textDim)
                }
                Text("由 macOS 调节")
                    .font(Fonts.ui(11))
                    .foregroundStyle(look.textDim)
                if let power = fan?.systemPower, power > 0 {
                    Text(String(format: "功耗 %.1fW", power))
                        .font(Fonts.mono(10)).foregroundStyle(look.textMute)
                }
            }
        }
    }

    // MARK: - 进程表（占满剩余高度，内部滚动，最多 50 条）

    private var processTable: some View {
        VStack(spacing: 0) {
            processHeader
            Divider().overlay(look.line)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.sortedProcesses.prefix(50).enumerated()), id: \.element.pid) { index, proc in
                        ProcessRow(proc: proc,
                                   icon: store.icon(for: proc),
                                   look: look,
                                   isSystem: store.isSystemProcess(proc),
                                   maxCPU: store.sortedProcesses.first?.cpu ?? 100,
                                   zebra: index % 2 == 1) {
                            store.confirmKill = proc
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(look.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var processHeader: some View {
        HStack(spacing: 0) {
            Text("名称（\(store.sortedProcesses.count)）")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("PID", .pid).frame(width: 80, alignment: .trailing)
            sortHeader("CPU", .cpu).frame(width: 130, alignment: .trailing)
            sortHeader("能耗", .energy).frame(width: 70, alignment: .trailing)
            sortHeader("内存", .memory).frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 36)
        }
        .font(Fonts.mono(10, .semibold))
        .foregroundStyle(look.textMute)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func sortHeader(_ label: String, _ column: StatusStore.SortColumn) -> some View {
        Button {
            store.toggleSort(column)
        } label: {
            HStack(spacing: 2) {
                if store.sortColumn == column {
                    Image(systemName: store.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7))
                }
                Text(label)
            }
            .foregroundStyle(store.sortColumn == column ? look.text : look.textMute)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 小工具

    /// GPU 等指标不可用时（负值）显示占位而非 -1%。
    private func validPercent(_ v: Double?) -> Double? {
        guard let v, v >= 0 else { return nil }
        return v
    }

    private func bigPercent(_ v: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v.map { "\(Int($0))" } ?? "--")
                .font(Fonts.serif(34, .semibold))
                .foregroundStyle(look.text)
            Text("%").font(Fonts.mono(12)).foregroundStyle(look.textDim)
        }
    }

    /// 温度 <=0 视为不可读，不显示徽标。
    private func tempBadge(_ t: Double?) -> String? {
        guard let t, t > 0 else { return nil }
        return String(format: "%.0f°C", t)
    }

    private func batteryStatusLabel(_ s: String?) -> String {
        switch (s ?? "").lowercased() {
        case "ac", "ac power": return "电源供电"
        case "charging": return "充电中"
        case "discharging", "battery power": return "电池供电"
        case "charged", "full", "fully charged": return "已充满"
        default: return s ?? "—"
        }
    }

    private func healthLabel(_ h: String?) -> String? {
        switch (h ?? "").lowercased() {
        case "good": return "健康"
        case "fair": return "一般"
        case "poor", "bad": return "较差"
        case "": return nil
        default: return h
        }
    }

    private func fmtBytes(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
    }

    /// 磁盘用 decimal（厂商口径：494 GB），与系统关于本机一致。
    private func fmtDisk(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }

    /// 健康诊断短语常见模式的中文化（CLI 输出英文；完整 i18n 见 §8.5）。
    private func healthMsg(_ msg: String?) -> String {
        guard var m = msg, !m.isEmpty else { return "—" }
        let table = [
            "Disk Almost Full": "磁盘空间不足",
            "Restart Recommended": "建议重启",
            "High CPU Load": "CPU 负载偏高",
            "High Memory Pressure": "内存压力偏高",
            "Good": "良好", "Fair": "一般", "Poor": "较差", "Excellent": "极佳",
        ]
        for (en, zh) in table { m = m.replacingOccurrences(of: en, with: zh) }
        return m.replacingOccurrences(of: ": ", with: "：").replacingOccurrences(of: ", ", with: " · ")
    }

    private func fmtRate(_ mbs: Double) -> String {
        mbs >= 1 ? String(format: "%.1f MB/s", mbs) : String(format: "%.0f KB/s", mbs * 1024)
    }
}

// MARK: - 组件

private struct MetricCard<Content: View>: View {
    var title: String
    var icon: String
    var tint: Color
    var badge: String?
    var look: Look
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Fonts.eyebrow(title, size: 9.5).foregroundStyle(tint.opacity(0.9))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(Fonts.mono(9, .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.12)))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(look.line, lineWidth: 1))
    }
}

private struct ProcessRow: View {
    var proc: MetricsSnapshot.ProcessInfo
    var icon: NSImage?
    var look: Look
    var isSystem: Bool
    var maxCPU: Double
    var zebra: Bool
    var onKill: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                iconView
                Text(proc.name ?? "?").font(Fonts.ui(12, .medium)).lineLimit(1)
                if (proc.cpu ?? 0) > 80 {
                    Image(systemName: "flame.fill").font(.system(size: 9))
                        .foregroundStyle(Semantic.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(proc.pid)").frame(width: 80, alignment: .trailing)
            HStack(spacing: 6) {
                Capsule().fill(look.line)
                    .overlay(alignment: .leading) {
                        Capsule().fill((proc.cpu ?? 0) > 80 ? Semantic.danger : Semantic.warnAlt)
                            .frame(width: 48 * min(1, (proc.cpu ?? 0) / max(1, maxCPU)))
                    }
                    .frame(width: 48, height: 3)
                Text(String(format: "%.1f", proc.cpu ?? 0)).frame(width: 50, alignment: .trailing)
            }
            .frame(width: 130, alignment: .trailing)
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
            .frame(width: 36)
        }
        .font(Fonts.mono(11.5))
        .foregroundStyle(look.text)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(hovering ? look.line : (zebra ? Color.white.opacity(0.015) : .clear))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
        } else {
            // 无图标兜底：系统进程用齿轮、其余用终端样占位（对齐设计稿）
            Image(systemName: isSystem ? "gearshape.fill" : "terminal.fill")
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .foregroundStyle(look.textMute)
                .background(RoundedRectangle(cornerRadius: 3.5).fill(look.line))
        }
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
                    let y = geo.size.height * (1 - CGFloat(min(100, max(0, v)) / 100))
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
                    let y = geo.size.height * (1 - CGFloat(min(100, max(0, v)) / 100))
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
