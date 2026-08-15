import MoleKit
import SwiftUI

/// 优化页（设计 §5.4 / 设计稿 optimize 页）：
/// 清单（分组任务卡：日常维护 / 修复小毛病 / 深度维护）→ 执行
/// （光谱环 tending 逐段点亮 + 任务状态流）→ 完成报告。
/// 21 项全部免管理员执行，无需管理员提示（CHANGELOG-2026-08-15 §1.1）。
struct OptimizeView: View {
    @Environment(OptimizeStore.self) private var store
    private let look = Look.ink
    private let accent = ModuleAccent.optimize

    /// 设计稿 optimize 页无页级标题：列表态自带头部（Customize eyebrow + serif
    /// 标题 + 已选副行 + 右侧开始钮，dc L730-740）。
    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .onAppear { store.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading: loadingView
        case .list: listView
        case .running: runningView
        case let .report(done, failed, skipped):
            reportView(done: done, failed: failed, skipped: skipped)
        case let .failed(reason): failedView(reason)
        }
    }

    // MARK: - loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            RingSpinner(accent: accent, size: 40, lineWidth: 2.5)
            Text(L("optimize.loading"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 清单（分组卡片 + 底部执行条）

    private var listView: some View {
        VStack(spacing: 0) {
            listHeader
                .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.grouped(), id: \.category.id) { group in
                        groupCard(group.category, group.rows)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 列表态头部（设计稿 optList，dc L730-740）：Customize eyebrow + serif 27
    /// 标题 + 已选副行（数字 accent 高亮），右侧开始按钮（底部对齐）。
    private var listHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Fonts.eyebrow("Customize", size: 10)
                    .foregroundStyle(look.textMute)
                Text(L("optimize.list.title"))
                    .font(Fonts.serif(27))
                    .foregroundStyle(look.text)
                    .padding(.top, 6)
                (Text(L("optimize.list.sub.prefix"))
                    + Text(verbatim: "\(store.checked.count)")
                    .foregroundColor(accent.a)
                    .fontWeight(.semibold)
                    + Text(L("optimize.list.sub.suffix")))
                    .font(Fonts.ui(13))
                    .foregroundColor(look.textDim)
                    .padding(.top, 7)
            }
            Spacer()
            Button {
                store.execute()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                    Text(L("optimize.cta.run", Int64(store.checked.count)))
                }
                .font(Fonts.ui(13, .semibold))
                .padding(.horizontal, 24).padding(.vertical, 11)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .disabled(store.checked.isEmpty)
            .opacity(store.checked.isEmpty ? 0.45 : 1)
        }
    }

    /// 双列卡片网格列定义（设计稿 optList，dc L780：grid-template-columns:1fr 1fr）。
    private var taskGridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    /// 分类节（设计稿 g.sec：12px semibold text-mute 小标签 + 双列任务卡网格，
    /// 无外层包裹卡、无计数）。
    private func groupCard(_ category: OptimizeStore.Category, _ rows: [OptimizeStore.TaskRow]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(category.title)
                .font(Fonts.ui(12, .semibold))
                .foregroundStyle(look.textMute)
                .padding(.horizontal, 2)
            LazyVGrid(columns: taskGridColumns, spacing: 10) {
                ForEach(rows) { task in
                    taskCard(task)
                }
            }
        }
    }

    /// 任务卡（设计稿 optList task 卡，dc L781-789）：勾选态用 accent 底 + 描边强调，
    /// 描述左对齐到复选框内侧（19 宽 + 10 间距）。
    private func taskCard(_ task: OptimizeStore.TaskRow) -> some View {
        let checked = store.checked.contains(task.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                OptimizeCheckBox(checked: checked, accent: accent, look: look, size: 19) {
                    store.toggle(task)
                }
                Text(task.name)
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if OptimizeStore.readOnlyTasks.contains(task.id) {
                    readOnlyBadge
                }
            }
            Text(task.desc)
                .font(Fonts.ui(11))
                .foregroundStyle(look.textMute)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.leading, 29)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(checked ? AnyShapeStyle(accent.a.opacity(0.06)) : AnyShapeStyle(look.surface))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(checked ? accent.a.opacity(0.4) : look.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(task) }
        .pointingCursor()
    }

    // MARK: - 执行中（tending 环逐段点亮 + 任务状态列表）

    private var runningView: some View {
        VStack(spacing: 0) {
            ZStack {
                SpectrumRingView(
                    state: .tending(done: store.finishedCount, total: store.runTotal),
                    accent: accent
                )
                VStack(spacing: 7) {
                    Fonts.eyebrow("Optimizing", size: 11)
                        .foregroundStyle(look.textMute)
                    Text("\(store.finishedCount)/\(store.runTotal)")
                        .font(Fonts.serif(44, .semibold))
                        .foregroundStyle(look.text)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: store.finishedCount)
                    Text(store.currentTaskName)
                        .font(Fonts.ui(12))
                        .foregroundStyle(look.textDim)
                        .lineLimit(1)
                        .frame(maxWidth: 240)
                }
            }
            statusList
                .frame(maxWidth: 560)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(store.tasks.filter { store.states[$0.id] != nil }) { task in
                    statusRow(task)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func statusRow(_ task: OptimizeStore.TaskRow) -> some View {
        let state = store.states[task.id] ?? .pending
        return HStack(spacing: 10) {
            statusIcon(state)
                .frame(width: 16)
            Text(task.name)
                .font(Fonts.ui(12))
                .foregroundStyle(look.textDim)
                .lineLimit(1)
            Spacer()
            statusTrailing(state, taskId: task.id)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    @ViewBuilder
    private func statusIcon(_ state: OptimizeStore.TaskState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(look.lineStrong, lineWidth: 1.5).frame(width: 9, height: 9)
        case .running:
            RingSpinner(accent: accent, size: 13, lineWidth: 2)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent.b)
        case .skipped:
            Image(systemName: "shield")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Semantic.warn)
        case .failedTask:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Semantic.danger)
        }
    }

    /// 只读徽标（设计：冷灰胶囊 + 眼睛，title 说明"不会做任何修改"）。
    private var readOnlyBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
                .font(.system(size: 8, weight: .semibold))
            Text(L("optimize.badge.readonly"))
                .font(Fonts.ui(9, .semibold))
        }
        .foregroundStyle(Color(red: 0.616, green: 0.690, blue: 0.776)) // #9DB0C6
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color(red: 0.486, green: 0.565, blue: 0.659).opacity(0.14)))
        .help(L("optimize.badge.readonly.help"))
    }

    @ViewBuilder
    private func statusTrailing(_ state: OptimizeStore.TaskState, taskId: String) -> some View {
        switch state {
        case let .done(ms):
            // 设计（CHANGELOG §1.1）：完成行显示该任务的 result 真实措辞；
            // 未知 id 无对应文案时回退为耗时。
            if let result = LOpt("optimize.task.\(taskId).result") {
                Text(result)
                    .font(Fonts.ui(10.5))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
            } else if let ms {
                Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "<1s")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(look.textMute)
            } else {
                EmptyView()
            }
        case .skipped:
            Text(L("optimize.status.whitelisted"))
                .font(Fonts.ui(10, .semibold))
                .foregroundStyle(Semantic.warn)
        case .failedTask:
            Text(L("optimize.status.failed"))
                .font(Fonts.ui(10, .semibold))
                .foregroundStyle(Semantic.danger)
        default:
            EmptyView()
        }
    }

    // MARK: - 报告 / 失败

    private func reportView(done: Int, failed: Int, skipped: Int) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent.b)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent.a.opacity(0.12)))
            Fonts.eyebrow("Optimized", size: 11)
                .foregroundStyle(look.textMute)
                .padding(.top, 22)
            Text(L("optimize.report.title", Int64(done)))
                .font(Fonts.serif(34, .semibold))
                .foregroundStyle(look.text)
                .padding(.top, 10)
            if failed > 0 {
                noteLine("exclamationmark.triangle", L("optimize.report.failed", Int64(failed)), Semantic.warn)
            }
            if skipped > 0 {
                noteLine("shield", L("optimize.report.skipped", Int64(skipped)), look.textMute)
            }
            Text(L("optimize.report.note"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textMute)
                .padding(.top, 10)
            Button(L("optimize.cta.back")) { store.backToList() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(13, .semibold))
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noteLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text)
        }
        .font(Fonts.ui(12))
        .foregroundStyle(color)
        .padding(.top, 8)
    }

    private func failedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 30))
                .foregroundStyle(Semantic.warn)
            Text(L("optimize.failed.title"))
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.text)
            Text(reason)
                .font(Fonts.mono(11))
                .foregroundStyle(look.textMute)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L("common.retry")) { store.load() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 优化页复选框（与清理页同款；抽公用组件排期在清理页稳定后）。
private struct OptimizeCheckBox: View {
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
