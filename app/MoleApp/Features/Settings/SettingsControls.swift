import SwiftUI

// 设置页复用控件（设计 §5.7）：分段控件 / 开关 / 行 / 胶囊按钮。
// 样式为设计稿精确值；改动须回到设计稿对齐。

// MARK: - 分段控件

struct SegmentedOption: Identifiable {
    let id: String
    let label: String
    var mono = false
    var disabled = false
}

/// 胶囊分段控件：容器 padding 3 / radius 999 / bg text .05 / 1px line 边框；
/// 选项 padding 6×14(mono 6×15) / radius 999 / 12.5 semibold；
/// 选中 = onAccent 文字 + accent 底，未选 = textDim 透明；禁用 opacity 0.4 不可点。
struct SegmentedControl: View {
    let look: Look
    let accent: ModuleAccent
    let options: [SegmentedOption]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(look.text.opacity(0.05)))
        .overlay(Capsule().stroke(look.line, lineWidth: 1))
    }

    @ViewBuilder
    private func segment(_ option: SegmentedOption) -> some View {
        let selected = option.id == selectedID
        let base = Text(option.label)
            .font(option.mono ? Fonts.mono(12, .semibold) : Fonts.ui(12.5, .semibold))
            .foregroundStyle(selected ? accent.onAccent : look.textDim)
            .padding(.horizontal, option.mono ? 15 : 14)
            .padding(.vertical, 6)
            .background {
                if selected { Capsule().fill(accent.a) }
            }
            .contentShape(Capsule())
            .opacity(option.disabled ? 0.4 : 1)

        if option.disabled {
            base
        } else {
            base
                .onTapGesture { onSelect(option.id) }
                .pointingCursor()
        }
    }
}

// MARK: - 开关

/// 轨道 40×23 radius 999（开 accent / 关 text .16）；旋钮 19×19 白色 + 阴影；
/// 开 x18 / 关 x2；easeOut 0.18。禁用不响应点击。
struct MoleToggle: View {
    let look: Look
    let accent: ModuleAccent
    let isOn: Bool
    var disabled = false
    let onToggle: () -> Void

    var body: some View {
        Capsule()
            .fill(isOn ? accent.a : look.text.opacity(0.16))
            .frame(width: 40, height: 23)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .offset(x: isOn ? 18 : 2)
            }
            .animation(.easeOut(duration: 0.18), value: isOn)
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
            .onTapGesture { if !disabled { onToggle() } }
            .pointingCursor()
    }
}

// MARK: - 设置行（标题 + 副标 + 尾部控件）

/// 行 padding 15 纵向、两端对齐、gap 20；标题 14 semibold、副标 12.5 textDim 上距 3；
/// 行尾 1px look.line 分隔线（末行传 showsDivider=false）。
struct SettingsRow<Trailing: View>: View {
    let look: Look
    let title: String
    let subtitle: String
    var titleColor: Color?
    var showsDivider = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Fonts.ui(14, .semibold))
                    .foregroundStyle(titleColor ?? look.text)
                Text(subtitle)
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
                .layoutPriority(1)
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(look.line).frame(height: 1)
            }
        }
    }
}

// MARK: - 胶囊按钮

enum PillButtonStyle {
    case outline // 描边：textDim + lineStrong 边框，hover→text
    case danger // 红描边：#E0745C 文字 + .35 边框，hover 底 .1
    case filledAccent // 实心 CTA：onAccent 文字 + accent 底
}

/// 通用胶囊按钮。禁用时 opacity 0.45、不可点、显示 help（如「即将推出」）。
struct PillButton: View {
    let look: Look
    let accent: ModuleAccent
    let title: String
    var style: PillButtonStyle = .outline
    var disabled = false
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 7
    var help: String?
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(background)
                .overlay(border)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hover = $0 && !disabled }
        .modifier(ConditionalPointer(enabled: !disabled))
        .help(help ?? "")
    }

    private var foreground: Color {
        switch style {
        case .outline: hover ? look.text : look.textDim
        case .danger: Semantic.danger
        case .filledAccent: accent.onAccent
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .outline:
            Color.clear
        case .danger:
            Capsule().fill(Semantic.danger.opacity(hover ? 0.1 : 0))
        case .filledAccent:
            Capsule().fill(accent.a)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .outline:
            Capsule().stroke(look.lineStrong, lineWidth: 1)
        case .danger:
            Capsule().stroke(Semantic.danger.opacity(0.35), lineWidth: 1)
        case .filledAccent:
            EmptyView()
        }
    }
}

/// 仅在启用时挂 pointingCursor（禁用按钮不显示小手）。
private struct ConditionalPointer: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.pointingCursor() } else { content }
    }
}
