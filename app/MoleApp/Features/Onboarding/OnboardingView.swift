import MoleKit
import SwiftUI

/// 首启引导（设计 §5.8，规格取自设计稿 Mole.dc.html 1353–1408 行）。
///
/// 全屏 overlay：暖黑遮罩 + 背景模糊 + 480 宽居中卡片；卡片内三步横向滑轨
/// （承诺 / FDA / 可选 helper），底部步骤 dots。品牌金渐变取自 `ModuleAccent.smart`。
/// `accessibilityReduceMotion` 时滑轨改交叉淡入、脉冲动画停用。
struct OnboardingView: View {
    @Environment(OnboardingStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 入场动画状态（opacity 0→1 + translateY 5→0，0.25s ease，对应设计 pageIn）。
    @State private var appeared = false

    private let look = Look.ink
    private let smart = ModuleAccent.smart

    /// 卡片固定宽度（设计稿 480px），三步 step 页各占同宽，滑轨按此平移。
    private let cardWidth: CGFloat = 480

    var body: some View {
        ZStack {
            // 遮罩：背景模糊层（近似 backdrop-filter blur 8pt）+ 暖黑半透明色。
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color(red: 9 / 255, green: 7 / 255, blue: 5 / 255)
                .opacity(0.86)
                .ignoresSafeArea()

            card
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 5)
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            }
        }
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            // 三步滑轨（内容 clipped）
            track
                .frame(width: cardWidth)
                .clipped()
            // 步骤 dots（滑轨外，卡片底部）
            dots
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(width: cardWidth)
        .background(look.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(look.lineStrong, lineWidth: 1)
        )
        // 近似设计 0 40px 120px -30px rgba(0,0,0,.7)
        .shadow(color: .black.opacity(0.7), radius: 60, y: 25)
    }

    /// 三步横向滑轨；reduceMotion 时改为当前步交叉淡入。
    @ViewBuilder
    private var track: some View {
        if reduceMotion {
            stepView(store.step)
                .frame(width: cardWidth)
                .id(store.step)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: store.step)
        } else {
            HStack(spacing: 0) {
                stepView(1).frame(width: cardWidth)
                stepView(2).frame(width: cardWidth)
                stepView(3).frame(width: cardWidth)
            }
            .offset(x: -CGFloat(store.step - 1) * cardWidth)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.45), value: store.step)
        }
    }

    @ViewBuilder
    private func stepView(_ n: Int) -> some View {
        switch n {
        case 1: WelcomeStep()
        case 2: FullDiskAccessStep()
        default: HelperStep()
        }
    }

    // MARK: - 步骤 dots

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(1 ... 3, id: \.self) { i in
                let active = i == store.step
                Capsule()
                    .fill(active ? smart.a : look.text.opacity(0.18))
                    .frame(width: active ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.35), value: store.step)
            }
        }
    }
}

// MARK: - STEP 1 · 欢迎与三个承诺

private struct WelcomeStep: View {
    @Environment(OnboardingStore.self) private var store
    private let look = Look.ink
    private let smart = ModuleAccent.smart

