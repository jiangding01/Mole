import SwiftUI

// 光谱环（Focus Ring）—— 核心动效资产。
// 规格来源：design/mole-dc/Mole.dc.html 逻辑类 initOrb()/loop()（HANDOFF §4）
// 与 docs/UI_DESIGN_PROMPT.md §4.1 状态机。
// 设计参数：canvas 340×340、半径 116、刻度 144（72–240）、每 N/12 一根主刻度；
// 扫描头高斯脉冲 σ=0.19；甜甜圈 lineWidth 10、段间隙 0.08rad、750ms 缓入；
// 优化分段 lineWidth 11、间隙 0.14rad。

/// 环的形态状态（驱动数据由页面 Store 提供，本视图纯渲染）。
enum RingState: Equatable {
    /// 静息：刻度呼吸。
    case idle
    /// 扫描中：扫描头角度 0…1 循环（真实扫描总量未知，由外部按时间/进度驱动）。
    case scanning(head: Double)
    /// 结果：甜甜圈占比（各段 0…1 比例 + 颜色），reveal 0…1 为 750ms 缓入进度。
    case results(segments: [RingSegment], reveal: Double)
    /// 执行：甜甜圈随进度放空（progress 0…1）。
    case executing(segments: [RingSegment], progress: Double)
    /// 优化：N 段逐段点亮。
    case tending(done: Int, total: Int)
}

struct RingSegment: Equatable {
    var fraction: Double
    var color: Color
}

