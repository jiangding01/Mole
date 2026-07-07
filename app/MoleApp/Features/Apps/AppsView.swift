import MoleKit
import SwiftUI

/// 软件页（设计 §5.2 / 设计稿 apps 页）：三个子 tab——卸载 / 更新 / 启动项。
/// M0：卸载 tab 接真实清单（robot apps list），搜索 + 排序 + 多选；
/// 卸载执行等 robot apps plan/apply 落地后接入（按钮禁用并说明，不做假动作）。
/// 更新 / 启动项 tab 为诚实占位（数据源分别在 Phase 5+ / Phase 3）。
struct AppsView: View {
    @State private var store = AppsStore()
    private let look = Look.ink
    private let accent = ModuleAccent.apps

    var body: some View {
        VStack(spacing: 14) {
            pageHeader
            toolbar
            content
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onAppear { store.loadIfNeeded() }
    }

    // MARK: - 页头

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Text(L("apps.title"))
                .font(Fonts.serif(28, .semibold))
                .foregroundStyle(look.text)
            if store.phase == .loaded {
                Text(L("apps.header.count", Int64(store.apps.count)) + (store.totalSizeText.isEmpty ? "" : " · " + L("apps.header.total", store.totalSizeText)))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
            }
            Spacer()
        }
    }

    // MARK: - 子 tab + 工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            subTabs
            Spacer()
            if store.tab == .uninstall {
                sortChips
                searchField
            }
        }
    }

    private var subTabs: some View {
        HStack(spacing: 2) {
            ForEach(AppsStore.Tab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { store.tab = tab }
                } label: {
                    Text(tab.title)
                        .font(Fonts.ui(12.5, .semibold))
                        .padding(.horizontal, 15).padding(.vertical, 6)
                        .background {
                            if store.tab == tab { Capsule().fill(accent.gradient) }
                        }
                        .foregroundStyle(store.tab == tab ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(look.textMute))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        }
        .padding(4)
        .background(Capsule().fill(look.chrome))
        .overlay(Capsule().stroke(look.line, lineWidth: 1))
    }

    private var sortChips: some View {
        HStack(spacing: 2) {
            sortChip(L("apps.sort.name"), .name)
            sortChip(L("apps.sort.size"), .size)
            sortChip(L("apps.sort.source"), .source)
        }
    }

    private func sortChip(_ label: String, _ key: AppsStore.SortKey) -> some View {
        Button {
            store.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(label)
                Text(store.sortKey == key ? (store.sortDescending ? "↓" : "↑") : " ")
                    .font(Fonts.mono(11))
                    .frame(width: 8)
            }
            .font(Fonts.ui(12, .medium))
            .foregroundStyle(store.sortKey == key ? look.text : look.textMute)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(look.textMute)
            TextField(L("apps.search.placeholder"), text: Binding(get: { store.search }, set: { store.search = $0 }))
                .textFieldStyle(.plain)
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.text)
                .frame(width: 120)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(look.chrome))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(look.line, lineWidth: 1))
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch store.tab {
        case .uninstall: uninstallTab
        case .update:
            comingSoon(icon: "arrow.triangle.2.circlepath",
                       title: L("apps.update.title"),
                       note: L("apps.update.note"))
        case .startup:
            comingSoon(icon: "power",
                       title: L("apps.startup.title"),
                       note: L("apps.startup.note"))
        }
    }

    @ViewBuilder
    private var uninstallTab: some View {
        switch store.phase {
        case .idle, .loading:
            loadingState
        case let .failed(reason):
            failedState(reason)
        case .loaded:
            VStack(spacing: 0) {
                appList
                if !store.selection.isEmpty { batchBar }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            ZStack {
                RingSpinner(accent: accent, size: 200, lineWidth: 3)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(accent.b)
            }
            Fonts.eyebrow("Scanning Applications", size: 11)
                .foregroundStyle(look.textMute)
                .padding(.top, 38)
            Text(L("apps.loading.title"))
                .font(Fonts.serif(30, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 12)
            Text(L("apps.loading.sub"))
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 30))
                .foregroundStyle(Semantic.warn)
            Text(L("apps.failed.title"))
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.text)
            Text(reason)
                .font(Fonts.mono(11))
                .foregroundStyle(look.textMute)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L("common.retry")) { store.reload() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if store.visibleApps.isEmpty {
                    Text(L("apps.empty"))
                        .font(Fonts.ui(13))
                        .foregroundStyle(look.textMute)
                        .padding(.vertical, 48)
                } else {
                    ForEach(store.visibleApps) { app in
                        AppRow(app: app,
                               icon: store.icon(for: app),
                               selected: store.selection.contains(app.id),
                               look: look,
                               accent: accent,
                               onToggle: { store.toggleSelection(app) },
                               onReveal: { store.reveal(app) })
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 批量条（设计稿 batch bar）：卸载执行未接入前按钮禁用并说明。
    private var batchBar: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(store.selectedApps.first?.name ?? "")
                    .font(Fonts.ui(13.5, .semibold))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Text(L("apps.batch.count", Int64(store.selection.count)) + (store.selectedSizeText.isEmpty ? "" : " · \(store.selectedSizeText)"))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
            }
            Spacer()
            Button(L("apps.batch.clear")) { store.selection.removeAll() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12.5, .semibold))
                .foregroundStyle(look.textDim)
            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text(L("apps.batch.remove", Int64(store.selection.count)))
                }
                .font(Fonts.ui(13, .semibold))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(look.line))
                .foregroundStyle(look.textMute)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help(L("apps.batch.disabled"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .padding(.top, 12)
    }

    private func comingSoon(icon: String, title: String, note: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(look.textMute)
            Text(title)
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.textDim)
            Text(note)
                .font(Fonts.ui(12))
                .foregroundStyle(look.textMute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 行

private struct AppRow: View {
    var app: InstalledApp
    var icon: NSImage
    var selected: Bool
    var look: Look
    var accent: ModuleAccent
    var onToggle: () -> Void
    var onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 13) {
            checkbox
            Image(nsImage: icon)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(Fonts.ui(13.5, .semibold))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if app.source == "Homebrew" {
                Text("Homebrew")
                    .font(Fonts.mono(10, .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(accent.a.opacity(0.12)))
                    .foregroundStyle(accent.b)
            }
            Text(app.size == "N/A" ? "--" : app.size)
                .font(Fonts.mono(13))
                .foregroundStyle(look.textDim)
                .frame(minWidth: 72, alignment: .trailing)
            Menu {
                Button(L("apps.row.reveal"), action: onReveal)
                Button(L("apps.row.copyBundleId")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.bundleId, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(look.textMute)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(selected ? AnyShapeStyle(accent.a.opacity(0.07)) : AnyShapeStyle(look.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? accent.a.opacity(0.45) : (hovering ? look.lineStrong : look.line), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .pointingCursor()
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.clear))
            .frame(width: 21, height: 21)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? accent.a : look.lineStrong, lineWidth: 1.5)
            )
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent.onAccent)
                }
            }
    }
}