    var body: some View {
        VStack(spacing: 0) {
            // 品牌徽标：76×76 金渐变圆角方块 + 鼹鼠 logo（MoleGlyph，见文件末转自设计稿 SVG）
            MoleGlyph()
                .fill(smart.onAccent, style: FillStyle(eoFill: true))
                .frame(width: 40, height: 40)
                .frame(width: 76, height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(smart.gradient)
                )
                .shadow(color: smart.a.opacity(0.6), radius: 25, y: 9)

            Text(L("onboarding.welcome.title"))
                .font(Fonts.serif(34))
                .foregroundStyle(look.text)
                .padding(.top, 20)

            Text(L("onboarding.welcome.sub1") + "\n" + L("onboarding.welcome.sub2"))
                .font(Fonts.ui(13.5))
                .foregroundStyle(look.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            // 三张承诺卡
            VStack(spacing: 10) {
                promise(
                    "eye",
                    title: L("onboarding.promise.preview.title"),
                    desc: L("onboarding.promise.preview.desc")
                )
                promise(
                    "trash",
                    title: L("onboarding.promise.trash.title"),
                    desc: L("onboarding.promise.trash.desc")
                )
                promise(
                    "clock.arrow.circlepath",
                    title: L("onboarding.promise.log.title"),
                    desc: L("onboarding.promise.log.desc")
                )
            }
            .padding(.top, 24)

            OnboardingCTA(title: L("onboarding.start")) { store.start() }
                .padding(.top, 24)
        }
        .padding(.horizontal, 44)
        .padding(.top, 46)
        .padding(.bottom, 34)
    }

    /// 承诺卡：图标框 + 标题/说明两行。
    private func promise(_ symbol: String, title: String, desc: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(smart.a)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(smart.a.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Fonts.ui(13.5, .semibold))
                    .foregroundStyle(look.text)
                Text(desc)
                    .font(Fonts.ui(11.5))
                    .foregroundStyle(look.textMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(RoundedRectangle(cornerRadius: 13).fill(look.text.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1))
    }
}

// MARK: - STEP 2 · 完全磁盘访问

private struct FullDiskAccessStep: View {
    @Environment(OnboardingStore.self) private var store
    private let look = Look.ink
    private let smart = ModuleAccent.smart

    var body: some View {
        VStack(spacing: 0) {
            OnboardingIconBox(symbol: "internaldrive")

            Text(L("onboarding.fda.title"))
                .font(Fonts.serif(28))
                .foregroundStyle(look.text)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            // 正文含加重片段「不会上传任何数据」（look.text）。
            (Text(L("onboarding.fda.bodyPrefix"))
                + Text(L("onboarding.fda.bodyEmphasis")).foregroundColor(look.text)
                + Text(L("onboarding.fda.bodySuffix")))
                .font(Fonts.ui(13.5))
                .foregroundColor(look.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            // 三态区（idle / waiting / ok），minHeight 84 保证切换不跳动。
            // 动画上下文挂在切换容器外层：分支插入/移除才会执行 transition。
            phaseArea
                .frame(maxWidth: .infinity, minHeight: 84)
                .animation(.easeOut(duration: 0.3), value: store.fdaPhase)
                .padding(.top, 26)

            // footer：返回 + 稍后再说（§5.8 三步均可跳过；跳过则功能降级并在权限页常驻提示）
            HStack(spacing: 18) {
                footerLink(L("onboarding.back")) { store.back() }
                footerLink(L("onboarding.fda.skip")) { store.skipFda() }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 44)
        .padding(.top, 46)
        .padding(.bottom, 34)
    }

    /// footer 文字链接（返回 / 稍后再说共用样式）。
    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    @ViewBuilder
    private var phaseArea: some View {
        switch store.fdaPhase {
        case .idle:
            VStack(spacing: 12) {
                OnboardingCTA(title: L("onboarding.fda.open")) { store.requestFda() }
                Text(L("onboarding.fda.hint"))
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textMute)
                    .multilineTextAlignment(.center)
            }
        case .waiting:
            VStack(spacing: 12) {
                HStack(spacing: 11) {
                    PulsingDot(color: Semantic.warnAlt)
                    Text(L("onboarding.fda.waiting"))
                        .font(Fonts.ui(14, .semibold))
                        .foregroundStyle(Semantic.warnAlt)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Semantic.warnAlt.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Semantic.warnAlt.opacity(0.26), lineWidth: 1)
                )
                Text(L("onboarding.fda.waitingHint"))
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textMute)
                    .multilineTextAlignment(.center)
            }
        case .granted:
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(Semantic.successAlt)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: 0x04241A))
                }
                .frame(width: 26, height: 26)
                Text(L("onboarding.fda.granted"))
                    .font(Fonts.ui(14, .semibold))
                    .foregroundStyle(Semantic.successAlt)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Semantic.successAlt.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Semantic.successAlt.opacity(0.3), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - STEP 3 · 可选后台助手

private struct HelperStep: View {
    @Environment(OnboardingStore.self) private var store
    private let look = Look.ink

