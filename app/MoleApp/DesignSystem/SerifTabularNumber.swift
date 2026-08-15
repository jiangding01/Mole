import SwiftUI

/// Instrument Serif 定宽数字（设计 CHANGELOG-2026-08-15 §四的 SwiftUI 版 `setNum`）。
///
/// Instrument Serif 不含 `tnum` OpenType 特性，`monospacedDigit()` 在它上面
/// 静默失效（`1` = .249em、`0` = .46em），60fps 刷新的计数器会横向抖动。
/// 解法与设计稿一致：逐字符渲染为定宽 cell——数字 `.46em`、小数点 `.213em`、
/// 其余字符自然宽度，整组居中对齐后与单位的间距恒定、位数切换零漂移。
///
/// 只用于**高频跳动的英雄数字**（扫描计数器）；静态衬线数字直接用
/// `Fonts.serif` 即可，遥测类小读数按设计分层继续用 mono。
struct SerifTabularNumber: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .primary
    var kerningEm: CGFloat = 0

    var body: some View {
        HStack(spacing: kerningEm * size) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(Fonts.serif(size, weight))
                    .frame(width: cellWidth(ch))
            }
        }
        .foregroundStyle(color)
    }

    private func cellWidth(_ ch: Character) -> CGFloat? {
        if ch.isNumber { return size * 0.46 }
        if ch == "." { return size * 0.213 }
        return nil // 逗号/负号等按自然宽度
    }
}
