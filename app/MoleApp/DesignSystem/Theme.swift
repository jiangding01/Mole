import SwiftUI

/// 设计系统 token 骨架（设计 §8.2）。
/// 每个模块一个主题色相；页面背景带 <8% 透明度的主题色氛围渐变。
/// 具体色值以 Claude Design 交付的设计系统页为准，这里先放占位值。
enum Theme {
    // MARK: - 模块主题色（占位，待设计系统定稿替换）

    static let smartScanAccent = Color(hue: 0.11, saturation: 0.75, brightness: 0.85) // 品牌琥珀
    static let cleanAccent = Color(hue: 0.52, saturation: 0.60, brightness: 0.80) // 青蓝
    static let appsAccent = Color(hue: 0.75, saturation: 0.45, brightness: 0.80) // 紫
    static let optimizeAccent = Color(hue: 0.12, saturation: 0.65, brightness: 0.85) // 琥珀金
    static let analyzeAccent = Color(hue: 0.07, saturation: 0.55, brightness: 0.75) // 橙棕
    static let statusAccent = Color(hue: 0.38, saturation: 0.55, brightness: 0.75) // 健康绿

    // MARK: - 导航胶囊

    static let capsuleBackground = Color.white.opacity(0.06)
    static let capsuleSelected = Color.white
    static let capsuleSelectedText = Color.black
    static let capsuleText = Color.white.opacity(0.65)

    // MARK: - 页面背景

    static func accent(for tab: MainTab) -> Color {
        switch tab {
        case .smartScan: return smartScanAccent
        case .clean: return cleanAccent
        case .apps: return appsAccent
        case .optimize: return optimizeAccent
        case .analyze: return analyzeAccent
        case .status: return statusAccent
        }
    }

    /// 深色基底（极深冷灰蓝，非纯黑）+ 极淡主题色氛围渐变。
    static func background(for tab: MainTab) -> some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10)
            RadialGradient(
                colors: [accent(for: tab).opacity(0.08), .clear],
                center: .top, startRadius: 0, endRadius: 900
            )
        }
    }
}
