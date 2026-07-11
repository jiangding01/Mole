import AppKit
import MoleKit
import SwiftUI

// 设置页分区：白名单 / 权限中心 / 高级（设计 §5.7）。

// MARK: - 白名单分区

struct WhitelistSection: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoBar
            modeSegment
            body(for: store.whitelistPhase)
        }
        .onAppear { store.loadWhitelistIfNeeded() }
    }

    /// 说明条
    private var infoBar: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "shield")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(accent.a)
            Text(L("settings.whitelist.info"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(accent.a.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(accent.a.opacity(0.14), lineWidth: 1))
        .padding(.bottom, 14)
    }

    /// 模式切换（两套独立配置）
    private var modeSegment: some View {
        SegmentedControl(
            look: look, accent: accent,
            options: [
                SegmentedOption(id: WhitelistMode.clean.rawValue, label: L("settings.whitelist.mode.clean")),
                SegmentedOption(id: WhitelistMode.optimize.rawValue, label: L("settings.whitelist.mode.optimize")),
            ],
            selectedID: store.whitelistMode.rawValue,
            onSelect: { id in if let m = WhitelistMode(rawValue: id) { store.selectMode(m) } }
        )
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func body(for phase: SettingsStore.WhitelistPhase) -> some View {
        if !store.entries.isEmpty {
            list
            addButton
        } else {
            switch phase {
            case .idle, .loading:
                loadingState
            case .loaded:
                emptyState
                addButton
            case let .failed(message):
                failedState(message)
                addButton
            }
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(store.entries) { entry in
                WhitelistRow(
                    look: look,
                    entry: entry,
                    disabled: store.pendingRemove.contains(entry.id),
                    onRemove: { store.removePattern(entry) }
                )
            }
        }
    }

    private var addButton: some View {
        Button {
            pickDirectory()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("settings.whitelist.add"))
                    .font(Fonts.ui(13, .semibold))
            }
            .foregroundStyle(look.textDim)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(look.text.opacity(0.03)))
            .overlay(
                Capsule().strokeBorder(look.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isAdding)
        .opacity(store.isAdding ? 0.5 : 1)
        .pointingCursor()
        .padding(.top, 14)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("settings.whitelist.loading"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var emptyState: some View {
        Text(L("settings.whitelist.empty"))
            .font(Fonts.ui(12.5))
            .foregroundStyle(look.textMute)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(L("settings.whitelist.failed"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
            Button {
                store.reloadWhitelist()
            } label: {
                Text(L("settings.whitelist.retry"))
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(accent.a)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .help(message)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("settings.whitelist.add.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let abbreviated = (url.path as NSString).abbreviatingWithTildeInPath
        store.addPattern(abbreviated)
    }
}

/// 白名单行
private struct WhitelistRow: View {
    let look: Look
    let entry: WhitelistEntry
    let disabled: Bool
    let onRemove: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(look.textMute)
            Text(verbatim: entry.pattern)
                .font(Fonts.mono(12.5))
                .foregroundStyle(look.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            removeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 11).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(look.line, lineWidth: 1))
        .opacity(disabled ? 0.5 : 1)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            RoundedRectangle(cornerRadius: 8)
                .fill(hover ? Semantic.danger.opacity(0.1) : .clear)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hover ? Semantic.danger : look.textMute)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 && !disabled }
        .pointingCursor()
    }
}

// MARK: - 权限中心分区

struct PermissionsSection: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    var body: some View {
        VStack(spacing: 12) {
            fdaCard
            helperCard
        }
        .onAppear { store.probeFullDiskAccess() }
    }

    private var fdaCard: some View {
        card(icon: "lock.shield") {
            cardText(
                title: L("settings.perm.fda.title"),
                description: Text(L("settings.perm.fda.desc"))
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textDim)
            )
        } trailing: {
            VStack(alignment: .trailing, spacing: 9) {
                badge(
                    text: store.hasFullDiskAccess ? L("settings.perm.badge.granted") : L("settings.perm.badge.denied"),
                    color: store.hasFullDiskAccess ? Color(hex: 0x63BB95) : Color(hex: 0xD89A54),
                    background: store.hasFullDiskAccess
                        ? Color(hex: 0x63BB95).opacity(0.14)
                        : Color(hex: 0xD89A54).opacity(0.14)
                )
                PillButton(
                    look: look, accent: accent,
                    title: L("settings.perm.fda.action"),
                    style: .outline,
                    action: { store.openFullDiskAccessSettings() }
                )
            }
        }
    }

    private var helperCard: some View {
        card(icon: "gearshape.2") {
            cardText(
                title: L("settings.perm.helper.title"),
                description:
                Text(L("settings.perm.helper.desc.pre"))
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textDim)
                    + Text(verbatim: "com.mole.helper")
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.text)
                    + Text(L("settings.perm.helper.desc.post"))
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textDim)
            )
        } trailing: {
            VStack(alignment: .trailing, spacing: 9) {
                badge(
                    text: L("settings.perm.badge.notInstalled"),
                    color: look.textMute,
                    background: look.text.opacity(0.05)
                )
                PillButton(
                    look: look, accent: accent,
                    title: L("settings.perm.helper.action"),
                    style: .filledAccent,
                    disabled: true,
                    horizontalPadding: 16,
                    help: L("settings.comingSoon"),
                    action: {}
                )
            }
        }
    }

    /// 卡片骨架
    private func card(
        icon: String,
        @ViewBuilder middle: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(accent.a.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(accent.a)
                )
            middle()
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.line, lineWidth: 1))
    }

    private func cardText(title: String, description: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Fonts.ui(14.5, .semibold))
                .foregroundStyle(look.text)
            description
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func badge(text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(Fonts.ui(11.5, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
    }
}

// MARK: - 高级分区

struct AdvancedSection: View {
    let store: SettingsStore
    let look: Look
    let accent: ModuleAccent

    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(look: look, title: L("settings.advanced.log"), subtitle: L("settings.advanced.log.desc")) {
                PillButton(
                    look: look, accent: accent,
                    title: L("settings.advanced.log.action"),
                    style: .outline, disabled: true,
                    horizontalPadding: 16, verticalPadding: 8,
                    help: L("settings.comingSoon"), action: {}
                )
            }
            SettingsRow(look: look, title: L("settings.advanced.index"), subtitle: L("settings.advanced.index.desc")) {
                PillButton(
                    look: look, accent: accent,
                    title: L("settings.advanced.index.action"),
                    style: .outline, disabled: true,
                    horizontalPadding: 16, verticalPadding: 8,
                    help: L("settings.comingSoon"), action: {}
                )
            }
            SettingsRow(
                look: look,
                title: L("settings.advanced.reset"),
                subtitle: L("settings.advanced.reset.desc"),
                titleColor: Semantic.danger,
                showsDivider: false
            ) {
                PillButton(
                    look: look, accent: accent,
                    title: L("settings.advanced.reset.action"),
                    style: .danger,
                    horizontalPadding: 16, verticalPadding: 8,
                    action: { showResetConfirm = true }
                )
            }
        }
        .confirmationDialog(
            L("settings.advanced.reset.confirm.title"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L("settings.advanced.reset.confirm.ok"), role: .destructive) {
                store.resetAll()
            }
            Button(L("settings.common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.advanced.reset.confirm.msg"))
        }
    }
}
