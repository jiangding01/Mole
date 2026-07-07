import SwiftUI

// 设计 token —— 来源：design/mole-dc/Mole.dc.html（Claude Design 定稿）。
// 双轴主题：全局 Look（Ink 暖黑 / Onyx 冷黑 / Paper 浅色）× 每模块 Accent。
// 色值为设计稿精确值，不得随手调整；改动须回到设计稿对齐。

// MARK: - Look（外观基调）

enum Look: String, CaseIterable {
    case ink // 默认：暖近黑
    case onyx // 冷黑
    case paper // 浅色

    var text: Color {
        switch self {
        case .ink: return Color(hex: 0xF3ECE0)
        case .onyx: return Color(hex: 0xEEF1F6)
        case .paper: return Color(hex: 0x2C2216)
        }
    }

    var textDim: Color { text.opacity(0.6) }
    var textMute: Color { self == .paper ? text.opacity(0.44) : text.opacity(0.4) }

    var line: Color { self == .paper ? Color(hex: 0x3A2C1A).opacity(0.11) : text.opacity(0.09) }
    var lineStrong: Color { self == .paper ? Color(hex: 0x3A2C1A).opacity(0.20) : text.opacity(0.17) }

    var surfaceSolid: Color {
        switch self {
        case .ink: return Color(hex: 0x181410)
        case .onyx: return Color(hex: 0x12151B)
        case .paper: return Color(hex: 0xFCFAF5)
        }
    }

    /// 导航胶囊底色（设计 --chrome）。
    var chrome: Color {
        switch self {
        case .ink: return Color(red: 20 / 255, green: 17 / 255, blue: 13 / 255).opacity(0.55)
        case .onyx: return Color(red: 16 / 255, green: 19 / 255, blue: 24 / 255).opacity(0.55)
        case .paper: return Color.white.opacity(0.78)
        }
    }

    /// 刻度环基色（设计 --tick rgb）。
    var tick: Color {
        switch self {
        case .ink: return Color(hex: 0xF3ECE0)
        case .onyx: return Color(hex: 0xE2E8F2)
        case .paper: return Color(hex: 0x786242)
        }
    }

    /// 页面背景（设计 --bg 径向渐变的近似：顶部微亮 → 底部沉底）。
    @ViewBuilder
    func background(accent: ModuleAccent) -> some View {
        ZStack {
            switch self {
            case .ink:
                RadialGradient(
                    colors: [Color(hex: 0x191510), Color(hex: 0x100D0A), Color(hex: 0x0A0807)],
                    center: UnitPoint(x: 0.5, y: -0.12), startRadius: 0, endRadius: 1100
                )
            case .onyx:
                RadialGradient(
                    colors: [Color(hex: 0x14171C), Color(hex: 0x0C0E12), Color(hex: 0x08090C)],
                    center: UnitPoint(x: 0.5, y: -0.12), startRadius: 0, endRadius: 1100
                )
            case .paper:
                RadialGradient(
                    colors: [Color(hex: 0xFCF9F3), Color(hex: 0xF4EDE1), Color(hex: 0xEBE1D0)],
                    center: UnitPoint(x: 0.5, y: -0.12), startRadius: 0, endRadius: 1100
                )
            }
            // 环境 accent 氛围光（设计：radial 78%×62% at 50% 4%, alpha .09）
            RadialGradient(
                colors: [accent.a.opacity(0.09), .clear],
                center: UnitPoint(x: 0.5, y: 0.04), startRadius: 0, endRadius: 700
            )
        }
    }
}

// MARK: - 模块 Accent（每页一套，含高亮 CTA 双色渐变与 on-accent 文字色）

enum ModuleAccent: String, CaseIterable {
    case smart, clean, apps, optimize, analyze, status, history, settings

    /// 主 accent（设计 THEMES.a）
    var a: Color {
        switch self {
        case .smart: return Color(hex: 0xD3A24A)
        case .clean: return Color(hex: 0x3C93B0)
        case .apps: return Color(hex: 0x8E72CE)
        case .optimize: return Color(hex: 0xB0702E)
        case .analyze: return Color(hex: 0xC86B49)
        case .status: return Color(hex: 0x4CA07C)
        case .history: return Color(hex: 0xB0A798)
        case .settings: return Color(hex: 0xA8A79E)
        }
    }

    /// 亮 accent（设计 THEMES.b，渐变上端）
    var b: Color {
        switch self {
        case .smart: return Color(hex: 0xE6C078)
        case .clean: return Color(hex: 0x5AB4CE)
        case .apps: return Color(hex: 0xA88BE6)
        case .optimize: return Color(hex: 0xCE8C44)
        case .analyze: return Color(hex: 0xDD8464)
        case .status: return Color(hex: 0x63BB95)
        case .history: return Color(hex: 0xC9C0B0)
        case .settings: return Color(hex: 0xC4C2B8)
        }
    }

