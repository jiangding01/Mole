import MoleKit
import SwiftUI

/// 智能扫描首页（设计 §6.1，App 默认页）。
///
/// 光谱环三态（idle 呼吸 / scanning 扫描头 / results 甜甜圈）+ 结论卡矩阵。
/// 扫描结果写入 ScanSession，清理页零重扫复用（§5.0）。结论卡经 Router 跨页跳转。
struct SmartScanView: View {
    @Environment(SmartScanStore.self) private var store
    @Environment(ScanSession.self) private var scanSession
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let look = Look.ink
    private let accent = ModuleAccent.smart

    // 甜甜圈段色（设计 SEGS，与卡色略有差异，照设计稿）。
    private let segGreen = Color(hex: 0x46A588)
    private let segPurple = Color(hex: 0x8E72CE)
    private let segOrange = Color(hex: 0xC0803A)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ringAndCenter
                phaseBlock
            }
            .frame(maxWidth: Metrics.contentMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            store.scanSession = scanSession
            if store.phase == .idle { store.loadIdleMeta() }
        }
    }

    private var isResults: Bool {
        store.phase == .results
    }

    // MARK: - 光谱环 + 环心 overlay

    private var ringAndCenter: some View {
        ZStack {
            ringCanvas
            centerOverlay
        }
        .frame(width: 340, height: isResults ? 212 : 340)
        .animation(reduceMotion ? nil : .timingCurve(0.34, 1.1, 0.4, 1, duration: 0.55), value: isResults)
    }

    @ViewBuilder
    private var ringCanvas: some View {
        switch store.phase {
        case .idle, .failed:
            SpectrumRingView(state: .idle, accent: accent)
        case .scanning:
            if reduceMotion {
                SpectrumRingView(state: .scanning(head: 0.5), accent: accent)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    // 时间循环旋转（不代表完成度：真实扫描总量未知，§6.1 进度诚实）。
                    let elapsed = timeline.date.timeIntervalSince(store.scanStartedAt)
                    SpectrumRingView(
                        state: .scanning(head: (elapsed * 0.24).truncatingRemainder(dividingBy: 1)),
                        accent: accent
                    )
                }
            }
        case .results:
            resultsRing
        }
    }

    @ViewBuilder
    private var resultsRing: some View {
        if reduceMotion {
            SpectrumRingView(state: .results(segments: donutSegments, reveal: 1), accent: accent)
                .scaleEffect(0.6)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let reveal = min(1, timeline.date.timeIntervalSince(store.resultsRevealStart) / 0.75)
                SpectrumRingView(state: .results(segments: donutSegments, reveal: reveal), accent: accent)
            }
            .scaleEffect(0.6)
        }
    }

    private var donutSegments: [RingSegment] {
        var segs: [RingSegment] = []
        let r = store.results
        if r.safeBytes > 0 { segs.append(RingSegment(fraction: Double(r.safeBytes), color: segGreen)) }
        if r.leftoverBytes > 0 { segs.append(RingSegment(fraction: Double(r.leftoverBytes), color: segPurple)) }
        if r.installerBytes > 0 { segs.append(RingSegment(fraction: Double(r.installerBytes), color: segOrange)) }
        return segs
    }

    @ViewBuilder
    private var centerOverlay: some View {
        switch store.phase {
        case .idle, .failed:
            VStack(spacing: 8) {
                eyebrow(L("smart.ring.ready"), size: 10, em: 0.28, color: look.textMute)
                Circle()
                    .fill(accent.a)
                    .frame(width: 5, height: 5)
                    .overlay(Circle().stroke(accent.a.opacity(0.12), lineWidth: 5))
            }
        case .scanning:
            VStack(spacing: 6) {
                eyebrow(L("smart.ring.reclaimable"), size: 10, em: 0.24, color: look.textMute)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 设计 CHANGELOG §四：扫描态计数器与结果态统一衬线（56px），
                    // 定宽 cell 防比例数字抖动；单位 GB 保持 mono。
                    SerifTabularNumber(
                        text: gb2(store.reclaimableBytes), size: 56,
                        color: look.text
                    )
                    Text(verbatim: "GB")
                        .font(Fonts.mono(15, .medium))
                        .foregroundStyle(accent.a)
                }
            }
        case .results:
            VStack(spacing: 1) {
                eyebrow(L("smart.ring.reclaimable"), size: 9, em: 0.26, color: look.textMute)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(gb1(store.results.totalReclaimableBytes))
                        .font(Fonts.serif(54, .regular))
                        .foregroundStyle(look.text)
                    Text(verbatim: "GB")
                        .font(Fonts.mono(12, .medium))
                        .foregroundStyle(accent.a)
                }
            }
        }
    }

    // MARK: - 各态内容块

    @ViewBuilder
    private var phaseBlock: some View {
        switch store.phase {
        case .idle:
            idleBlock(error: nil)
        case let .failed(reason):
            idleBlock(error: reason)
        case .scanning:
            scanningBlock
        case .results:
            resultsBlock
        }
    }

    // MARK: idle

    private func idleBlock(error: String?) -> some View {
        VStack(spacing: 0) {
            eyebrow(L("smart.idle.eyebrow"), size: 10, em: 0.26, color: look.textMute)
                .padding(.top, 2)
            startButton
                .padding(.top, 14)
            Text(error ?? idleSub)
                .font(Fonts.ui(13))
                .foregroundStyle(error == nil ? look.textDim : Semantic.danger)
                .multilineTextAlignment(.center)
                .padding(.top, 13)
            metaStrip
                .padding(.top, 34)
        }
    }

    private var startButton: some View {
        Button { store.startScan() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                Text(L("smart.cta.start"))
                    .font(Fonts.ui(15, .semibold))
            }
            .foregroundStyle(accent.onAccent)
            .padding(.horizontal, 30).padding(.vertical, 14)
            .background(Capsule().fill(accent.gradient))
            .overlay(
                Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1)
                    .blendMode(.plusLighter)
            )
            .shadow(color: accent.a.opacity(0.4), radius: 15, x: 0, y: 10)
            .contentShape(Capsule())
        }
        .buttonStyle(HoverLiftButtonStyle())
        .pointingCursor()
    }

    private var metaStrip: some View {
        HStack(spacing: 0) {
            metaCell(label: "Last scan", value: lastScanText, mono: false)
            metaDivider
            metaCell(label: "Last freed", value: lastFreedText, mono: true)
            metaDivider
            metaCell(label: "Disk free", value: diskFreeText, mono: true)
        }
        .padding(.horizontal, 6).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.text.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.line, lineWidth: 1))
    }

    private func metaCell(label: String, value: String, mono: Bool) -> some View {
        VStack(spacing: 3) {
            eyebrow(label, size: 9, em: 0.16, color: look.textMute)
            Text(value)
                .font(mono ? Fonts.mono(15, .medium) : Fonts.ui(13.5, .medium))
                .kerning(mono ? -0.3 : 0)
                .foregroundStyle(mono ? look.text : look.textDim)
        }
        .frame(minWidth: 92)
        .padding(.horizontal, 24).padding(.vertical, 2)
    }

    private var metaDivider: some View {
        Rectangle().fill(look.line).frame(width: 1, height: 26)
    }

    // MARK: scanning

    private var scanningBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PulsingDot(color: accent.a, size: 5, period: 1.0)
                Text((store.currentPath as NSString).abbreviatingWithTildeInPath)
                    .font(Fonts.mono(12))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            Button { store.stopScan() } label: {
                Text(L("smart.cta.stop"))
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 20).padding(.vertical, 9)
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .padding(.top, 18)
        }
        .padding(.top, 16)
    }

    // MARK: results

    private var resultsBlock: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(L("smart.results.title"))
                    .font(Fonts.serif(24, .regular))
                    .foregroundStyle(look.text)
                eyebrow(resultsSubtitle, size: 12, em: 0.14, color: look.textMute)
            }
            cardsGrid
                .padding(.top, 16)
            Button { store.rescan() } label: {
                Text(L("smart.cta.rescan"))
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .overlay(Capsule().stroke(look.line, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .padding(.top, 18)
        }
        .padding(.top, 6)
    }

    private var resultsSubtitle: String {
        L("smart.results.subtitle", Int64(store.results.insightCount))
    }

    private var cardsGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                ConclusionCard(card: card, look: look, index: index, reduceMotion: reduceMotion)
            }
        }
        .frame(maxWidth: 868)
    }

    private var cards: [CardData] {
        let r = store.results
        return [
            // 卡01 可安全清理（绿，→ 清理页）
            CardData(
                index: "01",
                icon: "trash",
                iconTint: Color(hex: 0x46A588),
                accentColor: Semantic.success,
                number: gb2(r.safeBytes),
                unit: L("smart.unit.gb"),
                title: L("smart.card.safe.title"),
                badge: .init(text: L("smart.badge.safe"), symbol: "shield.fill"),
                body: L("smart.card.safe.body"),
                cta: L("smart.cta.handle"),
                action: { router.go(.clean) }
            ),
            // 卡02 卸载残留（紫，→ 软件页）
            CardData(
                index: "02",
                icon: "shippingbox",
                iconTint: ModuleAccent.apps.a,
                accentColor: ModuleAccent.apps.b,
                number: "\(r.leftoverCount)",
                unit: L("smart.unit.count"),
                title: L("smart.card.leftovers.title"),
                badge: nil,
                body: L("smart.card.leftovers.body", gb1String(r.leftoverBytes)),
                cta: L("smart.cta.handle"),
                action: { router.go(.apps) }
            ),
            // 卡03 安装包（橙，→ 清理页）；clean 域无安装包 section 时降级
            CardData(
                index: "03",
                icon: "archivebox",
                iconTint: Color(hex: 0xC0803A),
                accentColor: Semantic.warnAlt,
                number: r.hasInstallers ? "\(r.installerCount)" : "—",
                unit: r.hasInstallers ? L("smart.unit.pcs") : "",
                title: L("smart.card.installers.title"),
                badge: nil,
                body: r.hasInstallers
                    ? L("smart.card.installers.body", gb1String(r.installerBytes))
                    : L("smart.card.installers.body.empty"),
                cta: L("smart.cta.handle"),
                action: { router.go(.clean) }
            ),
            // 卡04 空间洞察（橙，→ 分析页）；无 insight 时降级
            CardData(
                index: "04",
                icon: "square.grid.2x2",
                iconTint: ModuleAccent.analyze.a,
                accentColor: ModuleAccent.analyze.b,
                number: r.insight.flatMap { $0.bytes.map(gbConcise) } ?? "—",
                unit: r.insight?.bytes == nil ? "" : L("smart.unit.gb"),
                title: L("smart.card.insight.title"),
                badge: .init(text: L("smart.badge.insight"), symbol: nil),
                body: r.insight.map { L("smart.card.insight.body", insightPathText($0.path)) }
                    ?? L("smart.card.insight.body.empty"),
                cta: L("smart.cta.analyze"),
                action: { router.go(.analyze) }
            ),
        ]
    }

    // MARK: - 文案/格式辅助

    private func eyebrow(_ text: String, size: CGFloat, em: CGFloat, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .kerning(size * em)
            .foregroundStyle(color)
    }

    private func gb2(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1_000_000_000)
    }

    private func gb1(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    private func gb1String(_ bytes: Int64) -> String {
        gb1(bytes)
    }

    private func gbConcise(_ bytes: Int64) -> String {
        let v = Double(bytes) / 1_000_000_000
        return v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private func insightPathText(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// idle 副文案：设计 mock 的"约需 30 秒"在真机是分钟量级，不诚实。
    /// 冷启动说"通常需要几分钟"，之后用上次扫描的真实用时说话。
    private var idleSub: String {
        if let d = store.lastScanDuration {
            return L("smart.idle.sub.last", durationText(d))
        }
        return L("smart.idle.sub.first")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return L("smart.duration.sec", Int64(total)) }
        return L("smart.duration.min", Int64(total / 60), Int64(total % 60))
    }

    private var lastScanText: String {
        guard let date = store.lastScan else { return "—" }
        let cal = Calendar.current
        let time = Self.timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return L("smart.meta.today") + " " + time }
        if cal.isDateInYesterday(date) { return L("smart.meta.yesterday") + " " + time }
        return Self.dateFormatter.string(from: date)
    }

    private var lastFreedText: String {
        guard let bytes = store.lastFreedBytes else { return "—" }
        return gb1(bytes) + " GB"
    }

    private var diskFreeText: String {
        guard let free = store.diskFreeBytes, let total = store.diskTotalBytes else { return "—" }
        let g: (Int64) -> String = { String(format: "%.0f", Double($0) / 1_000_000_000) }
        return "\(g(free)) / \(g(total)) GB"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - 结论卡

private struct CardData {
    struct Badge {
        var text: String
        var symbol: String?
    }

    var index: String
    var icon: String
    /// 图标底色（低透明度）与图标描边色基色。
    var iconTint: Color
    /// 数字/单位/CTA/徽标主色。
    var accentColor: Color
    var number: String
    var unit: String
    var title: String
    var badge: Badge?
    var body: String
    var cta: String
    var action: () -> Void
}

private struct ConclusionCard: View {
    let card: CardData
    let look: Look
    let index: Int
    let reduceMotion: Bool

    @State private var appeared = false
    @State private var hovered = false

    private var enterDelay: Double {
        [0.02, 0.09, 0.16, 0.23][min(index, 3)]
    }

    var body: some View {
        Button(action: card.action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    iconBox
                    Spacer()
                    Text(card.index)
                        .font(Fonts.mono(10))
                        .foregroundStyle(look.textMute)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(card.number)
                        .font(Fonts.serif(44, .regular))
                        .foregroundStyle(card.accentColor)
                    if !card.unit.isEmpty {
                        Text(card.unit)
                            .font(Fonts.mono(13))
                            .foregroundStyle(card.accentColor)
                    }
                }
                .padding(.top, 14)
                titleRow
                    .padding(.top, 8)
                Text(card.body)
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textDim)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                HStack(spacing: hovered ? 9 : 5) {
                    Text(card.cta)
                        .font(Fonts.ui(12.5, .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(card.accentColor)
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(look.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(hovered ? look.lineStrong : look.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 14)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .offset(y: hovered ? -3 : 0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(.easeOut(duration: 0.2), value: hovered)
        .onHover { hovered = $0 }
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.55).delay(enterDelay)) {
                appeared = true
            }
        }
    }

    private var iconBox: some View {
        Image(systemName: card.icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(card.accentColor)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(card.iconTint.opacity(0.17)))
    }

    private var titleRow: some View {
        HStack(spacing: 7) {
            Text(card.title)
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.text)
            if let badge = card.badge {
                HStack(spacing: 3) {
                    if let symbol = badge.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 8, weight: .bold))
                    }
                    Text(badge.text)
                        .font(Fonts.ui(10, .semibold))
                }
                .foregroundStyle(card.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(card.iconTint.opacity(0.14)))
            }
        }
    }
}

// MARK: - 复用小组件

/// 呼吸圆点（dotPulse）。reduceMotion 下恒亮。
private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    let period: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(reduceMotion ? 1 : (on ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// CTA 悬停微抬 + 提亮（设计：translateY(-1) + brightness(1.05)）。
private struct HoverLiftButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovered ? 0.05 : 0)
            .offset(y: hovered ? -1 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: hovered)
            .onHover { hovered = $0 }
    }
}
