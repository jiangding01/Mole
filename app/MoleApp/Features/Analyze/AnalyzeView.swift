import MoleKit
import SwiftUI

/// 分析页（设计 §5.4 / 设计稿 analyze 页）：
/// 面包屑（任意层级可跳）+ 左栏完整子项列表 + Squarified Treemap（小项聚合）。
/// 下钻命中会话缓存秒回；刷新按钮强制重扫；纯只读（删除走 robot，M2）。
struct AnalyzeView: View {
    @State private var store = AnalyzeStore()
    private let look = Look.ink
    private let accent = ModuleAccent.analyze

    var body: some View {
        VStack(spacing: 12) {
            header
            content
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onAppear { store.startIfNeeded() }
    }

    // MARK: - 顶部：面包屑 + 状态区

    private var header: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer()
            if store.phase == .scanning {
                HStack(spacing: 7) {
                    RingSpinner(accent: accent, size: 14, lineWidth: 2)
                    if let progress = store.progress {
                        Text(L("analyze.progress", fmt(progress.bytes)))
                            .font(Fonts.mono(11))
                            .foregroundStyle(look.textMute)
                            .contentTransition(.numericText())
                    }
                }
            } else {
                Text(L("analyze.header.total", fmt(store.totalSize)))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
                if store.canRescan {
                    Button {
                        store.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(look.textDim)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(look.chrome))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(look.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .help(L("analyze.rescan.help"))
                }
            }
        }
    }

    /// 面包屑：首段 home 图标；过深时中间折叠为 … 下拉。
    private var breadcrumb: some View {
        let indexed = Array(store.crumbs.enumerated())
        let collapse = indexed.count > 5
        let middle = collapse ? Array(indexed.dropFirst().dropLast(2)) : []
        return HStack(spacing: 4) {
            ForEach(indexed, id: \.element.id) { index, crumb in
                if collapse, index == 1 {
                    collapsedMenu(middle)
                    chevron
                } else if !collapse || index == 0 || index >= indexed.count - 2 {
                    crumbButton(crumb, index: index, isFirst: index == 0, isLast: index == indexed.count - 1)
                    if index < indexed.count - 1 { chevron }
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(look.textMute)
    }

    private func crumbButton(_ crumb: AnalyzeStore.Crumb, index: Int, isFirst: Bool, isLast: Bool) -> some View {
        Button {
            store.jump(to: index)
        } label: {
            HStack(spacing: 4) {
                if isFirst {
                    Image(systemName: "house.fill").font(.system(size: 9))
                }
                Text(crumb.title)
                    .font(Fonts.ui(12.5, isLast ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isLast ? look.text : look.textDim)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(isLast ? look.chrome : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .disabled(isLast)
    }

    private func collapsedMenu(_ middle: [(offset: Int, element: AnalyzeStore.Crumb)]) -> some View {
        Menu {
            ForEach(middle, id: \.element.id) { index, crumb in
                Button(crumb.title) { store.jump(to: index) }
            }
        } label: {
            Text("…")
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingCursor()
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            Color.clear
        case let .failed(reason):
            failedView(reason)
        case .scanning, .loaded:
            HStack(alignment: .top, spacing: 14) {
                listPanel
                    .frame(width: 300)
                mainArea
            }
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        ZStack {
            if store.nodes.isEmpty, store.phase == .scanning {
                scanningPlaceholder
            } else {
                TreemapView(
                    nodes: store.nodes,
                    look: look,
                    accent: accent,
                    onDrill: { store.drill(into: $0) },
                    onAggregate: { store.openAggregate($0) },
                    onReveal: { store.reveal($0) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 13).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            RingSpinner(accent: accent, size: 44, lineWidth: 2.5)
            Text(L("analyze.scanning.title"))
                .font(Fonts.ui(13, .semibold))
                .foregroundStyle(look.textDim)
            if let progress = store.progress {
                Text((progress.current as NSString).abbreviatingWithTildeInPath)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(look.textMute)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
        }
    }

    // MARK: - 左栏：完整真实子项（不聚合）

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent.b)
                Text(L("analyze.list.summary", Int64(store.nodes.count), fmt(store.totalSize)))
                    .font(Fonts.mono(11))
                    .foregroundStyle(look.textDim)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().overlay(look.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.nodes) { node in
                        listRow(node)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(look.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func listRow(_ node: AnalyzeSession.Node) -> some View {
        let fraction = store.totalSize > 0 ? Double(max(0, node.size)) / Double(store.totalSize) : 0
        return HStack(spacing: 8) {
            Image(systemName: node.cleanable ? "sparkles" : (node.isDir ? "folder.fill" : "doc"))
                .font(.system(size: 10))
                .foregroundStyle(node.cleanable ? accent.b : look.textMute)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(look.line)
                        Capsule().fill(node.cleanable ? accent.b : accent.a.opacity(0.7))
                            .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: 3)
            }
            Spacer(minLength: 6)
            Text(fmt(node.size))
                .font(Fonts.mono(10.5))
                .foregroundStyle(look.textMute)
            if node.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(look.textMute)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDir { store.drill(into: node) } else { store.reveal(node) }
        }
        .contextMenu {
            Button(L("analyze.menu.reveal")) { store.reveal(node) }
            Button(L("analyze.menu.trash")) {}.disabled(true) // M2：经 robot 通道
        }
        .pointingCursor()
    }

    // MARK: - 失败

    private func failedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 30))
                .foregroundStyle(Semantic.warn)
            Text(L("analyze.failed.title"))
                .font(Fonts.ui(14, .semibold))
                .foregroundStyle(look.text)
            Text(reason)
                .font(Fonts.mono(11))
                .foregroundStyle(look.textMute)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L("common.retry")) { store.retry() }
                .buttonStyle(.plain)
                .pointingCursor()
                .font(Fonts.ui(12, .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(accent.gradient))
                .foregroundStyle(accent.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
