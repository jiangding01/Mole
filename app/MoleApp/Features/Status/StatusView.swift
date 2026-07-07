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
            // ready = 有快照且进程表有数据（或等待超时兜底）：
            // 避免"页面秒进但进程表还空着"的割裂体验
            if !store.ready {
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
        .sheet(item: Binding(get: { store.detailProc }, set: { store.detailProc = $0 })) { proc in
            ProcessDetailSheet(proc: proc, store: store, look: look, accent: accent)
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
                    .pointingCursor()
                    .font(Fonts.ui(12, .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Capsule().fill(accent.gradient))
                    .foregroundStyle(accent.onAccent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ZStack {
                    RingSpinner(accent: accent, size: 200, lineWidth: 3)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(accent.b)
                }
                Fonts.eyebrow("Reading Sensors", size: 11)
                    .foregroundStyle(look.textMute)
                    .padding(.top, 38)
                Text("正在读取系统指标")
                    .font(Fonts.serif(30, .semibold))
                    .foregroundStyle(look.text)
                    .padding(.top, 12)
                Text(store.snapshot == nil ? "采集 CPU · 内存 · 磁盘 · 网络 · 传感器数据" : "正在采集进程列表…")
                    .font(Fonts.ui(13))
                    .foregroundStyle(look.textDim)
                    .padding(.top, 10)
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
        HStack(spacing: 12) {
            // 设计稿：衬线大标题 + 绿色"实时监测中"胶囊
            Text("系统状态")
                .font(Fonts.serif(28, .semibold))
                .foregroundStyle(look.text)
            livePill
            Spacer()
            Text("刷新频率")
                .font(Fonts.ui(11))
                .foregroundStyle(look.textMute)
            refreshSegment
        }
    }

    private var livePill: some View {
        let live = store.phase == .live
        return HStack(spacing: 5) {
            Circle().fill(live ? accent.b : Semantic.warn)
                .frame(width: 6, height: 6)
            Text(live ? "实时监测中" : "重连中")
                .font(Fonts.ui(11, .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill((live ? accent.b : Semantic.warn).opacity(0.12)))
        .foregroundStyle(live ? accent.b : Semantic.warn)
    }

    /// 自定义刷新率段控（设计稿：选中 = accent 绿胶囊；系统 segmented 深底对比度不够）。
    private var refreshSegment: some View {
        HStack(spacing: 2) {
            ForEach([1, 2, 5], id: \.self) { s in
                Button {
                    store.refreshSeconds = s
                } label: {
                    Text("\(s)s")
                        .font(Fonts.mono(10.5, .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if store.refreshSeconds == s { Capsule().fill(accent.gradient) }
                        }
                        .foregroundStyle(store.refreshSeconds == s ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(look.textDim))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingCursor()
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
            // 设计稿行序：健康分 · CPU · GPU · 内存 / 磁盘 · 网络 · 电池 · 风扇
            healthCard(snap)
            cpuCard(snap)
            gpuCard(snap)
            memoryCard(snap)
            diskCard(snap)
            networkCard(snap)
            batteryCard(snap)
            fanCard(snap)
        }
        .opacity(store.phase == .disconnected ? 0.55 : 1)
    }

    // MARK: - 卡片

    private func healthCard(_ s: MetricsSnapshot?) -> some View {
        let score = Double(s?.healthScore ?? 0)
        let hw = s?.hardware
        return MetricCard(title: "健康分", icon: "heart", tint: Semantic.health(score), look: look) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(score))")
                        .font(Fonts.serif(40, .semibold))
                        .foregroundStyle(Semantic.health(score))
                    Text(healthMsg(s?.healthScoreMsg))
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textDim)
                        .lineLimit(2)
                }
                // 设计稿：芯片 / 内存 · 系统 / 运行 三行规格
                specRow("芯片", hw?.cpuModel ?? hw?.model ?? "—")
                HStack(spacing: 10) {
                    specRow("内存", hw?.totalRAM ?? "—")
                    specRow("系统", hw?.osVersion ?? "—")
                }
                specRow("运行", s?.uptime ?? "—")
            }
        }
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(look.textMute)
            Text(value).foregroundStyle(look.textDim).lineLimit(1)
        }
        .font(Fonts.mono(10))
    }

    private func cpuCard(_ s: MetricsSnapshot?) -> some View {
        let cpu = s?.cpu
        return MetricCard(title: "CPU", icon: "cpu", tint: Semantic.success, badge: tempBadge(s?.thermal?.cpuTemp), look: look) {
            VStack(alignment: .leading, spacing: 5) {
                bigPercent(cpu?.usage)
                BarHistoryChart(values: store.cpuHistory, color: Semantic.success)
                    .frame(height: 32)
                Text("负载 \(String(format: "%.1f", cpu?.load1 ?? 0)) / \(cpu?.coreCount ?? 0) 核 · \(loadQualifier(cpu))")
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
                Text(usage.map { "\($0 > 70 ? "繁忙" : "正常") · \(gpu?.coreCount ?? 0) GPU 核" } ?? "\(gpu?.coreCount ?? 0) GPU 核")
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
                // 设计稿：14.2 / 16 GB（已用 / 总量），非百分比
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmtGB(mem?.used))
                        .font(Fonts.serif(34, .semibold))
                        .foregroundStyle(look.text)
                    Text("/ \(fmtGB(mem?.total)) GB")
                        .font(Fonts.mono(12))
                        .foregroundStyle(look.textDim)
                }
                AreaHistoryChart(values: store.memHistory, color: accent.a)
                    .frame(height: 32)
                Text("交换空间 \(fmtBytes(mem?.swapUsed))")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
            }
        }
    }

    private func batteryCard(_ s: MetricsSnapshot?) -> some View {
        let bat = s?.batteries?.first
        // 设计稿徽标形如"健康 94%"（健康度 + 最大容量）
        let badge = bat?.capacity.map { "健康 \($0)%" } ?? healthLabel(bat?.health)
        let top = s?.topProcesses?.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }
        return MetricCard(title: "电池", icon: "battery.75percent", tint: Semantic.successAlt, badge: badge, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    bigPercent(bat?.percent)
                    Text(batteryStatusLabel(bat?.status))
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textDim)
                }
                Text("\(bat?.cycleCount ?? 0) 次循环")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                // 设计稿：最大消耗 <进程> · <CPU%>
                if let top, let cpu = top.cpu {
                    HStack(spacing: 4) {
                        Image(systemName: "flame").font(.system(size: 8)).foregroundStyle(Semantic.warnAlt)
                        Text("最大消耗 \(top.name ?? "?") · \(Int(cpu))%")
                    }
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
                }
            }
        }
    }

    private func diskCard(_ s: MetricsSnapshot?) -> some View {
        let disk = s?.disks?.first
        let free = (disk?.total ?? 0) &- (disk?.used ?? 0)
        return MetricCard(title: "磁盘", icon: "internaldrive", tint: Color(hex: 0x5AB4CE), look: look) {
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
                // 设计稿：已用 % 靠左、共 N GB 靠右
                HStack {
                    Text(String(format: "已用 %.0f%%", disk?.usedPercent ?? 0))
                    Spacer()
                    Text("共 \(fmtDisk(disk?.total))")
                }
                .font(Fonts.mono(10))
                .foregroundStyle(look.textMute)
            }
        }
    }

    private func networkCard(_ s: MetricsSnapshot?) -> some View {
        let iface = s?.network?.first?.name
        return MetricCard(title: "网络", icon: "globe", tint: Color(hex: 0x5AB4CE), badge: iface, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                // 设计稿：下行 / 上行 双列并排
                HStack(spacing: 18) {
                    netColumn("arrow.down", "下行", store.netRxHistory.last ?? 0, Color(hex: 0x63BB95))
                    netColumn("arrow.up", "上行", store.netTxHistory.last ?? 0, Color(hex: 0x5AB4CE))
                }
                DualLineChart(a: store.netRxHistory, b: store.netTxHistory,
                              colorA: Color(hex: 0x63BB95), colorB: Color(hex: 0x5AB4CE))
                    .frame(height: 32)
            }
        }
    }

    private func netColumn(_ symbol: String, _ label: String, _ mbs: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
                Text(label).font(Fonts.ui(10)).foregroundStyle(look.textMute)
            }
            Text(fmtRate(mbs))
                .font(Fonts.mono(15, .semibold))
                .foregroundStyle(look.text)
        }
    }

    private func fanCard(_ s: MetricsSnapshot?) -> some View {
        let fan = s?.thermal
        let hasFan = (fan?.fanSpeed ?? 0) > 0
        return MetricCard(title: "风扇", icon: "fan.fill", tint: Color(hex: 0xC9C0B0), badge: hasFan ? "自动" : nil, look: look) {
            VStack(alignment: .leading, spacing: 5) {
                if hasFan {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text((fan?.fanSpeed ?? 0).formatted(.number.grouping(.automatic)))
                            .font(Fonts.serif(28, .semibold))
                            .foregroundStyle(look.text)
                        Text("RPM").font(Fonts.mono(10)).foregroundStyle(look.textDim)
                    }
                } else {
                    Text("静音")
                        .font(Fonts.serif(28, .semibold))
                        .foregroundStyle(look.textDim)
                }
                HStack(spacing: 4) {
                    Image(systemName: "fanblades").font(.system(size: 9)).foregroundStyle(look.textMute)
                    Text("散热正常 · 由 macOS 调节")
                }
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
                if store.sortedProcesses.isEmpty {
                    // 首个快照可能没有进程数据（ps 需要采样窗口）：骨架行代替空白
                    processSkeleton
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.sortedProcesses.prefix(50).enumerated()), id: \.element.pid) { index, proc in
                            ProcessRow(proc: proc,
                                       icon: store.icon(for: proc),
                                       look: look,
                                       isSystem: store.isSystemProcess(proc),
                                       maxCPU: store.sortedProcesses.first?.cpu ?? 100,
                                       zebra: index % 2 == 1,
                                       onOpen: { store.detailProc = proc },
                                       onKill: { store.confirmKill = proc })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(look.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    /// 进程表骨架加载态（设计"加载骨架"边界状态）：呼吸闪烁的占位行。
    private var processSkeleton: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RingSpinner(accent: accent, size: 14, lineWidth: 2)
                Text("正在采集进程…")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            ForEach(0..<10, id: \.self) { i in
                SkeletonRow(look: look, wide: i % 3 == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var processHeader: some View {
        HStack(spacing: 0) {
            sortHeader("名称（\(store.sortedProcesses.count)）", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("PID", .pid).frame(width: 80, alignment: .trailing)
            sortHeader("CPU", .cpu).frame(width: 130, alignment: .trailing)
            sortHeader("能耗", .energy).frame(width: 70, alignment: .trailing)
            sortHeader("内存", .memory).frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 36, height: 1)
        }
        .font(Fonts.mono(10, .semibold))
        .foregroundStyle(look.textMute)
        .padding(.horizontal, 14)
        .frame(height: 34) // 表头固定高度；剩余空间全部归 ScrollView
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
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    // MARK: - 小工具

    /// 设计稿 CPU 卡评语：按 1 分钟负载 / 核数比给"低负载 · 正常 · 偏高"。
    private func loadQualifier(_ cpu: MetricsSnapshot.CPUStatus?) -> String {
        guard let load = cpu?.load1, let cores = cpu?.coreCount, cores > 0 else { return "—" }
        let ratio = load / Double(cores)
        if ratio < 0.5 { return "低负载" }
        if ratio < 1.0 { return "正常" }
        return "偏高"
    }

    /// 内存卡的 GB 数字（14.2 这种一位小数，去掉单位由调用方拼）。
    private func fmtGB(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "0" }
        let gb = Double(v) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

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
    var badge: String? = nil
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
    var onOpen: () -> Void
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
                        // 设计稿三档：>80 红、>45 橙、其余绿
                        Capsule().fill(cpuBarColor)
                            .frame(width: 48 * min(1, (proc.cpu ?? 0) / max(1, maxCPU)))
                    }
                    .frame(width: 48, height: 3)
                Text(String(format: "%.1f", proc.cpu ?? 0)).frame(width: 50, alignment: .trailing)
            }
            .frame(width: 130, alignment: .trailing)
            Text("--").frame(width: 70, alignment: .trailing)
            Text(fmtMem(proc.memoryBytes)).frame(width: 90, alignment: .trailing)
            Menu {
                Button("查看详情", action: onOpen)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen) // 设计 §9.6：点击行弹进程详情
        .onHover { hovering = $0 }
        .pointingCursor()
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
        } else {
            // 无图标兜底：系统进程用齿轮（灰）、其余用终端样占位（绿，terminal 语义色）
            Image(systemName: isSystem ? "gearshape.fill" : "terminal.fill")
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .foregroundStyle(isSystem ? look.textMute : Semantic.success)
                .background(RoundedRectangle(cornerRadius: 3.5)
                    .fill(isSystem ? AnyShapeStyle(look.line) : AnyShapeStyle(Semantic.success.opacity(0.14))))
        }
    }

    private var cpuBarColor: Color {
        let cpu = proc.cpu ?? 0
        if cpu > 80 { return Semantic.danger }
        if cpu > 45 { return Semantic.warnAlt }
        return Semantic.success
    }

    private func fmtMem(_ v: UInt64?) -> String {
        guard let v else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }
}

/// 骨架占位行：图标圆 + 名称条 + 右侧数值条，整体呼吸闪烁。
private struct SkeletonRow: View {
    var look: Look
    var wide: Bool

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3.5).fill(look.line).frame(width: 16, height: 16)
                Capsule().fill(look.line).frame(width: wide ? 150 : 96, height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(look.line).frame(width: 36, height: 8)
                .frame(width: 80, alignment: .trailing)
            Capsule().fill(look.line).frame(width: 72, height: 8)
                .frame(width: 130, alignment: .trailing)
            Capsule().fill(look.line).frame(width: 24, height: 8)
                .frame(width: 70, alignment: .trailing)
            Capsule().fill(look.line).frame(width: 48, height: 8)
                .frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 36, height: 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .opacity(pulse ? 0.35 : 0.9)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 进程详情弹窗（设计 §9.6 三态：系统 / 用户 App / 已退出）

private struct ProcessDetailSheet: View {
    var proc: MetricsSnapshot.ProcessInfo
    var store: StatusStore
    var look: Look
    var accent: ModuleAccent

    /// 原生探测数据（libproc/sysctl）：打开弹窗时取一次。
    @State private var probe: ProcessProbe?
    @State private var showRawCommand = false

    var body: some View {
        let gone = store.isGone(proc)
        let isSystem = store.isSystemProcess(proc)
        let app = store.runningApp(for: proc)
        Group {
            if gone {
                goneCard
            } else {
                detailCard(isSystem: isSystem, app: app)
            }
        }
        .background(look.surface)
        .presentationBackground(look.surfaceSolid)
        .task(id: proc.pid) { probe = store.probe(proc) }
    }

    // 已退出：极简卡片 + 红字提示
    private var goneCard: some View {
        VStack(spacing: 0) {
            header(titleSize: 19)
            Divider().overlay(look.line)
            Text("进程 \(proc.pid) 已不在运行。")
                .font(Fonts.ui(14))
                .foregroundStyle(Semantic.danger)
                .padding(.vertical, 34)
        }
        .frame(width: 560)
    }

    private func detailCard(isSystem: Bool, app: NSRunningApplication?) -> some View {
        VStack(spacing: 0) {
            header(titleSize: 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryLine
                    Divider().overlay(look.line)
                    processTree
                    infoRows(isSystem: isSystem, app: app)
                }
                .padding(.horizontal, 24)
            }
            footer(isSystem: isSystem)
        }
        .frame(width: 640)
        .frame(maxHeight: 620)
    }

    private func header(titleSize: CGFloat) -> some View {
        HStack(spacing: 14) {
            iconBox
            Text(proc.name ?? "?")
                .font(Fonts.ui(titleSize, .semibold))
                .foregroundStyle(look.text)
            Spacer()
            Button {
                store.detailProc = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(look.textMute)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(look.line.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .pointingCursor()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var iconBox: some View {
        if let icon = store.icon(for: proc) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        } else {
            Text("exec")
                .font(Fonts.mono(9, .bold))
                .foregroundStyle(look.textMute)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(look.line.opacity(0.6)))
        }
    }

    private var summaryLine: some View {
        Text(summaryText)
            .font(Fonts.mono(12))
            .foregroundStyle(look.textMute)
            .padding(.bottom, 14)
    }

    private var summaryText: String {
        var parts = ["PID \(proc.pid)"]
        if let cpu = proc.cpu { parts.append(String(format: "CPU %.1f%%", cpu)) }
        if let mem = proc.memoryBytes {
            parts.append("MEM " + ByteCountFormatter.string(fromByteCount: Int64(mem), countStyle: .memory))
        }
        if let user = probe?.user { parts.append(user) }
        if let probe, let from = store.origin(of: probe, selfPid: proc.pid) {
            parts.append("来自 \(from)")
        } else if proc.ppid == 1 {
            parts.append("由 launchd 启动")
        }
        return parts.joined(separator: " · ")
    }

    /// 进程树：完整祖先链 launchd 1 › … › 本进程 pid（探测失败时退化为 ppid 单级）。
    @ViewBuilder
    private var processTree: some View {
        Group {
            if let probe, probe.chain.count > 1 {
                chainText(store.friendlyChain(probe))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 7) {
                    let parent = store.parent(of: proc)
                    Text(parent?.name ?? (proc.ppid == 1 ? "launchd" : "PPID"))
                        .foregroundStyle(look.textDim)
                    Text("\(proc.ppid ?? 0)").foregroundStyle(look.textMute)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(look.textMute)
                    Text(proc.name ?? "?").foregroundStyle(look.text)
                    Text("\(proc.pid)").foregroundStyle(look.textMute)
                }
            }
        }
        .font(Fonts.mono(12.5))
        .padding(.vertical, 14)
    }

    private func chainText(_ chain: [(pid: Int32, name: String)]) -> Text {
        var result = Text("")
        for (i, link) in chain.enumerated() {
            if i > 0 { result = result + Text("  ›  ").foregroundStyle(look.textMute) }
            let isLast = i == chain.count - 1
            result = result + Text(link.name).foregroundStyle(isLast ? look.text : look.textDim)
            result = result + Text(" \(link.pid)").foregroundStyle(look.textMute)
        }
        return result
    }

    @ViewBuilder
    private func infoRows(isSystem: Bool, app: NSRunningApplication?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let app, let bundle = app.bundleURL?.path {
                infoRow("置信度", "高 · 正在运行的应用")
                infoRow("识别依据", bundle)
            } else if let bundle = inferredBundlePath {
                infoRow("置信度", "中 · 从可执行路径推断")
                infoRow("识别依据", bundle)
            }
            if let threads = probe?.threadCount { infoRow("线程数", "\(threads)") }
            if let files = probe?.openFileCount { infoRow("打开文件", "\(files)") }
            if let read = probe?.diskBytesRead, let written = probe?.diskBytesWritten {
                infoRow("磁盘 I/O", "\(fmtIO(read)) R · \(fmtIO(written)) W")
            }
            infoRow("子进程", "\(store.childCount(of: proc))")
            if let user = probe?.user { infoRow("用户", user) }
            if let started = app?.launchDate ?? probe?.startTime {
                infoRow("启动时间", elapsed(started))
            }
            if let dir = probe?.workingDirectory {
                infoRow("工作目录", (dir as NSString).abbreviatingWithTildeInPath)
            }
            if let exec = executableDisplay {
                infoRow("可执行文件", exec)
            }
            rawCommandSection
        }
        .padding(.bottom, 8)
    }

    /// helper 无 NSRunningApplication 时，从真实路径推断所属 bundle。
    private var inferredBundlePath: String? {
        guard let path = probe?.executablePath,
              let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 官方样式："SunBrowser.app / SunBrowser Helper (Renderer)"；非 bundle 进程给全路径。
    private var executableDisplay: String? {
        guard let path = probe?.executablePath else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        if let bundle = parts.last(where: { $0.hasSuffix(".app") }), let name = parts.last, bundle != name {
            return "\(bundle) / \(name)"
        }
        return path
    }

    /// 原始路径与命令（可折叠，等宽字体盒子，可选中复制）。
    @ViewBuilder
    private var rawCommandSection: some View {
        if let cmd = probe?.arguments ?? proc.command {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showRawCommand.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showRawCommand ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("原始路径与命令")
                        Text("1")
                    }
                    .font(Fonts.mono(11, .medium))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(look.line.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .pointingCursor()
                if showRawCommand {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("命令").font(Fonts.mono(10)).foregroundStyle(look.textMute)
                        Text(cmd)
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(look.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.line, lineWidth: 1))
                }
            }
            .padding(.top, 10)
        }
    }

    private func elapsed(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func fmtIO(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label)
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(Fonts.mono(12.5))
                .foregroundStyle(look.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private func footer(isSystem: Bool) -> some View {
        HStack(spacing: 10) {
            if isSystem {
                // 三通道：琥珀色 + 警示图标 + 文字
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text("系统进程，无法终止。")
                        .font(Fonts.ui(12))
                }
                .foregroundStyle(Semantic.warn)
            }
            Spacer()
            ghostButton("复制摘要") { store.copySummary(proc) }
            ghostButton("显示") { store.reveal(proc) }
            if !isSystem {
                ghostButton("终止") {
                    store.detailProc = nil
                    store.confirmKill = proc
                }
                Button {
                    store.detailProc = nil
                    store.confirmKill = proc
                } label: {
                    Text("强制退出")
                        .font(Fonts.ui(12.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Semantic.dangerFill))
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(look.textDim)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(look.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
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
