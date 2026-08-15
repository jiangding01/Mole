import SwiftUI

/// 线性光谱条（设计 r2 §P3）：光谱环刻度语汇的降维形态，用于**秒级**扫描
/// （软件页读取应用清单）。64 根 2px 刻度横向排开，高度 9↔30px 起伏、
/// 透明度 .24↔1，按 `(i%16)` 错峰延迟——同一种"仪器在采样"的语言，
/// 但没有起承转合，秒级出现/消失不尴尬。
///
/// 动画机制遵循设计红线"纯 CSS 不占 rAF"：`repeatForever` 一次性提交给
/// Core Animation（等价 CSS keyframes），**不用 TimelineView**（逐帧求值）。
struct LinearSpectrumBar: View {
    var accent: ModuleAccent
    var tickCount: Int = 64

    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<tickCount, id: \.self) { index in
                Capsule()
                    .fill(accent.a)
                    .frame(width: 2, height: animating ? 30 : 9)
                    .opacity(animating ? 1 : 0.24)
                    .animation(
                        .easeInOut(duration: 1.15 / 2) // CSS 45% 峰值 ≈ 半程往返
                            .repeatForever(autoreverses: true)
                            .delay(Double(index % 16) * 0.055 + Double(index / 16) * 0.02),
                        value: animating
                    )
            }
        }
        .frame(height: 30)
        .onAppear { animating = true }
    }
}
