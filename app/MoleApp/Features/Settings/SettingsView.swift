import AppKit
import MoleKit
import SwiftUI

/// 设置页（设计 §5.7）：通用 / 清理白名单 / 权限中心 / 高级 / 关于。
/// 许可分区 v1 隐藏（许可证商业化开启后才出现）。
/// 注意清理白名单与优化白名单是两套独立配置（robot whitelist --mode）。
struct SettingsView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store = SettingsStore()

    private let look = Look.ink
    private let accent = ModuleAccent.settings

    /// 入场动画（设计 pageIn：opacity 0→1 + translateY 5→0，0.28s ease）。
    @State private var appeared = false

    var body: some View {
        ZStack {
            look.background(accent: accent)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(L("settings.title"))
                    .font(Fonts.serif(28))
                    .foregroundStyle(look.text)
                    .padding(.bottom, 18)

                HStack(alignment: .top, spacing: 22) {
                    navColumn
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 5)
        }
        // toast 是全局层：挂在根容器底部，不嵌进 content 的 ScrollView（设计 §3.2）。
        .overlay(alignment: .bottom) {
            DiagnosticsToast(store: store, look: look, accent: accent)
                .padding(.bottom, 20)
        }
        .frame(width: 860, height: 620)
        // 录制态中途关闭 sheet 必须摘掉 NSEvent 本地监听：monitor 是 app 级资源，
        // store 随 @State 销毁但监听器不会自动移除，反复进录制→关 sheet 会累积泄漏。
        .onDisappear { store.cancelHotkeyRecording() }
        .onAppear {
            store.refreshLaunchAtLoginStatus()
            // 菜单栏「运行诊断」一次性信号：直接跳到高级分区并开始导出。
            if DiagnosticsMenuBridge.pendingAutoExport {
                DiagnosticsMenuBridge.pendingAutoExport = false
                store.section = .advanced
                store.startDiagnosticsExport()
            }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) { appeared = true }
            }
        }
    }

    // MARK: - 左导航栏

    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsStore.Section.allCases) { section in
                NavItem(
                    look: look,
                    accent: accent,
                    label: navLabel(section),
                    selected: store.section == section,
                    action: { store.section = section }
                )
            }
        }
        .frame(width: 176, alignment: .top)
    }

    private func navLabel(_ section: SettingsStore.Section) -> String {
        switch section {
        case .general: L("settings.nav.general")
        case .whitelist: L("settings.nav.whitelist")
        case .permissions: L("settings.nav.permissions")
        case .advanced: L("settings.nav.advanced")
        case .about: L("settings.nav.about")
        }
    }

    // MARK: - 右内容区

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch store.section {
                case .general: generalSection
                case .whitelist: WhitelistSection(store: store, look: look, accent: accent)
                case .permissions: PermissionsSection(store: store, look: look, accent: accent)
                case .advanced: AdvancedSection(store: store, look: look, accent: accent)
                case .about: aboutSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.automatic)
    }

    // MARK: - 通用分区

    private var generalSection: some View {
        VStack(spacing: 0) {
            SettingsRow(look: look, title: L("settings.general.language"), subtitle: L("settings.general.language.desc")) {
                SegmentedControl(
                    look: look, accent: accent,
                    options: [
                        SegmentedOption(id: L10n.Language.system.rawValue, label: L("settings.lang.auto")),
                        SegmentedOption(id: L10n.Language.zhHans.rawValue, label: L("settings.lang.zh")),
                        SegmentedOption(id: L10n.Language.english.rawValue, label: L("settings.lang.en")),
                    ],
                    selectedID: store.language.rawValue,
                    onSelect: { id in if let lang = L10n.Language(rawValue: id) { store.language = lang } }
                )
            }
            SettingsRow(look: look, title: L("settings.general.appearance"), subtitle: L("settings.general.appearance.desc")) {
                SegmentedControl(
                    look: look, accent: accent,
                    options: [
                        SegmentedOption(id: "follow", label: L("settings.appearance.follow"), disabled: true),
                        SegmentedOption(id: "light", label: L("settings.appearance.light"), disabled: true),
                        SegmentedOption(id: "dark", label: L("settings.appearance.dark")),
                    ],
                    selectedID: "dark",
                    onSelect: { _ in }
                )
            }
            SettingsRow(look: look, title: L("settings.general.temperature"), subtitle: L("settings.general.temperature.desc")) {
                SegmentedControl(
                    look: look, accent: accent,
                    options: [
                        SegmentedOption(id: "auto", label: L("settings.temp.auto")),
                        SegmentedOption(id: "celsius", label: "°C"),
                        SegmentedOption(id: "fahrenheit", label: "°F"),
                    ],
                    selectedID: store.temperatureUnit.rawValue,
                    onSelect: { id in if let u = SettingsStore.TemperatureUnit(rawValue: id) { store.temperatureUnit = u } }
                )
            }
            SettingsRow(look: look, title: L("settings.general.refresh"), subtitle: L("settings.general.refresh.desc")) {
                SegmentedControl(
                    look: look, accent: accent,
                    options: [
                        SegmentedOption(id: "1", label: "1s", mono: true),
                        SegmentedOption(id: "2", label: "2s", mono: true),
                        SegmentedOption(id: "5", label: "5s", mono: true),
                    ],
                    selectedID: String(store.refreshInterval.rawValue),
                    onSelect: { id in if let n = Int(id), let v = SettingsStore.RefreshInterval(rawValue: n) { store.refreshInterval = v } }
                )
            }
            SettingsRow(look: look, title: L("settings.general.cacheDelete"), subtitle: L("settings.general.cacheDelete.desc")) {
                SegmentedControl(
                    look: look, accent: accent,
                    options: [
                        SegmentedOption(id: "trash", label: L("settings.cache.trash")),
                        SegmentedOption(id: "permanent", label: L("settings.cache.permanent"), disabled: true),
                    ],
                    selectedID: "trash",
                    onSelect: { _ in }
                )
            }
            SettingsRow(look: look, title: L("settings.general.launchAtLogin"), subtitle: L("settings.general.launchAtLogin.desc")) {
                MoleToggle(look: look, accent: accent, isOn: store.launchAtLogin) {
                    store.setLaunchAtLogin(!store.launchAtLogin)
                }
                .help(store.launchAtLoginError ?? "")
            }
            SettingsRow(look: look, title: L("settings.general.skipIntro"), subtitle: L("settings.general.skipIntro.desc")) {
                MoleToggle(look: look, accent: accent, isOn: store.skipIntro) {
                    store.skipIntro.toggle()
                }
            }
            HotkeyRow(store: store, look: look, accent: accent)
            SettingsRow(
                look: look,
                title: L("settings.general.reduceMotion"),
                subtitle: L("settings.general.reduceMotion.desc"),
                showsDivider: false
            ) {
                MoleToggle(look: look, accent: accent, isOn: store.reduceMotion) {
                    store.reduceMotion.toggle()
                }
            }
        }
    }

    // MARK: - 关于分区

    private var aboutSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 19)
                    .fill(accent.gradient)
                    .frame(width: 66, height: 66)
                    .overlay(
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(accent.onAccent)
                    )
                    .shadow(color: accent.a.opacity(0.35), radius: 14, y: 8)
                Text(verbatim: "Mole")
                    .font(Fonts.serif(26))
                    .foregroundStyle(look.text)
                    .padding(.top, 14)
                Text(L("settings.about.version", store.appShortVersion, store.appBuild))
                    .font(Fonts.mono(12))
                    .foregroundStyle(look.textMute)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 26)

            aboutRow(label: L("settings.about.core"), divider: true) {
                Text(verbatim: coreVersionValue)
                    .font(Fonts.mono(12.5))
                    .foregroundStyle(look.text)
            }
            aboutRow(label: L("settings.about.license"), divider: true) {
                aboutLink(L("settings.about.license.action")) {
                    open("https://github.com/tw93/Mole/blob/main/LICENSE")
                }
            }
            aboutRow(label: L("settings.about.update"), divider: true) {
                aboutLink(L("settings.about.update.action")) {
                    open("https://github.com/tw93/Mole/releases")
                }
            }
            aboutRow(label: L("settings.about.onboarding"), divider: true) {
                aboutLink(L("settings.about.onboarding.action")) {
                    onboarding.reopen()
                    dismiss()
                }
            }

            Text(L("settings.about.footer"))
                .font(Fonts.ui(11.5))
                .foregroundStyle(look.textMute)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        }
    }

    private var coreVersionValue: String {
        if let v = store.coreVersion() { return "mole-core \(v)" }
        return "—"
    }

    private func aboutRow(label: String, divider: Bool, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 20) {
            Text(label)
                .font(Fonts.ui(13.5))
                .foregroundStyle(look.textDim)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(look.line).frame(height: 1) }
        }
    }

    private func aboutLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(accent.a)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 导航项

private struct NavItem: View {
    let look: Look
    let accent: ModuleAccent
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? accent.a : .clear)
                    .frame(width: 3, height: 15)
                Text(label)
                    .font(Fonts.ui(13.5, .semibold))
                    .foregroundStyle(selected ? look.text : look.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(look.text.opacity(selected ? 0.06 : (hover ? 0.04 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pointingCursor()
    }
}