struct SpectrumRingView: View {
    var state: RingState
    var accent: ModuleAccent
    var look: Look = .ink
    var tickCount: Int = 144

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // HANDOFF §4：Reduce Motion 停用环动效，静态刻度。
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, time: 0, motion: false)
            }
            .frame(width: 340, height: 340)
        } else {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    draw(ctx: &ctx, size: size, time: t, motion: true)
                }
            }
            .frame(width: 340, height: 340)
        }
    }

    // MARK: - 绘制

    private func draw(ctx: inout GraphicsContext, size: CGSize, time: TimeInterval, motion: Bool) {
        // 设计稿 canvas 用 composite 'lighter' 做加性发光（暗色 Look），
        // 否则低 alpha 刻度在深底上偏暗看不清。
        if look != .paper {
            ctx.blendMode = .plusLighter
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 116
        let n = max(72, min(240, tickCount))
        let major = max(1, Int((Double(n) / 12).rounded()))

        // 基线双圈（alpha .06）
        for r in [radius, radius - 30] {
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ctx.stroke(circle, with: .color(look.tick.opacity(0.06)), lineWidth: 1)
        }

        switch state {
        case .idle:
            drawTicks(ctx: &ctx, center: center, radius: radius, n: n, major: major) { i, isMajor in
                let breathe = motion ? 5 * sin(time * 1.25 + Double(i) * 0.42) : 0
                let len = (isMajor ? 16.0 : 8.0) + breathe
                let alpha = isMajor ? 0.62 : 0.42
                return (len, look.tick.opacity(alpha))
            }

        case let .scanning(head):
            let headAngle = -Double.pi / 2 + head * 2 * .pi
            // 刻度均衡器：扫描头附近高斯脉冲
            drawTicks(ctx: &ctx, center: center, radius: radius, n: n, major: major) { i, isMajor in
                let angle = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
                var d = abs(angle - headAngle).truncatingRemainder(dividingBy: 2 * .pi)
                if d > .pi { d = 2 * .pi - d }
                let bump = exp(-(d * d) / (2 * 0.19 * 0.19))
                let shimmer = motion ? 4 * sin(time * 2.1 + Double(i)) : 0
                let len = (isMajor ? 16.0 : 8.0) + 26 * bump + shimmer
                let alpha = (isMajor ? 0.62 : 0.42) + 0.55 * bump
                return (len, look.tick.opacity(min(1, alpha)))
            }
            // 双色进度弧（-π/2 → head，0.07rad 分段做 A→B 色插值）
            drawLerpedArc(ctx: &ctx, center: center, radius: radius,
                          from: -Double.pi / 2, to: headAngle, lineWidth: 2.5)
            // 白热扫描头
            drawHeadSprite(ctx: &ctx, center: center, radius: radius, angle: headAngle)

        case let .results(segments, reveal):
            let eased = 1 - pow(1 - min(1, max(0, reveal)), 3)
            drawTicks(ctx: &ctx, center: center, radius: radius, n: n, major: major) { _, isMajor in
                ((isMajor ? 9.0 : 4.0), look.tick.opacity(isMajor ? 0.4 : 0.22))
            }
            drawDonut(ctx: &ctx, center: center, radius: radius, segments: segments, fill: eased)

        case let .executing(segments, progress):
            let fade = 1 - min(1, max(0, progress))
            drawTicks(ctx: &ctx, center: center, radius: radius, n: n, major: major) { _, isMajor in
                ((isMajor ? 9.0 : 4.0), look.tick.opacity((isMajor ? 0.4 : 0.22) * (0.5 + fade * 0.5)))
            }
            drawDonut(ctx: &ctx, center: center, radius: radius, segments: segments, fill: fade)

        case let .tending(done, total):
            drawTicks(ctx: &ctx, center: center, radius: radius, n: n, major: major) { _, isMajor in
                ((isMajor ? 9.0 : 4.0), look.tick.opacity(isMajor ? 0.4 : 0.22))
            }
            drawTendingSegments(ctx: &ctx, center: center, radius: radius, done: done, total: max(1, total))
        }
    }

    private func drawTicks(
        ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, n: Int, major: Int,
        style: (Int, Bool) -> (Double, Color)
    ) {
        for i in 0 ..< n {
            let isMajor = i % major == 0
            let (len, color) = style(i, isMajor)
            let angle = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
            let outer = point(center, radius, angle)
            let inner = point(center, radius - CGFloat(len), angle)
            var path = Path()
            path.move(to: outer)
            path.addLine(to: inner)
            ctx.stroke(path, with: .color(color), lineWidth: isMajor ? 2.6 : 1.8)
        }
    }

    private func drawLerpedArc(
        ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat,
        from: Double, to: Double, lineWidth: CGFloat
    ) {
        guard to > from else { return }
        var a = from
        while a < to {
            let b = min(a + 0.07, to)
            let t = (cos(a) + 1) / 2 // 设计的 A↔B 插值因子
            var seg = Path()
            seg.addArc(center: center, radius: radius,
                       startAngle: .radians(a), endAngle: .radians(b), clockwise: false)
            ctx.stroke(seg, with: .color(lerp(accent.a, accent.b, t)), lineWidth: lineWidth)
            a = b
        }
    }

    private func drawDonut(
        ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat,
        segments: [RingSegment], fill: Double
    ) {
        let gap = 0.08
        let total = segments.reduce(0) { $0 + $1.fraction }
        guard total > 0, fill > 0 else { return }
        var start = -Double.pi / 2
        for seg in segments {
            let sweep = (seg.fraction / total) * (2 * .pi - gap * Double(segments.count)) * fill
            var path = Path()
            path.addArc(center: center, radius: radius,
                        startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
            ctx.stroke(path, with: .color(seg.color), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            start += sweep + gap
        }
    }

    private func drawTendingSegments(
        ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, done: Int, total: Int
    ) {
        let gap = 0.14
        let sweep = (2 * .pi - gap * Double(total)) / Double(total)
        var start = -Double.pi / 2
        for i in 0 ..< total {
            var path = Path()
            path.addArc(center: center, radius: radius,
                        startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
            if i < done {
                let t = Double(i) / Double(max(1, total - 1))
                ctx.stroke(path, with: .color(lerp(accent.a, accent.b, t)),
                           style: StrokeStyle(lineWidth: 11, lineCap: .round))
                if i == done - 1 {
                    drawHeadSprite(ctx: &ctx, center: center, radius: radius, angle: start + sweep)
                }
            } else {
                ctx.stroke(path, with: .color(look.tick.opacity(0.1)), lineWidth: 11)
            }
            start += sweep + gap
        }
    }

    private func drawHeadSprite(ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, angle: Double) {
        let p = point(center, radius, angle)
        let glow = Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        ctx.fill(glow, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.9), accent.b.opacity(0.5), .clear]),
            center: p, startRadius: 0, endRadius: 11
        ))
        let dot = Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4))
        ctx.fill(dot, with: .color(.white))
    }

    // MARK: - 工具

    private func point(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
    }

    private func lerp(_ x: Color, _ y: Color, _ t: Double) -> Color {
        let cx = NSColor(x).usingColorSpace(.sRGB) ?? .white
        let cy = NSColor(y).usingColorSpace(.sRGB) ?? .white
        return Color(
            red: Double(cx.redComponent) + (Double(cy.redComponent) - Double(cx.redComponent)) * t,
            green: Double(cx.greenComponent) + (Double(cy.greenComponent) - Double(cx.greenComponent)) * t,
            blue: Double(cx.blueComponent) + (Double(cy.blueComponent) - Double(cx.blueComponent)) * t
        )
    }
}

#Preview("idle") {
    SpectrumRingView(state: .idle, accent: .smart)
        .background(Color(hex: 0x0B0908))
}

#Preview("scanning") {
    SpectrumRingView(state: .scanning(head: 0.6), accent: .clean)
        .background(Color(hex: 0x0B0908))
}

#Preview("results") {
    SpectrumRingView(
        state: .results(segments: [
            RingSegment(fraction: 8.92, color: Color(hex: 0x46A588)),
            RingSegment(fraction: 1.4, color: Color(hex: 0x8E72CE)),
            RingSegment(fraction: 3.1, color: Color(hex: 0xC0803A)),
        ], reveal: 1),
        accent: .smart
    )
    .background(Color(hex: 0x0B0908))
}
