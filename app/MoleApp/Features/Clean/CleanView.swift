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
    /// 确认页结果环 reveal 完成标记：置位后两层 TimelineView 全部停帧。
    @State private var confirmRingSettled = false
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
            // 左：结果环（reveal 750ms 缓入；收束后整条动画链停摆——
            // 30fps 改 reveal 会让环子树每帧重建，叠加大清单布局曾致
            // 全窗永久无响应，见 SpectrumRingView.paused 注释）
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: confirmRingSettled)) { timeline in
                let reveal = min(1, timeline.date.timeIntervalSince(store.confirmRevealStart) / 0.75)
                ZStack {
                    SpectrumRingView(
                        state: .results(segments: ringSegments, reveal: reveal),
                        accent: accent,
                        paused: confirmRingSettled
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
            // 每份新 plan（confirmRevealStart 变化）重放一次 reveal，
            // 850ms 后（750ms 动画 + 余量）停摆。
            .task(id: store.confirmRevealStart) {
                confirmRingSettled = false
                try? await Task.sleep(for: .milliseconds(850))
                if !Task.isCancelled { confirmRingSettled = true }
            }

            // 右：分组清单 + 底部执行条
            VStack(spacing: 0) {
                ScrollView {
                    // 单层 LazyVStack 是硬要求，且清单必须**拍平**：组头、条目行、
                    // 翻页按钮各自是顶层懒加载单元。曾经的形态是"卡片=一个 lazy
                    // item、行区是卡片内普通 VStack"——展开+翻页后整卡数百行全部
                    // 实体化，此后任何一次失效（滚动、勾选、展开动画的每一帧）都
                    // 要整树重测数百个双行 Text，真机单遍数百毫秒、事务排队即
                    // 无响应（2026-08-15 第三次卡死采样实证；嵌套 LazyVStack 拿
                    // 不到视口会退化，见 git 史，唯一出路就是拍平）。
                    LazyVStack(spacing: 0) {
                        // 守卫提示条（r2 §P2）：洞察卡之上、info 级、可关闭
                        if !store.guardBlockedApps.isEmpty, !store.guardBarDismissed {
                            guardBar.padding(.bottom, 10)
                        }
                        ForEach(store.groups) { group in
                            groupHeader(group)
                                .padding(.bottom, store.isExpanded(group) ? 0 : 10)
                            if store.isExpanded(group) {
                                expandedRows(group)
                            }
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

    /// 摘要卡组头（r2 §P1.1）：默认折叠，一眼结论——复选框·图标·组名·
    /// 已选 X/Y·贡献条·已选/总体积·箭头。复选框与展开互相独立。
    /// 拍平后组头是独立懒加载单元：折叠时整卡圆角+描边，展开时只圆上缘、
    /// 行区元素各自续接卡底色（描边省略是性能重构的有意视觉简化）。
    private func groupHeader(_ group: CleanStore.Group) -> some View {
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
            }
        }
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 13,
                bottomLeadingRadius: expanded ? 0 : 13,
                bottomTrailingRadius: expanded ? 0 : 13,
                topTrailingRadius: 13
            )
            .fill(look.surface)
        )
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1)
            }
        }
    }

    /// 展开区（§P1.3 + r3 §P5）：分页单位是展示节点（聚合父行算一行），
    /// 首屏 12 + 「再显示 50」渐进；0 B 长尾分隔而不跨语义聚合（§P1.4）。
    /// **不包 VStack**：每行直接作为外层 LazyVStack 的懒加载单元（拍平虚拟化，
    /// 理由见 confirmView 注释），只有视口附近的行会实体化与参与布局。
    /// 未展开的组连 ForEach 都不进入。
    @ViewBuilder
    private func expandedRows(_ group: CleanStore.Group) -> some View {
        let nodes = store.displayNodes(group)
        let visible = store.visibleCount(group)
        let shown = Array(nodes.prefix(visible))
        let zeros = store.zeroCount(group)
        let firstZeroShownIndex = shown.firstIndex { node in
            if case let .single(item) = node { return item.bytes == 0 }
            return false
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
            if index == firstZeroShownIndex, !store.isAllZero(group) {
                zeroSeparator(count: zeros).background(look.surface)
            }
            nodeRow(node).background(look.surface)
        }
        if visible < nodes.count {
            revealMoreButton(group, remaining: nodes.count - visible)
                .background(look.surface)
        }
        // 底盖：无论行区最后一个元素是什么，展开卡都以圆角收尾
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 13,
            bottomTrailingRadius: 13, topTrailingRadius: 0
        )
        .fill(look.surface)
        .frame(height: 8)
        .padding(.bottom, 10)
    }

    /// 节点渲染（r3 §P5）：单项直出；聚合 = 父行表头 + 展开后一级缩进子行。
    @ViewBuilder
    private func nodeRow(_ node: CleanStore.DisplayNode) -> some View {
        switch node {
        case let .single(item):
            itemRow(item, dimmed: item.bytes == 0)
        case let .aggregate(parent, items):
            aggregateRow(node, parent: parent, items: items)
            if store.isAggregateExpanded(node) {
                // 子行一级缩进 22px（§P5.3），各自体积、各自行内动作
                VStack(spacing: 0) {
                    ForEach(items, id: \.id) { item in
                        itemRow(item, dimmed: item.bytes == 0)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    /// 聚合父行（§P5）：三态复选框 + 语义名/父路径 + 「N 项」 + 总量 + 动作簇。
    /// 父行本身不参与体积统计（总量由子行汇总）；默认收起。
    private func aggregateRow(
        _ node: CleanStore.DisplayNode, parent: String, items: [RobotItem]
    ) -> some View {
        CleanAggregateRow(
            parent: parent,
            count: items.count,
            bytes: store.aggregateBytes(items),
            allChecked: store.aggregateAllChecked(items),
            anyChecked: store.aggregateAnyChecked(items),
            expanded: store.isAggregateExpanded(node),
            whitelisted: store.aggregateWhitelisted(items),
            whitelistBusy: store.aggregateWhitelistBusy(items),
            lockedBy: store.aggregateLocked(items) ? items.first?.blockedBy : nil,
            look: look,
            accent: accent,
            onToggle: { store.toggleAggregate(items) },
            onExpand: {
                withAnimation(.easeOut(duration: 0.15)) { store.toggleAggregateExpand(node) }
            },
            onReveal: { store.revealPath(parent) },
            onWhitelist: { store.toggleAggregateWhitelist(items) }
        )
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
        CleanItemRow(
            item: item,
            checked: store.checked.contains(item.id),
            dimmed: dimmed,
            whitelisted: store.isWhitelisted(item),
            whitelistBusy: store.isWhitelistBusy(item),
            locked: store.isLocked(item),
            look: look,
            accent: accent,
            onToggle: { store.toggle(item) },
            onReveal: { store.revealInFinder(item) },
            onWhitelist: { store.toggleWhitelist(item) }
        )
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
        case "apps_and_utilities": "square.grid.2x2"
        case "cloud_and_office": "cloud"
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
            // 选择预设三连（r3 §P6）：主操作左侧、弱化为文本按钮；
            // 「推荐」= 协议 default_selected，选择恰等推荐集时字色高亮作状态指示。
            HStack(spacing: 14) {
                presetButton(L("clean.preset.all")) { store.selectAll() }
                presetButton(L("clean.preset.none")) { store.selectNone() }
                presetButton(
                    L("clean.preset.recommended"),
                    highlighted: store.isRecommendedSelection
                ) { store.selectRecommended() }
            }
            Rectangle()
                .fill(look.line)
                .frame(width: 1, height: 16)
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

    private func presetButton(
        _ title: String, highlighted: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .pointingCursor()
            .font(Fonts.ui(12, highlighted ? .semibold : .medium))
            .foregroundStyle(highlighted ? accent.b : look.textDim)
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
/// `indeterminate`：聚合父行半选态（r3 §P5.4），横杠替代对勾。
private struct CleanCheckBox: View {
    var checked: Bool
    var indeterminate: Bool = false
    var accent: ModuleAccent
    var look: Look
    var size: CGFloat
    var onToggle: () -> Void

    var body: some View {
        let filled = checked || indeterminate
        Button(action: onToggle) {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(filled ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.clear))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.29)
                        .stroke(filled ? accent.a : look.lineStrong, lineWidth: 1.5)
                )
                .overlay {
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.52, weight: .bold))
                            .foregroundStyle(accent.onAccent)
                    } else if indeterminate {
                        Image(systemName: "minus")
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

// MARK: - 聚合父行（r3 §P5）

/// 同父目录子项的可折叠表头：三态复选框、语义名或父路径、子项数 + 总量、
/// 行内动作（Finder 显示父目录 / 盾牌批量加白）。父行 size 不参与统计。
/// 独立结构体、42px 定高，与条目行同一套性能约束。
private struct CleanAggregateRow: View {
    var parent: String
    var count: Int
    var bytes: Int64
    var allChecked: Bool
    var anyChecked: Bool
    var expanded: Bool
    var whitelisted: Bool
    var whitelistBusy: Bool
    /// 全部子行锁定时父行继承锁定态（r3 §P4 父子继承），值 = 首个子行的 blocked_by。
    var lockedBy: String?
    var look: Look
    var accent: ModuleAccent
    var onToggle: () -> Void
    var onExpand: () -> Void
    var onReveal: () -> Void
    var onWhitelist: () -> Void

    private static let wlTint = Color(red: 0.616, green: 0.690, blue: 0.776)

    var body: some View {
        let name = CleanPathNames.semanticName(forAbbreviatedPath: parent)
        HStack(spacing: 11) {
            if lockedBy != nil {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(CleanItemRow.lockTint)
                    .frame(width: 17, height: 17)
                    .help(lockHelp)
            } else {
                CleanCheckBox(
                    checked: allChecked,
                    indeterminate: !allChecked && anyChecked,
                    accent: accent, look: look, size: 17, onToggle: onToggle
                )
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(look.textMute)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    // 命名走同一张映射表；映射不到用父路径本身——绝不编造（§P2/§P5）
                    if let name {
                        Text(name)
                            .font(Fonts.ui(12.5, .medium))
                            .foregroundStyle(look.text)
                    } else {
                        Text(parent)
                            .font(Fonts.mono(12))
                            .foregroundStyle(look.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(L("clean.agg.count", Int64(count)))
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(look.textMute)
                }
                if name != nil {
                    Text(parent)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(look.textMute)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if whitelisted {
                Text(L("clean.badge.whitelisted"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Self.wlTint.opacity(0.14)))
                    .foregroundStyle(Self.wlTint)
            } else if lockedBy != nil {
                Text(CleanStore.lockAppName(lockedBy) != nil
                    ? L("clean.lock.badge.app") : L("clean.lock.badge.sys"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(CleanItemRow.lockTint.opacity(0.13))
                    )
                    .foregroundStyle(CleanItemRow.lockTint)
                    .help(lockHelp)
            }
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textDim)
                .frame(width: 74, alignment: .trailing)
            actionsCluster
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .opacity(whitelisted ? 0.5 : (lockedBy != nil ? 0.72 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    private var lockHelp: String {
        if let app = CleanStore.lockAppName(lockedBy) {
            L("clean.lock.help.app", app)
        } else {
            L("clean.lock.help.sys")
        }
    }

    /// 常驻 .55、无 hover 追踪区、tooltip 只留盾牌——理由见 CleanItemRow.actionsCluster。
    private var actionsCluster: some View {
        HStack(spacing: 4) {
            Button(action: onReveal) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(look.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onWhitelist) {
                Image(systemName: whitelisted ? "shield.fill" : "shield")
                    .font(.system(size: 11))
                    .foregroundStyle(whitelisted ? Self.wlTint : look.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(whitelistBusy)
            .help(whitelisted
                ? L("clean.action.unwhitelist.help")
                : L("clean.action.whitelist.agg.help"))
        }
        .opacity(0.55)
    }
}

// MARK: - 条目行（性能关键）

/// 确认清单条目行。独立 View 结构体而非视图函数：SwiftUI 按行 diff，
/// 勾选/翻页只重建变化的行——函数式写法会让每次 store 变更重算全部可见行。
/// 行上**不挂 pointingCursor**：它的 NSTrackingArea 在每次 mouseMoved 都强制
/// 设置光标，几百行同时注册是"展开开发者工具即卡死"的直接原因；
/// tooltip 同理只保留在未知/0B 行（数据必需），普通行零追踪区。
private struct CleanItemRow: View {
    var item: RobotItem
    var checked: Bool
    var dimmed: Bool
    var whitelisted: Bool
    var whitelistBusy: Bool
    var locked: Bool
    var look: Look
    var accent: ModuleAccent
    var onToggle: () -> Void
    var onReveal: () -> Void
    var onWhitelist: () -> Void

    /// 白名单徽标/守卫条同款冷灰蓝（#9DB0C6）。
    private static let wlTint = Color(red: 0.616, green: 0.690, blue: 0.776)
    /// 行级锁定琥珀（r3 §P4 #E3B34E）。
    static let lockTint = Color(red: 0.890, green: 0.702, blue: 0.306)

    var body: some View {
        let path = ((item.path ?? item.label) as NSString).abbreviatingWithTildeInPath
        let name = CleanPathNames.semanticName(forAbbreviatedPath: path)
        HStack(spacing: 11) {
            if locked {
                // 锁图标替代复选框（§P4）：selectable() 在 Store 侧已排除，
                // 这里连勾选入口一起拿掉，形态即语义。
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.lockTint)
                    .frame(width: 17, height: 17)
                    .help(lockHelp)
            } else {
                CleanCheckBox(
                    checked: checked, accent: accent, look: look, size: 17, onToggle: onToggle
                )
            }
            if let name {
                // 双行形态（r3 §P2）：语义名主行 + mono 路径副行。
                // 副行从头部截断保尾段——尾段（profile 散列/子目录名）才是识别用的；
                // 完整路径挂 tooltip。
                // 副行不挂完整路径 tooltip：262 可见行 × 每行多个 .help/onHover
                // 响应区曾把 hover 机制推回布局风暴（2026-08-15 真机采样：
                // enqueueHoverUpdateIfNeeded → 全行 responder 图 → 整树重排）。
                // 全路径复核走行内"Finder 显示"。
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Fonts.ui(12.5, .medium))
                        .foregroundStyle(checked ? look.text : look.textDim)
                    Text(path)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(look.textMute)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                // 回退单行（约 18% 长尾）：映射不到就只给路径，绝不编造名称；
                // 路径此时是主信息，字号/色阶提一档（12px · textDim）。
                Text(path)
                    .font(Fonts.mono(12))
                    .foregroundStyle(checked ? look.text : look.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // 已加白名单徽标（r3 §P3 可撤销状态机）：不移除、可见后果、可撤销。
            if whitelisted {
                Text(L("clean.badge.whitelisted"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Self.wlTint.opacity(0.14)))
                    .foregroundStyle(Self.wlTint)
            } else if locked {
                // 行级锁定徽标（§P4）：应用打开中 / 系统占用——扫到了但此刻不可删
                Text(CleanStore.lockAppName(item.blockedBy) != nil
                    ? L("clean.lock.badge.app") : L("clean.lock.badge.sys"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Self.lockTint.opacity(0.13)))
                    .foregroundStyle(Self.lockTint)
                    .help(lockHelp)
            } else if item.risk == "caution" {
                Text(L("clean.badge.review"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Semantic.warn.opacity(0.12)))
                    .foregroundStyle(Semantic.warn)
            }
            sizeColumn
            actionsCluster
        }
        .padding(.horizontal, 14)
        // 定高行：弹性高度让 StackLayout 对每行做多轮 sizeThatFits，
        // 数百行 × 截断文本测量是布局风暴的单次成本大头。42px 居中行盒
        // 同时容纳双行与回退单行两种形态，两端各列天然成列（r3 §P2）。
        .frame(height: 42)
        // 透明度分档（§P4 定稿）：白名单 .5 / 锁定 .72 / 0B .62，彼此可区分
        .opacity(whitelisted ? 0.5 : (locked ? 0.72 : (dimmed ? 0.62 : 1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// 锁定行 hover 说明（§P4）：锁图标与徽标同一句。
    private var lockHelp: String {
        if let app = CleanStore.lockAppName(item.blockedBy) {
            L("clean.lock.help.app", app)
        } else {
            L("clean.lock.help.sys")
        }
    }

    /// 行内动作（r3 §P3）：Finder 显示 + 白名单盾牌，常驻 opacity .55。
    /// 与设计稿的有意偏差（同 r2 去 pointingCursor 的先例）：不做 hover 升亮
    /// ——每行 onHover 的 @State 翻转会让鼠标扫过清单时连发布局事务，
    /// 叠加数百双行 Text 测量 = 布局风暴复发（真机采样实证）。tooltip 只留
    /// 盾牌一处：白名单后果说明是设计红线，文件夹图标自明。
    private var actionsCluster: some View {
        HStack(spacing: 4) {
            Button(action: onReveal) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(look.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onWhitelist) {
                Image(systemName: whitelisted ? "shield.fill" : "shield")
                    .font(.system(size: 11))
                    .foregroundStyle(whitelisted ? Self.wlTint : look.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(whitelistBusy)
            .help(whitelisted
                ? L("clean.action.unwhitelist.help")
                : L("clean.action.whitelist.help"))
        }
        .opacity(0.55)
    }

    @ViewBuilder
    private var sizeColumn: some View {
        // bytes == nil 是协议里的"大小未知"（测量超时），不是 0 B——如实说。
        if item.bytes == nil {
            Text(L("clean.size.unknown"))
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textMute)
                .frame(width: 74, alignment: .trailing)
                .help(L("clean.size.unknown.help"))
        } else if dimmed {
            // 0 B 行（r2 §P1.4）：测量出来的零，与"大小未知"是两回事
            Text(verbatim: "0 B")
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textMute)
                .frame(width: 74, alignment: .trailing)
                .help(L("clean.zero.help"))
        } else {
            Text(ByteCountFormatter.string(fromByteCount: item.bytes ?? 0, countStyle: .file))
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textMute)
                .frame(width: 74, alignment: .trailing)
        }
    }
}
