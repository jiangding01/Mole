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
            // 品牌金氛围光（主界面 look.background 的语言）：让卡片浮在光里而非纯黑上。
            RadialGradient(
                colors: [smart.a.opacity(0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 40, endRadius: 480
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

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
        // 顶部内高光：金调从上缘渐隐（设计稿卡面受光语言）。
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [smart.a.opacity(0.05), .clear],
                        startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)
                    )
                )
                .allowsHitTesting(false)
        )
        // 描边：顶部偏金、向下沉入常规 line 色的渐变 hairline。
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [smart.a.opacity(0.38), look.lineStrong, look.line],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        // 近似设计 0 40px 120px -30px rgba(0,0,0,.7)，外加一层贴身金晕。
        .shadow(color: smart.a.opacity(0.10), radius: 22, y: 4)
        .shadow(color: .black.opacity(0.7), radius: 60, y: 25)
    }

    /// 步骤区：只渲染当前步（高度随内容自适应），步间按 `store.advancing`
    /// 决定滑入/滑出边，还原设计稿的横向滑轨观感；reduceMotion 时交叉淡入。
    ///
    /// （曾经的 bug：三步平铺进 HStack 再整体 offset，但外层 frame 默认居中对齐，
    /// 可见窗口正对中间步——第 1 步显示成 FDA 步、第 3 步移出滑轨直接空白。）
    private var track: some View {
        ZStack {
            stepView(store.step)
                .frame(width: cardWidth)
                .id(store.step)
                .transition(stepTransition)
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.25)
                : .timingCurve(0.4, 0, 0.2, 1, duration: 0.45),
            value: store.step
        )
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: store.advancing ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: store.advancing ? .leading : .trailing).combined(with: .opacity)
        )
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    private let look = Look.ink
    private let smart = ModuleAccent.smart

    var body: some View {
        VStack(spacing: 0) {
            StepEyebrow(step: 1)

            // 品牌徽标：76×76 金渐变圆角方块 + 鼹鼠 logo，外围双装饰环
            // （实线 + 虚线缓旋，设计稿占位模块语言），整体轻浮动。
            ZStack {
                OrnamentRings()
                    .frame(width: 128, height: 128)
                MoleGlyph()
                    .fill(smart.onAccent, style: FillStyle(eoFill: true))
                    .frame(width: 40, height: 40)
                    .frame(width: 76, height: 76)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(smart.gradient)
                    )
                    .shadow(color: smart.a.opacity(0.6), radius: 25, y: 9)
            }
            .frame(height: 128)
            .offset(y: floating ? -3 : 3)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                    floating = true
                }
            }
            .padding(.top, 12)

            Text(L("onboarding.welcome.title"))
                .font(Fonts.serif(34))
                .foregroundStyle(look.text)
                .padding(.top, 18)
                .enterStagger(0)

            TitleHairline()
                .padding(.top, 12)
                .enterStagger(0)

            Text(L("onboarding.welcome.sub1") + "\n" + L("onboarding.welcome.sub2"))
                .font(Fonts.ui(13.5))
                .foregroundStyle(look.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .enterStagger(1)

            // 三张承诺卡（stagger 入场，hover 提亮）
            VStack(spacing: 10) {
                PromiseCard(
                    symbol: "eye",
                    title: L("onboarding.promise.preview.title"),
                    desc: L("onboarding.promise.preview.desc")
                )
                .enterStagger(2)
                PromiseCard(
                    symbol: "trash",
                    title: L("onboarding.promise.trash.title"),
                    desc: L("onboarding.promise.trash.desc")
                )
                .enterStagger(3)
                PromiseCard(
                    symbol: "clock.arrow.circlepath",
                    title: L("onboarding.promise.log.title"),
                    desc: L("onboarding.promise.log.desc")
                )
                .enterStagger(4)
            }
            .padding(.top, 24)

            OnboardingCTA(title: L("onboarding.start")) { store.start() }
                .padding(.top, 24)
                .enterStagger(5)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 34)
    }
}

/// 承诺卡：图标框 + 标题/说明两行；hover 时边框与底色轻提亮（设计稿卡片 hover 语言）。
private struct PromiseCard: View {
    let symbol: String
    let title: String
    let desc: String

