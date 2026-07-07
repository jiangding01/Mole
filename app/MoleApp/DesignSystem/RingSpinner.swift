import SwiftUI

/// 设计感加载指示器（设计稿的 ringSpin CSS spinner：细弧 1s 匀速旋转）。
/// 用于状态页读取指标、分析下钻等轻量等待场景——注意与光谱环区分：
/// 这是小型 loading，光谱环（SpectrumRingView）是页面级焦点视觉。
struct RingSpinner: View {
    var accent: ModuleAccent
    var size: CGFloat = 28
    var lineWidth: CGFloat = 2.5

    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(
                AngularGradient(colors: [accent.b, accent.a.opacity(0.15)],
                                center: .center),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

#Preview {
    RingSpinner(accent: .status)
        .padding(40)
        .background(Color(hex: 0x0B0908))
}