    /// accent 面上的文字色（设计 THEMES.ink）
    var onAccent: Color {
        switch self {
        case .smart: return Color(hex: 0x241703)
        case .clean: return Color(hex: 0x03212B)
        case .apps: return Color(hex: 0xFBF7F0)
        case .optimize: return Color(hex: 0x231402)
        case .analyze: return Color(hex: 0xFBF7F0)
        case .status: return Color(hex: 0x04241A)
        case .history: return Color(hex: 0x221C14)
        case .settings: return Color(hex: 0x221C14)
        }
    }

    /// CTA/高亮渐变（设计：linear 180deg, b → a）
    var gradient: LinearGradient {
        LinearGradient(colors: [b, a], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 语义色（跨模块固定，不随 accent）

enum Semantic {
    static let success = Color(hex: 0x5FBFA0)
    static let successAlt = Color(hex: 0x63BB95)
    static let warn = Color(hex: 0xE3B34E) // FDA 点、"需确认/需复核"
    static let warnAlt = Color(hex: 0xD89A54)
    static let danger = Color(hex: 0xE0745C)
    static let dangerFill = Color(hex: 0xC8583E)
    static let insight = Color(hex: 0x9DB0C6)

    /// 健康分插值（设计：green→amber→red，拐点 70/30）
    static func health(_ score: Double) -> Color {
        func lerp(_ x: (Double, Double, Double), _ y: (Double, Double, Double), _ t: Double) -> Color {
            Color(red: (x.0 + (y.0 - x.0) * t) / 255,
                  green: (x.1 + (y.1 - x.1) * t) / 255,
                  blue: (x.2 + (y.2 - x.2) * t) / 255)
        }
        let green = (99.0, 187.0, 149.0), amber = (216.0, 154.0, 84.0), red = (224.0, 116.0, 92.0)
        if score >= 70 { return lerp(amber, green, min(1, (score - 70) / 30)) }
        if score >= 30 { return lerp(red, amber, (score - 30) / 40) }
        return lerp(red, red, 0)
    }
}

/// Treemap 暖色阶（设计 TM_PALETTE）+ 聚合块色。
enum TreemapPalette {
    static let ramp: [Color] = [
        Color(hex: 0xC7AC72), Color(hex: 0xC89A54), Color(hex: 0xC68348), Color(hex: 0xB96A3E),
        Color(hex: 0xA75838), Color(hex: 0x8C6B4E), Color(hex: 0x7A5E48), Color(hex: 0x6B5540),
    ]
    static let aggregate = Color(hex: 0x4E463C)
}

// MARK: - 字体（HANDOFF §2 三分工）
// 英雄数字 → Instrument Serif；路径/单位/索引/英文微标签 → JetBrains Mono；
// 中文标题正文 → 思源黑/宋。均非 macOS 内置，v1 系统近似：
// serif→New York、mono→SF Mono、ui→系统默认（中文即苹方，正是设计 fallback 链）。
// 是否打包 OFL 字体在 Phase 4 决定。

enum Fonts {
    /// 技术信息：路径、大小、PID、英文微标签（tabular 数字）。
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// 英雄数字与大标题（"体检完成"、Freed GB、健康分）。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// 中文标题与正文（系统默认 → 苹方）。
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 字距拉开的全大写小标签（设计 eyebrow：9–11px, .16–.28em, uppercase）。
    static func eyebrow(_ text: String, size: CGFloat = 10) -> some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .kerning(size * 0.2)
    }
}

// MARK: - 尺寸 token

enum Metrics {
    /// 卡片统一圆角（HANDOFF §2）。
    static let cardRadius: CGFloat = 15
    static let pillRadius: CGFloat = 999
    static let modalRadius: CGFloat = 20
    /// 页面栅格：结果/状态卡 4 列 gap 12；内容最大宽度。
    static let gridGap: CGFloat = 12
    static let contentMaxWidth: CGFloat = 900
}

// MARK: - 主题环境

/// 当前主题（Look + 页面 Accent），经 Environment 注入全树。
struct MoleTheme {
    var look: Look = .ink
    var accent: ModuleAccent = .smart
}

extension EnvironmentValues {
    @Entry var moleTheme = MoleTheme()
}

// MARK: - Color(hex:)

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 兼容旧骨架的过渡 API（RootView 迁移后删除）

enum Theme {
    static let capsuleBackground = Look.ink.chrome
    static let capsuleSelected = Color.white
    static let capsuleSelectedText = Color.black
    static let capsuleText = Look.ink.textDim

    static func accent(for tab: MainTab) -> Color { moduleAccent(for: tab).a }

    static func moduleAccent(for tab: MainTab) -> ModuleAccent {
        switch tab {
        case .smartScan: return .smart
        case .clean: return .clean
        case .apps: return .apps
        case .optimize: return .optimize
        case .analyze: return .analyze
        case .status: return .status
        }
    }

    @ViewBuilder
    static func background(for tab: MainTab) -> some View {
        Look.ink.background(accent: moduleAccent(for: tab))
    }
}
