import MoleKit
import SwiftUI
import UniformTypeIdentifiers

/// 软件页（设计 §5.2 / 设计稿 apps 页）：三个子 tab——卸载 / 更新 / 启动项。
/// 卸载 tab：真实清单（robot apps list）+ 行展开残留分组 + 卸载执行链
/// （运行中拦截 → 危险确认 → robot apps apply 逐应用执行 → 完成汇总）。
/// 更新 / 启动项 tab 为诚实占位（数据源分别在 Phase 5+ / Phase 3）。
struct AppsView: View {
    @Environment(AppsStore.self) private var store
    @Environment(UpdatesStore.self) private var updatesStore
    @Environment(LaunchItemsStore.self) private var launchItemsStore
    @State private var showsHistory = false
    private let look = Look.ink
    private let accent = ModuleAccent.apps

    /// 设计稿 apps 页无页级标题：直接以「子 tab 胶囊 + 工具栏」开始（dc L427）。
    var body: some View {
        VStack(spacing: 14) {
            toolbar
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .onAppear { store.loadIfNeeded() }
    }

    // MARK: - 子 tab + 工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            subTabs
            Spacer()
            switch store.tab {
            case .uninstall:
                sortChips
                searchField
            case .update:
                updateSourceFilter
            case .startup:
                startupStatusFilter
            }
        }
    }

    /// 更新 tab 来源筛选（设计稿形态；v1 仅 Homebrew 一档，静态展示不循环）。
    private var updateSourceFilter: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
            Text(L("apps.update.sourceFilter"))
                .font(Fonts.ui(12.5, .medium))
        }
        .foregroundStyle(look.textDim)
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(look.text.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(look.line, lineWidth: 1))
    }

    /// 启动项 tab 状态筛选（循环 all/on/off）。
    private var startupStatusFilter: some View {
        Button {
            launchItemsStore.cycleFilter()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                Text(startupFilterLabel)
                    .font(Fonts.ui(12.5, .medium))
            }
            .foregroundStyle(look.textDim)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(look.text.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(look.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private var startupFilterLabel: String {
        switch launchItemsStore.filter {
        case .all: L("apps.startup.filter.all")
        case .on: L("apps.startup.filter.on")
        case .off: L("apps.startup.filter.off")
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
        case .update: updateTab
        case .startup: startupTab
        }
    }

    @ViewBuilder
    private var uninstallTab: some View {
        // 移除流程优先于清单状态：执行完会触发列表重扫（phase 回到 loading），
        // 不能让"正在扫描已安装应用"盖住 REMOVING / UNINSTALLED 页。
        switch store.removalPhase {
        case .running:
            removingView
        case let .done(removed, freed, failedItems, relatedFiles):
            removalDoneView(
                removed: removed,
                freed: freed,
                failedItems: failedItems,
                relatedFiles: relatedFiles
            )
        case .idle:
            switch store.phase {
            case .idle, .loading:
                loadingState
            case let .failed(reason):
                failedState(reason)
            case .loaded:
                idleListView
            }
        }
    }

    private var idleListView: some View {
        VStack(spacing: 0) {
            appList
            if !store.selection.isEmpty { batchBar }
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
        .sheet(isPresented: Binding(get: { store.confirmRemoval }, set: { store.confirmRemoval = $0 })) {
            RemoveConfirmSheet(store: store, look: look, accent: accent)
        }
    }

    // MARK: - 执行中（设计稿 REMOVING：光谱环放空 + 环心实时字节 + 逐项打勾清单）

    private var removingView: some View {
        VStack(spacing: 0) {
            ZStack {
                SpectrumRingView(
                    state: .executing(segments: removalSegments, progress: store.removalProgress),
                    accent: accent
                )
                VStack(spacing: 7) {
                    Fonts.eyebrow("Removing", size: 11)
                        .foregroundStyle(look.textMute)
                    freedReadout
                    Text(removingCaption)
                        .font(Fonts.ui(12))
                        .foregroundStyle(look.textDim)
                        .lineLimit(1)
                        .frame(maxWidth: 250)
                }
            }
            removalChecklist
                .frame(maxWidth: 560)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 环占比：每个应用一段（按计划字节均分兜底），双色相间。
    private var removalSegments: [RingSegment] {
        let count = max(1, store.removalAppNames.count)
        return (0 ..< count).map { index in
            RingSegment(
                fraction: 1.0 / Double(count),
                color: index % 2 == 0 ? accent.a : accent.b
            )
        }
    }

    /// 环心实时读数：大号衬线数字 + 单位（"1.06" + "GB"）。
    private var freedReadout: some View {
        let text = ByteCountFormatter.string(fromByteCount: store.removalFreed, countStyle: .file)
        let parts = text.split(separator: " ", maxSplits: 1)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.first.map(String.init) ?? "0")
                .font(Fonts.serif(44, .semibold))
                .foregroundStyle(look.text)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: store.removalFreed)
            Text(parts.count > 1 ? String(parts[1]) : "")
                .font(Fonts.mono(14))
                .foregroundStyle(look.textDim)
        }
    }

    private var removingCaption: String {
        let names = store.removalAppNames
        guard let first = names.first else { return "" }
        return names.count == 1
            ? L("apps.removing.captionOne", first)
            : L("apps.removing.captionMany", first, Int64(names.count))
    }

    private var removalChecklist: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.removalLog) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.ok ? "checkmark" : "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(entry.ok ? accent.b : Semantic.danger)
                                .frame(width: 14)
                            Text(entry.name)
                                .font(Fonts.mono(12))
                                .foregroundStyle(look.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(entry.bytes > 0 ? ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file) : "--")
                                .font(Fonts.mono(11.5))
                                .foregroundStyle(look.textMute)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: store.removalLog.count) {
                if let last = store.removalLog.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - 完成（设计稿 UNINSTALLED 整页：大号释放读数 + 照片换算 + 双按钮）

    private func removalDoneView(removed: Int, freed: Int64, failedItems: Int, relatedFiles: Int) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "trash")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent.b)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent.a.opacity(0.12)))
            Fonts.eyebrow("Uninstalled", size: 11)
                .foregroundStyle(look.textMute)
                .padding(.top, 22)
            Text(L("apps.done.title", Int64(removed)))
                .font(Fonts.serif(26, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 10)
            Text(L("apps.done.freed", ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))
                .font(Fonts.serif(54, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 2)
            Text(L("apps.done.equiv", Int64(max(0, freed / 4_000_000)), Int64(relatedFiles)))
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
                .padding(.top, 12)
            if failedItems > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(L("apps.remove.doneFailed", Int64(failedItems)))
                }
                .font(Fonts.ui(12))
                .foregroundStyle(Semantic.warn)
                .padding(.top, 8)
            }
            Text(L("apps.done.trash"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
                .padding(.top, 6)
            HStack(spacing: 12) {
                Button(L("apps.done.history")) { showsHistory = true }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                Button(L("apps.done.back")) { store.finishRemoval() }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(13, .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Capsule().fill(accent.gradient))
                    .foregroundStyle(accent.onAccent)
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsHistory) { HistoryView() }
    }

    // MARK: - 清单加载 / 失败 / 列表 / 批量条

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
                Text(L("apps.batch.count", Int64(store.selection.count)) +
                    (store.selectedSizeText.isEmpty ? "" : " · \(store.selectedSizeText)"))
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

    // MARK: - 更新 tab（设计 §5.2.2 / 设计稿 UPDATE TAB）

    private var updateTab: some View {
        VStack(spacing: 0) {
            switch updatesStore.phase {
            case .idle, .loading:
                tabLoading(L("apps.update.loading"))
            case let .failed(reason):
                tabFailed(reason) { updatesStore.reload() }
            case .loaded:
                if updatesStore.visibleUpdates.isEmpty {
                    tabEmpty(
                        icon: "checkmark.circle",
                        title: L("apps.update.empty.title"),
                        note: L("apps.update.empty.note")
                    )
                } else {
                    updateList
                }
            }
        }
        .onAppear { updatesStore.loadIfNeeded() }
    }

    private var updateList: some View {
        VStack(spacing: 0) {
            // 列表头：可更新计数 + 「全部更新」（设计稿 space-between）
            HStack(alignment: .firstTextBaseline) {
                Text(L("apps.update.header", Int64(updatesStore.visibleCount)))
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.text)
                Spacer()
                Button {
                    updatesStore.updateAll()
                } label: {
                    Text(L("apps.update.updateAll"))
                        .font(Fonts.ui(12.5, .semibold))
                        .foregroundStyle(updatesStore.canUpdateAll ? accent.a : look.textMute)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingCursor()
                .disabled(!updatesStore.canUpdateAll)
            }
            .padding(.horizontal, 2).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(updatesStore.visibleUpdates) { item in
                        UpdateRow(
                            item: item,
                            store: updatesStore,
                            appsStore: store,
                            look: look,
                            accent: accent
                        )
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 启动项 tab（设计 §5.2.3 / 设计稿 STARTUP TAB）

    private var startupTab: some View {
        VStack(spacing: 0) {
            switch launchItemsStore.phase {
            case .idle, .loading:
                tabLoading(L("apps.startup.loading"))
            case let .failed(reason):
                tabFailed(reason) { launchItemsStore.reload() }
            case .loaded:
                if launchItemsStore.items.isEmpty {
                    tabEmpty(
                        icon: "power",
                        title: L("apps.startup.empty"),
                        note: ""
                    )
                } else {
                    startupList
                }
            }
        }
        .onAppear { launchItemsStore.loadIfNeeded() }
    }

    private var startupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                startupGroup(
                    header: L("apps.startup.loginHeader", Int64(launchItemsStore.loginItems.count)),
                    items: launchItemsStore.loginItems
                )
                startupGroup(
                    header: L("apps.startup.serviceHeader", Int64(launchItemsStore.serviceItems.count)),
                    items: launchItemsStore.serviceItems
                )
            }
            .padding(.trailing, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startupGroup(header: String, items: [LaunchItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header)
                .font(Fonts.ui(12, .semibold))
                .foregroundStyle(look.textMute)
                .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(items) { item in
                    LaunchItemRow(item: item, store: launchItemsStore, look: look, accent: accent)
                }
            }
        }
    }

    // MARK: - 更新/启动项共用的加载/失败/空态（与卸载 tab 同源诚实呈现）

    private func tabLoading(_ title: String) -> some View {
        VStack(spacing: 16) {
            RingSpinner(accent: accent, size: 44, lineWidth: 3)
            Text(title)
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabFailed(_ reason: String, retry: @escaping () -> Void) -> some View {
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
            Button(L("common.retry")) { retry() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabEmpty(icon: String, title: String, note: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(look.textMute)
            Text(title)
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.textDim)
            if !note.isEmpty {
                Text(note)
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textMute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 二次确认弹层（设计稿：琥珀警示 + 衬线标题 + 逐应用构成 + 橙色主按钮）

private struct RemoveConfirmSheet: View {
    var store: AppsStore
    var look: Look
    var accent: ModuleAccent

    var body: some View {
        VStack(spacing: 0) {
            // 警示徽标：颜色 + 图标双通道（文字在标题）
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Semantic.warnAlt)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Semantic.warnAlt.opacity(0.12)))
                .padding(.top, 28)
            Text(L("apps.remove.confirmTitle", Int64(store.selection.count)))
                .font(Fonts.serif(24, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 16)
            Text(L("apps.confirm.message"))
                .font(Fonts.ui(13))
                .foregroundStyle(look.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)

            // 逐应用构成：图标 · 名称 · 本体 X + 残留 N 项 · 小计
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.selectedApps) { app in
                        appRow(app)
                    }
                }
            }
            .frame(maxHeight: 220)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            HStack(spacing: 10) {
                Text(L("apps.confirm.total", store.selectedSizeText.isEmpty ? "--" : store.selectedSizeText))
                    .font(Fonts.mono(13))
                    .foregroundStyle(look.textDim)
                Spacer()
                Button(L("common.cancel")) { store.confirmRemoval = false }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.textDim)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .overlay(Capsule().stroke(look.lineStrong, lineWidth: 1))
                    .contentShape(Capsule())
                Button {
                    store.confirmRemoval = false
                    store.executeRemoval()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text(L("apps.confirm.trash"))
                    }
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(Semantic.dangerFill))
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: 480)
        .background(look.surface)
        .presentationBackground(look.surfaceSolid)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let leftovers = store.loadedLeftovers(for: app)
        let checked = store.checkedLeftoverCount(for: app)
        let total = Int64(app.sizeBytes ?? 0) + store.checkedLeftoverBytes(for: app)
        return HStack(spacing: 12) {
            Image(nsImage: store.icon(for: app))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Text(leftovers == nil
                    ? L("apps.confirm.scanning")
                    : L("apps.confirm.perApp", app.size == "N/A" ? "--" : app.size, Int64(checked)))
                    .font(Fonts.mono(11))
                    .foregroundStyle(look.textMute)
            }
            Spacer(minLength: 8)
            Text(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : (app.size == "N/A" ? "--" : app.size))
                .font(Fonts.mono(12.5))
                .foregroundStyle(look.textDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(look.line.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(look.line, lineWidth: 1))
    }
}

// MARK: - 行（设计稿 AppCard：点击行体展开残留分组，勾选进入批量；左侧 3px 选中色条）

private struct AppRow: View {
    var app: InstalledApp
    var store: AppsStore
    var look: Look
    var accent: ModuleAccent

    @State private var hovering = false

    private var selected: Bool {
        store.selection.contains(app.id)
    }

    private var isExpanded: Bool {
        store.expanded.contains(app.id)
    }

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

// MARK: - 更新行（设计稿 UPDATE TAB：图标 + 名称/来源徽标 + 版本差 + 忽略/更新）

private struct UpdateRow: View {
    var item: AppUpdate
    var store: UpdatesStore
    var appsStore: AppsStore
    var look: Look
    var accent: ModuleAccent

    /// 关联已装应用（cask token 命中 Homebrew 清单）→ 友好名与真实图标；否则回退 token + 通用图标。
    private var matchedApp: InstalledApp? {
        appsStore.apps.first { $0.source == "Homebrew" && $0.uninstallName == item.token }
    }

    private var displayName: String {
        matchedApp?.name ?? item.token
    }

    private var icon: NSImage {
        if let app = matchedApp { return appsStore.icon(for: app) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    var body: some View {
        let running = store.isRunning(item)
        let failure = store.failure(item)
        return HStack(spacing: 13) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(Fonts.ui(13.5, .semibold))
                        .foregroundStyle(look.text)
                        .lineLimit(1)
                    // 来源徽标（v1 恒为 Homebrew）
                    Text(verbatim: item.sourceDisplay)
                        .font(Fonts.ui(10.5))
                        .foregroundStyle(look.textMute)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(look.text.opacity(0.05)))
                }
                // 版本差：旧 → 新（mono 11.5，新版本橙红）
                HStack(spacing: 0) {
                    Text(verbatim: item.installed + " → ")
                        .foregroundStyle(look.textMute)
                    Text(verbatim: item.latest)
                        .foregroundStyle(Semantic.danger)
                        .fontWeight(.medium)
                }
                .font(Fonts.mono(11.5))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let failure {
                Text(L("apps.update.failed"))
                    .font(Fonts.ui(12))
                    .foregroundStyle(Semantic.warn)
                    .help(failure)
            } else if !running {
                Button {
                    store.ignore(item)
                } label: {
                    Text(L("apps.update.ignore"))
                        .font(Fonts.ui(12))
                        .foregroundStyle(look.textMute)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
            if running {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 60, height: 30)
            } else {
                Button {
                    store.update(item)
                } label: {
                    Text(failure == nil ? L("apps.update.button") : L("common.retry"))
                        .font(Fonts.ui(12.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: 0xC86B49)))
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.line, lineWidth: 1))
    }
}

// MARK: - 启动项行（设计稿 STARTUP TAB：登录项 / 后台服务两种版式 + 开关）

private struct LaunchItemRow: View {
    var item: LaunchItem
    var store: LaunchItemsStore
    var look: Look
    var accent: ModuleAccent

    private var icon: NSImage {
        if !item.path.isEmpty {
            return NSWorkspace.shared.icon(forFile: item.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// 后台服务副行类型文案：daemon → LaunchDaemon，agent → LaunchAgent；系统项追加 "· 系统项"。
    private var serviceType: String {
        let base = item.category == .daemon ? "LaunchDaemon" : "LaunchAgent"
        return item.sys ? base + " · " + L("apps.startup.systemTag") : base
    }

    /// 登录项副行："App · 允许实际启动 · <路径>"（路径为我们能拿到的技术标识）。
    private var loginSubtitle: String {
        let caption = L("apps.startup.loginCaption")
        guard !item.path.isEmpty else { return caption }
        return caption + " · " + (item.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                if item.category.isLogin {
                    Text(item.label)
                        .font(Fonts.ui(13, .semibold))
                        .foregroundStyle(look.text)
                        .lineLimit(1)
                    Text(verbatim: loginSubtitle)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(look.textMute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(verbatim: item.label)
                        .font(Fonts.mono(12, .medium))
                        .foregroundStyle(look.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: serviceType)
                        .font(Fonts.ui(10.5))
                        .foregroundStyle(look.textMute)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            LaunchToggle(
                on: item.enabled, mutable: item.mutable, pending: store.isPending(item),
                accent: accent, look: look
            ) {
                store.toggle(item)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.line, lineWidth: 1))
        .opacity(item.sys ? 0.6 : 1) // 系统项整行降透明（只读提示）
    }
}

/// 设计稿开关（34×20 胶囊 + 16 白滑块）。开=accent 轨道滑块右移；系统项恒暗轨道且只读。
private struct LaunchToggle: View {
    var on: Bool
    var mutable: Bool
    var pending: Bool
    var accent: ModuleAccent
    var look: Look
    var onToggle: () -> Void

    private var trackColor: Color {
        guard mutable else { return look.text.opacity(0.1) } // 系统项：恒暗轨道
        return on ? accent.a : look.text.opacity(0.14)
    }

    var body: some View {
        ZStack {
            Capsule().fill(trackColor)
                .frame(width: 34, height: 20)
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .offset(x: on ? 7 : -7)
        }
        .frame(width: 34, height: 20)
        .opacity(pending ? 0.6 : 1)
        .animation(.easeOut(duration: 0.2), value: on)
        .contentShape(Rectangle())
        .onTapGesture { if mutable, !pending { onToggle() } }
        .modifier(ConditionalPointer(active: mutable && !pending))
    }
}

/// 仅在可操作时挂 pointingCursor（系统项/进行中不给可点暗示）。
private struct ConditionalPointer: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { content.pointingCursor() } else { content }
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
