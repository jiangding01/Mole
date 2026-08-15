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

// MARK: - 全局快捷键行（设计 CHANGELOG §3.1）

/// 行本体（标题/副标/录制控件）+ 行下方可选状态线（录制提示 或 冲突警告）。
/// 与 SettingsRow 不同之处在于状态线需要跨越整行宽度，不能塞进 trailing。
struct HotkeyRow: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("settings.general.hotkey"))
                        .font(Fonts.ui(14, .semibold))
                        .foregroundStyle(look.text)
                    Text(L("settings.general.hotkey.desc"))
                        .font(Fonts.ui(12.5))
                        .foregroundStyle(look.textDim)
                }
                Spacer(minLength: 12)
                HotkeyRecorderControl(store: store, look: look, accent: accent)
                    .layoutPriority(1)
            }
            statusLine
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            Rectangle().fill(look.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if store.hotkeyRecording == .recording {
            HStack(spacing: 6) {
                PulseDot(color: accent.a)
                Text(L("settings.general.hotkey.recording.hint"))
                    .font(Fonts.ui(11.5))
                    .foregroundStyle(accent.a)
            }
        } else if let message = store.hotkeyConflictMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                Text(message)
                    .font(Fonts.ui(11.5))
            }
            .foregroundStyle(Semantic.warn)
        }
    }
}

/// 录制控件：未设置占位 / 已保存组合（mono 展示 + 清除按钮）/ 录制中输入框。
private struct HotkeyRecorderControl: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    var body: some View {
        HStack(spacing: 8) {
            box
            if store.currentHotkey != nil, store.hotkeyRecording == .idle {
                clearButton
            }
        }
    }

    @ViewBuilder
    private var box: some View {
        switch store.hotkeyRecording {
        case .recording:
            Text(L("settings.general.hotkey.recordingPlaceholder"))
                .font(Fonts.mono(12.5, .semibold))
                .foregroundStyle(accent.a)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(accent.a.opacity(0.1)))
                .overlay(Capsule().stroke(accent.a.opacity(0.5), lineWidth: 1))
        case .idle:
            if let combo = store.currentHotkey {
                Text(combo.displayString)
                    .font(Fonts.mono(12.5, .semibold))
                    .foregroundStyle(look.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(look.text.opacity(0.05)))
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture { store.startHotkeyRecording() }
                    .pointingCursor()
            } else {
                Text(L("settings.general.hotkey.unset"))
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textMute)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(look.text.opacity(0.03)))
                    .overlay(Capsule().strokeBorder(look.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .contentShape(Capsule())
                    .onTapGesture { store.startHotkeyRecording() }
                    .pointingCursor()
            }
        }
    }

    private var clearButton: some View {
        Button(action: { store.clearHotkey() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.textMute)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}

/// 录制态脉冲点：呼吸式扩散动画，提示「正在录制」。
private struct PulseDot: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 6, height: 6)
                .scaleEffect(animate ? 2.4 : 1)
                .opacity(animate ? 0 : 0.8)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

// MARK: - 诊断导出 toast（设计 CHANGELOG §3.2）

/// 窗口底部居中 toast：成功（绿）/ 失败（红），6 秒自动消失（成功态）或手动关闭。
/// 全局层，挂在 SettingsView 根容器 overlay(.bottom)，不嵌进滚动区。
struct DiagnosticsToast: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    var body: some View {
        Group {
            switch store.diagnosticsPhase {
            case .idle, .exporting:
                EmptyView()
            case let .succeeded(url):
                body(icon: "checkmark.circle.fill", tint: Semantic.success, message: L("settings.advanced.diagnostics.toast.success", url.path)) {
                    toastActionButton(L("settings.advanced.diagnostics.toast.showInFinder"), tint: accent.a) {
                        store.revealDiagnosticsExport()
                    }
                }
            case let .failed(reason):
                body(icon: "exclamationmark.triangle.fill", tint: Semantic.danger, message: L("settings.advanced.diagnostics.toast.failed", reason)) {
                    toastActionButton(L("settings.advanced.diagnostics.toast.retry"), tint: Semantic.danger) {
                        store.startDiagnosticsExport()
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.diagnosticsPhase)
    }

    private func body(icon: String, tint: Color, message: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.text)
                .lineLimit(2)
                .truncationMode(.middle)
            action()
            Button(action: { store.dismissDiagnosticsToast() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(look.textMute)
            }
            .buttonStyle(.plain)
            .pointingCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(look.surfaceSolid))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .frame(maxWidth: 520)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toastActionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}