    var body: some View {
        VStack(spacing: 0) {
            OnboardingIconBox(symbol: "checkmark.shield")

            Text(L("onboarding.helper.title"))
                .font(Fonts.serif(28))
                .foregroundStyle(look.text)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            // 正文含两处加重：「深度维护」与「现在跳过也完全没问题」（look.text）。
            (Text(L("onboarding.helper.body.p1"))
                + Text(L("onboarding.helper.body.emph1")).foregroundColor(look.text)
                + Text(L("onboarding.helper.body.p2"))
                + Text(L("onboarding.helper.body.emph2")).foregroundColor(look.text)
                + Text(L("onboarding.helper.body.p3")))
                .font(Fonts.ui(13.5))
                .foregroundColor(look.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            VStack(spacing: 10) {
                // 主按钮 v1 禁用：helper 组件（SMAppService）尚未落地。
                // TODO(helper): 组件落地后启用，点击调 store.finish(installHelper: true)。
                VStack(spacing: 6) {
                    OnboardingCTA(title: L("onboarding.helper.install"), disabled: true) {}
                    Text(L("onboarding.helper.comingSoon"))
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textMute)
                }
                // 次按钮（幽灵款）：跳过 → 完成引导。
                OnboardingGhostButton(title: L("onboarding.helper.skip")) {
                    store.finish()
                }
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 44)
        .padding(.top, 46)
        .padding(.bottom, 34)
    }
}

// MARK: - 共用组件

/// 主 CTA（三步共用）：全宽金渐变按钮，hover 微增亮。
private struct OnboardingCTA: View {
    let title: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false
    private let smart = ModuleAccent.smart

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(15, .bold))
                .foregroundStyle(smart.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(smart.gradient))
                .brightness(hovering && !disabled ? 0.05 : 0)
                .shadow(color: smart.a.opacity(0.5), radius: 15, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .pointingCursor()
    }
}

/// 幽灵款次按钮（Step 3 跳过）：透明底 + 描边，hover 文字提亮。
private struct OnboardingGhostButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false
    private let look = Look.ink

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(hovering ? look.text : look.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 12).stroke(look.lineStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingCursor()
    }
}

/// Step 2/3 头部图标框：76×76 金调描边方块 + 38pt 线性 SF Symbol。
private struct OnboardingIconBox: View {
    let symbol: String
    private let smart = ModuleAccent.smart

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(smart.a)
            .frame(width: 76, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(smart.a.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(smart.a.opacity(0.24), lineWidth: 1)
            )
    }
}

/// 等待态脉冲圆点（9pt，1s 周期 opacity 1↔0.3）；reduceMotion 时恒亮不脉冲。
private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(pulsing ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

// MARK: - 鼹鼠 logo 图形

/// 鼹鼠 logo（1:1 转自设计稿 Mole.dc.html 1361 行的 SVG path，24×24 viewBox）。
/// 身体轮廓由 SVG 相对三次贝塞尔逐段换算为绝对坐标；双眼用 even-odd 填充规则镂空，
/// 露出底层金渐变形成面部。使用时以 `FillStyle(eoFill: true)` 填充。
private struct MoleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * s, y: y * s)
        }
        var p = Path()
        // 身体轮廓
        p.move(to: pt(12, 3))
        p.addCurve(to: pt(5, 9), control1: pt(8, 3), control2: pt(5, 5.5))
        p.addCurve(to: pt(6.8, 13), control1: pt(5, 10.6), control2: pt(5.7, 12))
        p.addCurve(to: pt(6, 15.2), control1: pt(6.3, 13.6), control2: pt(6, 14.4))
        p.addCurve(to: pt(7, 16.2), control1: pt(6, 15.8), control2: pt(6.4, 16.2))
        p.addCurve(to: pt(7.8, 15.8), control1: pt(7.3, 16.2), control2: pt(7.6, 16.1))
        p.addCurve(to: pt(11, 17), control1: pt(8.7, 16.5), control2: pt(9.8, 16.9))
        p.addLine(to: pt(11, 18.5))
        p.addCurve(to: pt(12, 19.5), control1: pt(11, 19.1), control2: pt(11.4, 19.5))
        p.addCurve(to: pt(13, 18.5), control1: pt(12.6, 19.5), control2: pt(13, 19.1))
        p.addLine(to: pt(13, 17))
        p.addCurve(to: pt(16.2, 15.8), control1: pt(14.2, 16.9), control2: pt(15.3, 16.5))
        p.addCurve(to: pt(17, 16.2), control1: pt(16.4, 16.1), control2: pt(16.7, 16.2))
        p.addCurve(to: pt(18, 15.2), control1: pt(17.6, 16.2), control2: pt(18, 15.8))
        p.addCurve(to: pt(17.2, 13), control1: pt(18, 14.4), control2: pt(17.7, 13.6))
        p.addCurve(to: pt(19, 9), control1: pt(18.3, 12), control2: pt(19, 10.6))
        p.addCurve(to: pt(12, 3), control1: pt(19, 5.5), control2: pt(16, 3))
        p.closeSubpath()
        // 双眼（半径 1，中心 y=8）——even-odd 镂空
        p.addEllipse(in: CGRect(x: (9.5 - 1) * s, y: (8 - 1) * s, width: 2 * s, height: 2 * s))
        p.addEllipse(in: CGRect(x: (14.5 - 1) * s, y: (8 - 1) * s, width: 2 * s, height: 2 * s))
        return p
    }
}
