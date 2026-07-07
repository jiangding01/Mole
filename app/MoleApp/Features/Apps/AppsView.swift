import MoleKit
import SwiftUI

/// 软件页（设计 §5.2 / 设计稿 apps 页）：三个子 tab——卸载 / 更新 / 启动项。
/// 卸载 tab：真实清单（robot apps list）+ 行展开残留分组 + 卸载执行链
/// （运行中拦截 → 危险确认 → robot apps apply 逐应用执行 → 完成汇总）。
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
                switch store.removalPhase {
                case .idle:
                    if !store.selection.isEmpty { batchBar }
                case let .running(app, index, total):
                    removalProgressBar(app: app, index: index, total: total)
                case let .done(removed, freed, failedItems):
                    removalDoneBar(removed: removed, freed: freed, failedItems: failedItems)
                }
            }
            .alert(L("apps.remove.runningTitle"), isPresented: Binding(
                get: { !store.runningBlockers.isEmpty },
                set: { if !$0 { store.runningBlockers = [] } }
            )) {
                Button(L("apps.remove.quitAndContinue")) { store.quitBlockersAndContinue() }
                Button(L("common.cancel"), role: .cancel) { store.runningBlockers = [] }
            } message: {
                Text(L("apps.remove.runningMsg", store.runningBlockers.map(\.name).joined(separator: "、")))
            }
            .confirmationDialog(
                L("apps.remove.confirmTitle", Int64(store.selection.count)),
                isPresented: Binding(get: { store.confirmRemoval }, set: { store.confirmRemoval = $0 })
            ) {
                Button(L("apps.remove.confirm"), role: .destructive) {
                    store.confirmRemoval = false
                    store.executeRemoval()
                }
                Button(L("common.cancel"), role: .cancel) { store.confirmRemoval = false }
            } message: {
                Text(L("apps.remove.confirmMsg", store.selectedSizeText.isEmpty ? "--" : store.selectedSizeText))
            }
        }
    }

    /// 执行中：进度条替换批量条（破坏性操作期间不可再发起）。
    private func removalProgressBar(app: String, index: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            RingSpinner(accent: accent, size: 16, lineWidth: 2)
            Text(L("apps.remove.progress", app, Int64(index + 1), Int64(total)))
                .font(Fonts.ui(13, .semibold))
                .foregroundStyle(look.text)
            Spacer()
            Text(L("apps.remove.trashNote"))
                .font(Fonts.ui(11))
                .foregroundStyle(look.textMute)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .padding(.top, 12)
    }

    /// 完成态：结果摘要（颜色 + 图标 + 文字三通道）。
    private func removalDoneBar(removed: Int, freed: Int64, failedItems: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: failedItems > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failedItems > 0 ? Semantic.warn : Semantic.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("apps.remove.doneTitle", Int64(removed),
                       ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.text)
                if failedItems > 0 {
                    Text(L("apps.remove.doneFailed", Int64(failedItems)))
                        .font(Fonts.ui(11))
                        .foregroundStyle(Semantic.warn)
                } else {
                    Text(L("apps.remove.trashNote"))
                        .font(Fonts.ui(11))
                        .foregroundStyle(look.textMute)
                }
            }
            Spacer()
            Button(L("apps.remove.finish")) { store.finishRemoval() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12.5, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .padding(.top, 12)
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
                        AppRow(app: app, store: store, look: look, accent: accent)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 批量条（设计稿 batch bar）：移除入口，先运行中拦截再危险确认。
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
            Button {
                store.requestRemoval()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text(L("apps.batch.remove", Int64(store.selection.count)))
                }
                .font(Fonts.ui(13, .semibold))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(Color(hex: 0xF3ECE0)))
                .foregroundStyle(Color(hex: 0x1A1206))
            }
            .buttonStyle(.plain)
            .pointingCursor()
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

// MARK: - 行（设计稿 AppCard：点击行体展开残留分组，勾选进入批量；左侧 3px 选中色条）

private struct AppRow: View {
    var app: InstalledApp
    var store: AppsStore
    var look: Look
    var accent: ModuleAccent

    @State private var hovering = false

