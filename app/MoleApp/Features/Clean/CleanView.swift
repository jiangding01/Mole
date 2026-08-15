import MoleKit
import SwiftUI

/// 清理页（设计 §5.1 / 设计稿 clean 页）：
/// idle（光谱环呼吸 + 三承诺 + CTA）→ scanning（扫描头 + 实时读数 + 当前路径）
/// → confirm（环收束甜甜圈 + 分组勾选清单）→ executing（环放空 + 打勾清单）
/// → done / empty。进入时复用智能扫描已产出的 clean plan（§5.0）。
/// TODO(后续)：项目产物 / 安装包子 tab。
struct CleanView: View {
    @Environment(CleanStore.self) private var store
    @Environment(ScanSession.self) private var scanSession
    @State private var showsHistory = false
    /// 守卫提示条"查看应用"展开态（视图态，不进 Store）。
    @State private var guardExpanded = false
    private let look = Look.ink
    private let accent = ModuleAccent.clean

    /// 设计稿 clean 页无页级标题：idle 态居中呈现，confirm 态以汇总条开始（dc L253）。
    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .task {
            // 会话正向闭环（§5.0）：注入会话资产，复用智能扫描已产出的 clean plan。
            store.scanSession = scanSession
            store.adoptSessionPlanIfAvailable()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle: idleView
        case .scanning: scanningView
        case .confirm: confirmView
        case .executing: executingView
        case let .done(freed, failed, skipped, cancelled):
            doneView(freed: freed, failed: failed, skipped: skipped, cancelled: cancelled)
        case .empty: emptyView
        case let .failed(reason): failedView(reason)
        }
    }

    // MARK: - idle（环呼吸 + 三承诺 + CTA）

    private var idleView: some View {
        VStack(spacing: 0) {
            ZStack {
                SpectrumRingView(state: .idle, accent: accent)
                VStack(spacing: 8) {
                    Fonts.eyebrow("Clean", size: 11)
                        .foregroundStyle(look.textMute)
                    Text(L("clean.idle.title"))
                        .font(Fonts.serif(30, .semibold))
                        .foregroundStyle(look.text)
                }
            }
            // 三承诺（设计 §3：删前可预览 · 删后进废纸篓 · 删过有记录）
            HStack(spacing: 10) {
                promiseChip("eye", L("clean.promise.preview"))
                promiseChip("trash", L("clean.promise.trash"))
                promiseChip("clock.arrow.circlepath", L("clean.promise.logged"))
            }
            .padding(.top, 6)
            Button {
                store.startScan()
            } label: {
                Text(L("clean.cta.scan"))
                    .font(Fonts.ui(14, .semibold))
                    .padding(.horizontal, 30).padding(.vertical, 12)
                    .background(Capsule().fill(accent.gradient))
                    .foregroundStyle(accent.onAccent)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .padding(.top, 26)
            Text(L("clean.idle.sub"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func promiseChip(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(accent.b)
            Text(label)
                .font(Fonts.ui(11.5))
                .foregroundStyle(look.textDim)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(look.chrome))
        .overlay(Capsule().stroke(look.line, lineWidth: 1))
    }

    // MARK: - scanning（扫描头 + 实时读数 + 当前路径 + 停止）

    private var scanningView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(store.scanStartedAt)
            VStack(spacing: 0) {
                ZStack {
                    SpectrumRingView(
                        state: .scanning(head: (elapsed * 0.22).truncatingRemainder(dividingBy: 1)),
                        accent: accent
                    )
                    VStack(spacing: 7) {
                        Fonts.eyebrow("Scanning", size: 11)
                            .foregroundStyle(look.textMute)
                        bigBytes(store.scanBytesFound)
                        Text(CleanStore.sectionLabel(store.scanSection))
                            .font(Fonts.ui(12))
                            .foregroundStyle(look.textDim)
                    }
                }
                Text((store.scanCurrent as NSString).abbreviatingWithTildeInPath)
                    .font(Fonts.mono(11))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                    .padding(.top, 4)
                Button(L("clean.cta.stop")) { store.cancelScan() }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                    .contentShape(Capsule())
                    .padding(.top, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - confirm（环收束 + 分组勾选清单 + 底部执行条）

    private var confirmView: some View {
        HStack(alignment: .top, spacing: 18) {
            // 左：结果环（reveal 750ms 缓入）
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let reveal = min(1, timeline.date.timeIntervalSince(store.confirmRevealStart) / 0.75)
                ZStack {
                    SpectrumRingView(
                        state: .results(segments: ringSegments, reveal: reveal),
                        accent: accent
                    )
                    VStack(spacing: 7) {
                        Fonts.eyebrow("Reclaimable", size: 11)
                            .foregroundStyle(look.textMute)
                        bigBytes(store.checkedBytes)
                        Text(L("clean.confirm.selected", Int64(store.checkedCount)))
                            .font(Fonts.ui(12))
                            .foregroundStyle(look.textDim)
                    }
                }
            }
            .frame(width: 340)

            // 右：分组清单 + 底部执行条
            VStack(spacing: 0) {
                ScrollView {
                    // Lazy 是硬要求：真实扫描 1854 项，普通 VStack 在 tab 再入时
                    // 主线程同步重建全部行（含每行的 hover 追踪区），冻结数秒。
                    LazyVStack(spacing: 10) {
                        // 守卫提示条（r2 §P2）：洞察卡之上、info 级、可关闭
                        if !store.guardBlockedApps.isEmpty, !store.guardBarDismissed {
                            guardBar
                        }
                        ForEach(store.groups) { group in
                            groupCard(group)
                        }
                        if !store.insights.isEmpty { insightCard }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                confirmBar
            }
        }
    }

    private var ringSegments: [RingSegment] {
        let total = max(1, store.totalBytes)
        let palette: [Color] = [accent.a, accent.b, accent.a.opacity(0.6), accent.b.opacity(0.6)]
        return store.groups.enumerated().map { index, group in
            RingSegment(
                fraction: Double(group.bytes) / Double(total),
                color: palette[index % palette.count]
            )
        }
    }

    /// 摘要卡（r2 §P1.1）：默认折叠，组头一眼结论——复选框·图标·组名·
    /// 已选 X/Y·贡献条·已选/总体积·箭头。复选框与展开互相独立。
    private func groupCard(_ group: CleanStore.Group) -> some View {
        let expanded = store.isExpanded(group)
        let allZero = store.isAllZero(group)
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                CleanCheckBox(checked: store.groupChecked(group), accent: accent, look: look, size: 19) {
                    store.toggleGroup(group)
                }
                Image(systemName: Self.sectionIcon(group.section))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent.b)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(CleanStore.sectionLabel(group.section))
                            .font(Fonts.ui(13, .semibold))
                            .foregroundStyle(look.text)
                        Text(L("clean.group.selected", Int64(store.groupSelectedCount(group)), Int64(group.items.count)))
                            .font(Fonts.mono(10.5))
                            .foregroundStyle(look.textMute)
                    }
                    // 全 0 B 组（§P1.5）：无贡献条，直接告知无可释放
                    if allZero {
                        Text(L("clean.group.allZero", Int64(group.items.count)))
                            .font(Fonts.ui(10.5))
                            .foregroundStyle(look.textMute)
                    }
                }
                Spacer()
                // 贡献条（§P1.1 关键元素）：3px，宽度 = 组体积/最大组体积
                if !allZero, store.maxGroupBytes > 0 {
                    Capsule()
                        .fill(accent.gradient)
                        .frame(
                            width: max(6, 110 * CGFloat(group.bytes) / CGFloat(store.maxGroupBytes)),
                            height: 3
                        )
                        .opacity(0.85)
                }
                Text(allZero
                    ? verbatimSizePair(0, 0)
                    : verbatimSizePair(store.groupSelectedBytes(group), group.bytes))
                    .font(Fonts.mono(12))
                    .foregroundStyle(look.textDim)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(look.textMute)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { store.toggleExpand(group) }
            }
            .pointingCursor()

            if expanded {
                Divider().overlay(look.line)
                expandedRows(group)
            }
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1))
    }

    /// 展开区（§P1.3）：首屏 12 项（必然是组内 Top 大项）+「再显示 50 项」渐进；
    /// 0 B 长尾分隔而不聚合（§P1.4）。未展开的组完全不构建行。
    @ViewBuilder
    private func expandedRows(_ group: CleanStore.Group) -> some View {
        let sorted = store.sortedItems(group)
        let visible = store.visibleCount(group)
        let shown = Array(sorted.prefix(visible))
        let zeros = store.zeroCount(group)
        let firstZeroShownIndex = shown.firstIndex { $0.bytes == 0 }
        LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                if index == firstZeroShownIndex, !store.isAllZero(group) {
                    zeroSeparator(count: zeros)
                }
                itemRow(item, dimmed: item.bytes == 0)
            }
            if visible < sorted.count {
                revealMoreButton(group, remaining: sorted.count - visible)
            }
        }
        .padding(.vertical, 4)
    }

    /// 0 B 分隔线（§P1.4）：只计真 0 B；「大小未知」行排在此线之前，不受其陈述。
    private func zeroSeparator(count: Int) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(look.line).frame(height: 1)
            Text(L("clean.zero.separator", Int64(count)))
                .font(Fonts.ui(10))
                .foregroundStyle(look.textMute)
                .fixedSize()
            Rectangle().fill(look.line).frame(height: 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func revealMoreButton(_ group: CleanStore.Group, remaining: Int) -> some View {
        Button {
            store.revealMore(group)
        } label: {
            Text(L("clean.showMore", Int64(min(CleanStore.revealStep, remaining)), Int64(remaining)))
                .font(Fonts.ui(11.5, .medium))
                .foregroundStyle(look.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(look.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    /// "已选体积 / 总体积"（fmtGB 语义，§P1.1）。
    private func verbatimSizePair(_ selected: Int64, _ total: Int64) -> String {
        fmtGB(selected) + " / " + fmtGB(total)
    }

    private func itemRow(_ item: RobotItem, dimmed: Bool = false) -> some View {
        let checked = store.checked.contains(item.id)
        return HStack(spacing: 11) {
            CleanCheckBox(checked: checked, accent: accent, look: look, size: 17) {
                store.toggle(item)
            }
            Text(((item.path ?? item.label) as NSString).abbreviatingWithTildeInPath)
                .font(Fonts.mono(11.5))
                .foregroundStyle(checked ? look.text : look.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if item.risk == "caution" {
                Text(L("clean.badge.review"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Semantic.warn.opacity(0.12)))
                    .foregroundStyle(Semantic.warn)
            }
            // bytes == nil 是协议里的"大小未知"（测量超时），不是 0 B——如实说。
            // .help 只挂在未知行：每个 .help 注册一个 tooltip 追踪区，
            // 1854 行全挂（哪怕空字符串）是再入冻结的帮凶之一。
            if item.bytes == nil {
                Text(L("clean.size.unknown"))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
                    .frame(minWidth: 62, alignment: .trailing)
                    .help(L("clean.size.unknown.help"))
            } else if dimmed {
                // 0 B 行（r2 §P1.4）：测量出来的零，与"大小未知"是两回事
                Text(verbatim: "0 B")
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
                    .frame(minWidth: 62, alignment: .trailing)
                    .help(L("clean.zero.help"))
            } else {
                Text(item.bytes.map(fmt) ?? "")
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
                    .frame(minWidth: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .opacity(dimmed ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(item) }
        .pointingCursor()
    }

    /// 组头图标（原型语汇 → SF Symbols 映射，未知 slug 回退文件夹）。
    private static func sectionIcon(_ slug: String) -> String {
        switch slug {
        case "user_essentials": "person.crop.circle"
        case "app_caches", "application_support": "square.stack.3d.up"
        case "browsers": "globe"
        case "developer_tools", "development": "hammer"
        case "logs", "system_logs": "doc.text"
        case "trash": "trash"
        case "downloads": "arrow.down.circle"
        case "installers": "shippingbox"
        case "app_leftovers", "leftovers": "puzzlepiece"
        case "large_files": "doc.zipper"
        case "system_maintenance": "gearshape.2"
        case "external_volumes": "externaldrive"
        case "apps_utilities": "square.grid.2x2"
        case "cloud_office": "cloud"
        default: "folder"
        }
    }

    /// r2 fmtGB 语义：≥1 GB 两位小数 GB；≥1 MB 取整 MB；>0 取整 KB；零 = 0 B。
    /// （长尾是 MB/KB 级，统一 GB 两位小数会全变 0.00——设计明确要改。）
    private func fmtGB(_ bytes: Int64) -> String {
        if bytes >= 1 << 30 { return String(format: "%.2f GB", Double(bytes) / Double(1 << 30)) }
        if bytes >= 1 << 20 { return "\(bytes / (1 << 20)) MB" }
        if bytes > 0 { return "\(max(1, bytes / (1 << 10))) KB" }
        return "0 B"
    }

    /// 守卫提示条（r2 §P2）：冷灰 info 级、非阻断、可关闭。
    /// 红线：全程不出现任何字节数——被挡目标未被扫描，给不出就不编。
    /// 文案与设计稿的一处有意偏差：defer 记录只有应用名没有段名，
    /// 因此说"N 个应用"而非"N 个分组"（诚实贴数据能力）。
    private var guardBar: some View {
        let tint = Color(red: 0.616, green: 0.690, blue: 0.776) // #9DB0C6
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text(L("clean.guard.headline", Int64(store.guardBlockedApps.count)))
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textDim)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { guardExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(L("clean.guard.viewApps"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(guardExpanded ? 180 : 0))
                    }
                    .font(Fonts.ui(11.5, .medium))
                    .foregroundStyle(tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingCursor()
                Button {
                    store.guardBarDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(look.textMute)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
            .padding(.horizontal, 13).padding(.vertical, 10)

            if guardExpanded {
                Divider().overlay(look.line)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.guardBlockedApps, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(nsImage: Self.runningAppIcon(named: name))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(name)
                                .font(Fonts.ui(12))
                                .foregroundStyle(look.text)
                        }
                    }
                    Text(L("clean.guard.footnote"))
                        .font(Fonts.ui(10.5))
                        .foregroundStyle(look.textMute)
                        .padding(.top, 3)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    /// 被挡应用图标：按名称匹配运行中应用；退出了/匹配不到给通用图标。
    private static func runningAppIcon(named name: String) -> NSImage {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// 空间洞察（info 级，不可勾，仅提示，去分析页处理）。
    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 10))
                    .foregroundStyle(Semantic.info)
                Fonts.eyebrow(L("clean.insight.title"), size: 10)
                    .foregroundStyle(Semantic.info)
            }
            ForEach(Array(store.insights.enumerated()), id: \.offset) { _, insight in
                HStack {
                    Text((insight.label as NSString).abbreviatingWithTildeInPath)
                        .font(Fonts.mono(11))
                        .foregroundStyle(look.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(insight.bytes.map(fmt) ?? L("clean.size.unknown"))
                        .font(Fonts.mono(11))
                        .foregroundStyle(look.textMute)
                }
            }
            Text(L("clean.insight.hint"))
                .font(Fonts.ui(10.5))
                .foregroundStyle(look.textMute)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Semantic.info.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Semantic.info.opacity(0.25), lineWidth: 1))
    }

    private var confirmBar: some View {
        HStack(spacing: 10) {
            Button(L("clean.cta.rescan")) { store.startScan() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(look.textDim)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("clean.confirm.summary", Int64(store.checkedCount), fmt(store.checkedBytes)))
                    .font(Fonts.mono(12))
                    .foregroundStyle(look.textDim)
                // 设计红线：总计只累加已知项，未知项单独如实声明（CHANGELOG §1.2）。
                if store.checkedUnknownCount > 0 {
                    Text(L("clean.confirm.unknown", Int64(store.checkedUnknownCount)))
                        .font(Fonts.ui(10.5))
                        .foregroundStyle(look.textMute)
                        .textCase(.uppercase)
                        .kerning(0.5)
                }
            }
            Button {
                store.execute()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                    Text(L("clean.cta.clean"))
                }
                .font(Fonts.ui(13, .semibold))
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .disabled(store.checked.isEmpty)
            .opacity(store.checked.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .padding(.top, 12)
    }

    // MARK: - executing（环放空 + 实时读数 + 打勾清单 + 停止）

    private var executingView: some View {
        VStack(spacing: 0) {
            ZStack {
                SpectrumRingView(
                    state: .executing(segments: ringSegments, progress: store.executeProgress),
                    accent: accent
                )
                VStack(spacing: 7) {
                    Fonts.eyebrow("Cleaning", size: 11)
                        .foregroundStyle(look.textMute)
                    bigBytes(store.freed)
                    Text(L("clean.executing.caption"))
                        .font(Fonts.ui(12))
                        .foregroundStyle(look.textDim)
                }
            }
            executeChecklist
                .frame(maxWidth: 560)
                .frame(maxHeight: .infinity)
            Button(L("clean.cta.stopClean")) { store.cancelExecute() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .foregroundStyle(look.textMute)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var executeChecklist: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.log) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.ok ? "checkmark" : "shield")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(entry.ok ? accent.b : Semantic.warn)
                                .frame(width: 14)
                            Text(entry.name)
                                .font(Fonts.mono(12))
                                .foregroundStyle(look.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !entry.ok, let label = CleanStore.statusLabel(entry.status) {
                                Text(label)
                                    .font(Fonts.ui(10, .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Semantic.warn.opacity(0.12)))
                                    .foregroundStyle(Semantic.warn)
                            }
                            Spacer()
                            Text(entry.bytes > 0 ? fmt(entry.bytes) : "--")
                                .font(Fonts.mono(11.5))
                                .foregroundStyle(look.textMute)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: store.log.count) {
                if let last = store.log.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - done / empty / failed

    private func doneView(freed: Int64, failed: Int, skipped: Int, cancelled: Int) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(accent.b)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent.a.opacity(0.12)))
            Fonts.eyebrow("Cleaned", size: 11)
                .foregroundStyle(look.textMute)
                .padding(.top, 22)
            Text(L("clean.done.freed", fmt(freed)))
                .font(Fonts.serif(54, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 10)
            Text(L("clean.done.trash"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
                .padding(.top, 10)
            if cancelled > 0 {
                noteLine("hand.raised", L("clean.done.cancelled", Int64(cancelled)), Semantic.warn)
            }
            if failed > 0 {
                noteLine("exclamationmark.triangle", L("clean.done.failed", Int64(failed)), Semantic.warn)
            }
            if skipped > 0 {
                noteLine("shield", L("clean.done.skipped", Int64(skipped)), look.textMute)
            }
            HStack(spacing: 12) {
                Button(L("apps.done.history")) { showsHistory = true }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                Button(L("clean.cta.rescan")) { store.startScan() }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(13, .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Capsule().fill(accent.gradient))
                    .foregroundStyle(accent.onAccent)
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsHistory) { HistoryView() }
    }

    private func noteLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text)
        }
        .font(Fonts.ui(12))
        .foregroundStyle(color)
        .padding(.top, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent.b)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent.a.opacity(0.12)))
            Text(L("clean.empty.title"))
                .font(Fonts.serif(30, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 20)
            Text(L("clean.empty.sub"))
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 10)
            Button(L("clean.cta.rescan")) { store.startScan() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(13, .semibold))
                .foregroundStyle(look.textDim)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 30))
                .foregroundStyle(Semantic.warn)
            Text(L("clean.failed.title"))
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.text)
            Text(reason)
                .font(Fonts.mono(11))
                .foregroundStyle(look.textMute)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L("common.retry")) { store.startScan() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 小工具

    private func bigBytes(_ bytes: Int64) -> some View {
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let parts = text.split(separator: " ", maxSplits: 1)
        let number = parts.first.map(String.init) ?? "0"
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            // 定宽 cell（SerifTabularNumber）：扫描态 60fps 刷新时
            // Instrument Serif 无 tnum，普通 Text 会横向抖动（设计 §四）。
            // MB/KB 段数字更长（"934.8"五字符），降一档字号防蹭环刻度。
            SerifTabularNumber(
                text: number, size: number.count > 4 ? 38 : 44,
                weight: .semibold, color: look.text
            )
            Text(parts.count > 1 ? String(parts[1]) : "")
                .font(Fonts.mono(14))
                .foregroundStyle(look.textDim)
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 清理页复选框（与软件页 CheckBox 同款式样；组件抽公用留待清理页稳定后）。
private struct CleanCheckBox: View {
    var checked: Bool
    var accent: ModuleAccent
    var look: Look
    var size: CGFloat
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(checked ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.clear))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.29)
                        .stroke(checked ? accent.a : look.lineStrong, lineWidth: 1.5)
                )
                .overlay {
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.52, weight: .bold))
                            .foregroundStyle(accent.onAccent)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}
