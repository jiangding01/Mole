import MoleKit
import SwiftUI

/// 优化页（设计 §5.4 / 设计稿 optimize 页）：
/// 清单（分组任务卡：日常维护 / 修复小毛病 / 深度维护）→ 执行
/// （光谱环 tending 逐段点亮 + 任务状态流）→ 完成报告。
/// 深度任务的管理员分支当前自动跳过（后台助手 Phase 3 前的诚实姿态）。
struct OptimizeView: View {
    @State private var store = OptimizeStore()
    private let look = Look.ink
    private let accent = ModuleAccent.optimize

    var body: some View {
        VStack(spacing: 14) {
            pageHeader
            content
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onAppear { store.loadIfNeeded() }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Text(L("optimize.title"))
                .font(Fonts.serif(28, .semibold))
                .foregroundStyle(look.text)
            if store.phase == .list {
                Text(L("optimize.header.selected", Int64(store.checked.count), Int64(store.tasks.count)))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
            }
            Spacer()
        }
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
            adminNote
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.grouped(), id: \.category.id) { group in
                        groupCard(group.category, group.rows)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            listBar
        }
    }

    /// 深度任务说明（颜色 + 图标 + 文字三通道，诚实告知 sudo 分支跳过）。
    private var adminNote: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(Semantic.info)
            Text(L("optimize.adminNote"))
                .font(Fonts.ui(11.5))
                .foregroundStyle(look.textDim)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Semantic.info.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Semantic.info.opacity(0.22), lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func groupCard(_ category: OptimizeStore.Category, _ rows: [OptimizeStore.TaskRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Fonts.eyebrow(category.title, size: 10)
                    .foregroundStyle(accent.b)
                Text("\(rows.count)")
                    .font(Fonts.mono(10))
                    .foregroundStyle(look.textMute)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().overlay(look.line)
            VStack(spacing: 0) {
                ForEach(rows) { task in
                    taskRow(task)
                }
            }
            .padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1))
    }

    private func taskRow(_ task: OptimizeStore.TaskRow) -> some View {
        let checked = store.checked.contains(task.id)
        return HStack(spacing: 11) {
            OptimizeCheckBox(checked: checked, accent: accent, look: look, size: 18) {
                store.toggle(task)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(Fonts.ui(12.5, .medium))
                    .foregroundStyle(checked ? look.text : look.textDim)
                Text(task.desc)
                    .font(Fonts.ui(11))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(task.id)
                .font(Fonts.mono(9.5))
                .foregroundStyle(look.textMute.opacity(0.7))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(task) }
        .pointingCursor()
    }

    private var listBar: some View {
        HStack(spacing: 10) {
            Text(L("optimize.bar.note"))
                .font(Fonts.ui(11.5))
                .foregroundStyle(look.textMute)
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
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .disabled(store.checked.isEmpty)
            .opacity(store.checked.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .padding(.top, 12)
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
            statusTrailing(state)
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

    @ViewBuilder
    private func statusTrailing(_ state: OptimizeStore.TaskState) -> some View {
        switch state {
        case let .done(ms?):
            Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "<1s")
                .font(Fonts.mono(10.5))
                .foregroundStyle(look.textMute)
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