    @State private var hovered = false
    private let look = Look.ink
    private let smart = ModuleAccent.smart

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(smart.a)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(smart.a.opacity(hovered ? 0.2 : 0.14)))
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
        .background(
            RoundedRectangle(cornerRadius: 13).fill(look.text.opacity(hovered ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13).stroke(hovered ? look.lineStrong : look.line, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - STEP 2 · 完全磁盘访问

private struct FullDiskAccessStep: View {
    @Environment(OnboardingStore.self) private var store
    private let look = Look.ink
    private let smart = ModuleAccent.smart

    var body: some View {
        VStack(spacing: 0) {
            StepEyebrow(step: 2)

            OnboardingIconBox(symbol: "internaldrive")
                .padding(.top, 12)

            Text(L("onboarding.fda.title"))
                .font(Fonts.serif(28))
                .foregroundStyle(look.text)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .enterStagger(0)

            TitleHairline()
                .padding(.top, 12)
                .enterStagger(0)

            // 正文含加重片段「不会上传任何数据」（look.text）。
            (Text(L("onboarding.fda.bodyPrefix"))
                + Text(L("onboarding.fda.bodyEmphasis")).foregroundColor(look.text)
                + Text(L("onboarding.fda.bodySuffix")))
                .font(Fonts.ui(13.5))
                .foregroundColor(look.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .enterStagger(1)

            // 三态区（idle / waiting / ok），minHeight 84 保证切换不跳动。
            // 动画上下文挂在切换容器外层：分支插入/移除才会执行 transition。
            phaseArea
                .frame(maxWidth: .infinity, minHeight: 84)
                .animation(.easeOut(duration: 0.3), value: store.fdaPhase)
                .padding(.top, 26)
                .enterStagger(2)

            // footer：返回 + 稍后再说（§5.8 三步均可跳过；跳过则功能降级并在权限页常驻提示）
            HStack(spacing: 18) {
                OnboardingFooterLink(title: L("onboarding.back")) { store.back() }
                OnboardingFooterLink(title: L("onboarding.fda.skip")) { store.skipFda() }
            }
            .padding(.top, 14)
            .enterStagger(3)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 34)
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
                // 自救出路：关掉系统设置窗口后可重新打开（requestFda 幂等，会重启轮询）。
                Button {
                    store.requestFda()
                } label: {
                    Text(L("onboarding.fda.reopen"))
                        .font(Fonts.ui(12, .semibold))
                        .foregroundStyle(ModuleAccent.smart.a)
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        case .granted:
            VStack(spacing: 14) {
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
                // 显式前进按钮：授权导致 App 重启后由恢复路径进入本态时，
                // 没有轮询自动推进，这是唯一的继续通路。
                OnboardingCTA(title: L("onboarding.fda.continue")) { store.continueAfterFda() }
            }
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
            StepEyebrow(step: 3)

            OnboardingIconBox(symbol: "checkmark.shield")
                .padding(.top, 12)

            Text(L("onboarding.helper.title"))
                .font(Fonts.serif(28))
                .foregroundStyle(look.text)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .enterStagger(0)

            TitleHairline()
                .padding(.top, 12)
                .enterStagger(0)

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
                .padding(.top, 12)
                .enterStagger(1)

            VStack(spacing: 10) {
                // 主按钮 v1 禁用：helper 组件（SMAppService）尚未落地。
                // TODO(helper): 组件落地后启用，点击调 store.finish(installHelper: true)。
                VStack(spacing: 6) {
                    OnboardingCTA(title: L("onboarding.helper.install"), disabled: true) {}
                    Text(L("onboarding.helper.comingSoon"))
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textMute)
                }
                .enterStagger(2)
                // 次按钮（幽灵款）：跳过 → 完成引导。
                OnboardingGhostButton(title: L("onboarding.helper.skip")) {
                    store.finish()
                }
                .enterStagger(3)
            }
            .padding(.top, 26)

            // footer：返回 FDA 步（跳过授权后想回头补授权的通路）。
            OnboardingFooterLink(title: L("onboarding.back")) { store.back() }
                .padding(.top, 14)
                .enterStagger(4)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 34)
    }
}

// MARK: - 共用组件

/// 步骤 eyebrow：小号大写字距序号（设计稿全局 eyebrow 语言）。纯技术标签不进 L10n。
private struct StepEyebrow: View {
    let step: Int

    var body: some View {
        Text(verbatim: String(format: "STEP %02d / 03", step))
            .font(.system(size: 10, weight: .semibold))
            .kerning(10 * 0.26)
            .foregroundStyle(Look.ink.textMute)
    }
}

/// 标题下的金渐变短分隔线（设计稿 section 标题语言）：两端渐隐的 2pt hairline。
private struct TitleHairline: View {
    private let smart = ModuleAccent.smart

    var body: some View {
        LinearGradient(
            colors: [.clear, smart.a.opacity(0.55), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: 46, height: 2)
        .clipShape(Capsule())
    }
}

/// 徽标装饰双环（设计稿占位模块语言）：外实线环 + 内虚线环 26s 缓旋。
/// reduceMotion 时静止。
private struct OrnamentRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    private let smart = ModuleAccent.smart

    var body: some View {
        ZStack {
            Circle()
                .stroke(Look.ink.lineStrong, lineWidth: 1)
            Circle()
                .stroke(
                    smart.a.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                )
                .padding(15)
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

/// 入场 stagger：淡入 + 上移 6pt，延迟按索引阶梯（智能页结论卡节奏）。
/// reduceMotion 时直接呈现。
private struct EnterStagger: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                guard !reduceMotion else {
                    shown = true
                    return
                }
                withAnimation(
                    .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.5)
                        .delay(0.08 + Double(index) * 0.07)
                ) {
                    shown = true
                }
            }
    }
}

private extension View {
    func enterStagger(_ index: Int) -> some View {
        modifier(EnterStagger(index: index))
    }
}

/// 主 CTA（三步共用）：全宽金渐变按钮 + 白 hairline 顶光（智能页 CTA 同款），hover 微增亮。
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
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

/// footer 文字链接（Step 2/3 返回、稍后再说共用样式）。
private struct OnboardingFooterLink: View {
    let title: String
    let action: () -> Void

    private let look = Look.ink

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
        }
        .buttonStyle(.plain)
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

/// Step 2/3 头部图标框：76×76 金调描边方块 + 38pt 线性 SF Symbol + 贴身金晕。
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
            .shadow(color: smart.a.opacity(0.22), radius: 20, y: 7)
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