    private var selected: Bool { store.selection.contains(app.id) }
    private var isExpanded: Bool { store.expanded.contains(app.id) }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if selected { summaryLine }
            if isExpanded { expansion }
        }
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(selected ? AnyShapeStyle(accent.a.opacity(0.06)) : AnyShapeStyle(look.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? accent.a.opacity(0.45) : (hovering ? look.lineStrong : look.line), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if selected {
                // 设计稿：选中卡片左侧 3px 强调色条
                UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13)
                    .fill(accent.gradient)
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .onHover { hovering = $0 }
    }

    // MARK: 头行

    private var headerRow: some View {
        HStack(spacing: 13) {
            CheckBox(checked: selected, accent: accent, look: look, size: 21) {
                store.toggleSelection(app)
            }
            Image(nsImage: store.icon(for: app))
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
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(look.textMute)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
            Menu {
                Button(L("apps.row.reveal")) { store.reveal(app) }
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
        .contentShape(Rectangle())
        .onTapGesture {
            // 设计稿交互：行体点击 = 展开/收起（勾选走左侧 checkbox）
            withAnimation(.easeOut(duration: 0.2)) { store.toggleExpanded(app) }
        }
        .pointingCursor()
    }

    // MARK: 选中摘要（设计稿：移除本体 + 残留 x/y 项 · 共 SIZE）

    @ViewBuilder
    private var summaryLine: some View {
        if let items = store.loadedLeftovers(for: app) {
            let checked = store.checkedLeftoverCount(for: app)
            let totalBytes = Int64(app.sizeBytes ?? 0) + store.checkedLeftoverBytes(for: app)
            let reviewBytes = store.uncheckedReviewBytes(for: app)
            HStack(spacing: 6) {
                Text(L("apps.row.leftoverSummary", Int64(checked), Int64(items.count), fmtBytes(totalBytes)))
                    .foregroundStyle(accent.b)
                    .fontWeight(.semibold)
                if reviewBytes > 0 {
                    Text(L("apps.row.reviewNote", fmtBytes(reviewBytes)))
                        .foregroundStyle(Semantic.warn)
                }
                Spacer()
            }
            .font(Fonts.ui(12))
            .padding(.leading, 49).padding(.trailing, 15).padding(.bottom, 10)
        }
    }

    // MARK: 展开区（分组残留清单）

    @ViewBuilder
    private var expansion: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(look.line)
            switch store.leftovers[app.id] {
            case .loading?, nil:
                HStack(spacing: 8) {
                    RingSpinner(accent: accent, size: 14, lineWidth: 2)
                    Text(L("apps.leftovers.loading"))
                        .font(Fonts.mono(11))
                        .foregroundStyle(look.textMute)
                }
                .padding(14)
            case let .failed(reason)?:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Semantic.warn)
                    Text("\(L("apps.leftovers.failed"))：\(reason)")
                        .font(Fonts.mono(11))
                        .foregroundStyle(look.textMute)
                        .lineLimit(2)
                    Button(L("common.retry")) { store.retryLeftovers(for: app) }
                        .buttonStyle(.plain)
                        .pointingCursor()
                        .font(Fonts.ui(11, .semibold))
                        .foregroundStyle(accent.b)
                }
                .padding(14)
            case .loaded?:
                let groups = store.groupedLeftovers(for: app)
                if groups.isEmpty {
                    Text(L("apps.leftovers.empty"))
                        .font(Fonts.ui(12))
                        .foregroundStyle(look.textMute)
                        .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.group) { group in
                            Fonts.eyebrow(group.group, size: 10)
                                .foregroundStyle(look.textMute)
                                .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 3)
                            ForEach(group.items, id: \.id) { item in
                                leftoverRow(item)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }

    private func leftoverRow(_ item: RobotItem) -> some View {
        let checked = store.checkedLeftovers[app.id]?.contains(item.id) ?? false
        let reviewOnly = store.isReviewOnly(item)
        return HStack(spacing: 11) {
            if reviewOnly {
                // 系统级复核项：仅展示（CLI 同姿态"预览可见、从不删除"），盾牌占位
                Image(systemName: "shield")
                    .font(.system(size: 11))
                    .foregroundStyle(look.textMute)
                    .frame(width: 18, height: 18)
            } else {
                CheckBox(checked: checked, accent: accent, look: look, size: 18) {
                    store.toggleLeftover(app, item)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(leftoverName(item))
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Text(abbreviated(item.path ?? ""))
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.risk == "caution" {
                Text(L("apps.badge.review"))
                    .font(Fonts.ui(10, .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Semantic.warn.opacity(0.12)))
                    .foregroundStyle(Semantic.warn)
            }
            Text(fmtBytes(item.bytes ?? 0))
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textMute)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleLeftover(app, item) }
        .pointingCursor()
    }

    private func leftoverName(_ item: RobotItem) -> String {
        let path = item.path ?? item.label
        return (path as NSString).lastPathComponent
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func fmtBytes(_ v: Int64) -> String {
        guard v > 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }
}

/// 设计稿样式复选框（圆角方块，选中 = accent 渐变 + 对钩）。
private struct CheckBox: View {
    var checked: Bool
    var accent: ModuleAccent
    var look: Look
    var size: CGFloat
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(checked ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.clear))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.29)
                        .stroke(checked ? accent.a : look.lineStrong, lineWidth: 1.5)
                )
                .overlay {
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.52, weight: .bold))
                            .foregroundStyle(accent.onAccent)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }
}
