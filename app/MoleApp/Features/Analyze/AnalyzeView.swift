import MoleKit
import SwiftUI

/// 分析页（设计 §5.4 / 设计稿 analyze 页）：
/// 面包屑 + 右侧状态区（当前总量 · 磁盘用量 · 重新扫描）；左栏两行式列表
/// （大小/名称排序、cleanable 绿扳手、hover 与 treemap 双向联动）；
/// 主区 Squarified Treemap（居中标签 + 小项聚合）。
/// 扫描态 = 旧内容模糊压暗 + 居中环形加载覆盖层（设计稿 SCANNING）。
struct AnalyzeView: View {
    @Environment(AnalyzeStore.self) private var store
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
                // 设计稿：细进度线 + 实时总量
                Capsule()
                    .fill(accent.gradient)
                    .frame(width: 120, height: 3)
                Text(L("analyze.header.current", fmt(store.progress?.bytes ?? store.totalSize)))
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textDim)
                    .contentTransition(.numericText())
            } else {
                Text(headerSummary)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(look.textMute)
                if store.canRescan {
                    Button {
                        store.rescan()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text(L("analyze.rescan"))
                        }
                        .font(Fonts.ui(12, .semibold))
                        .foregroundStyle(look.textDim)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Capsule().fill(look.chrome))
                        .overlay(Capsule().stroke(look.line, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingCursor()
                }
            }
        }
    }

    private var headerSummary: String {
        var parts = [L("analyze.header.current", fmt(store.totalSize))]
        if let disk = store.diskUsage {
            parts.append(L("analyze.header.disk", fmtGBOnly(disk.used), fmt(disk.total)))
        }
        return parts.joined(separator: " · ")
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
                    Image(systemName: "house").font(.system(size: 10))
                }
                Text(crumb.title)
                    .font(Fonts.ui(13, isLast ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isLast ? look.text : look.textDim)
            .padding(.horizontal, 7).padding(.vertical, 4)
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

    // MARK: - 主体（扫描态 = 模糊压暗 + 覆盖层）

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            Color.clear
        case let .failed(reason):
            failedView(reason)
        case .scanning, .loaded:
            explorer
                .blur(radius: store.phase == .scanning ? 6 : 0)
                .opacity(store.phase == .scanning ? 0.45 : 1)
                .allowsHitTesting(store.phase != .scanning)
                .overlay {
                    if store.phase == .scanning { scanningOverlay }
                }
                .animation(.easeOut(duration: 0.25), value: store.phase == .scanning)
        }
    }

    private var explorer: some View {
        HStack(alignment: .top, spacing: 18) {
            listPanel
                .frame(width: 300)
            TreemapView(
                nodes: store.nodes,
                look: look,
                accent: accent,
                hoverId: Binding(get: { store.hoveredPath }, set: { store.hoveredPath = $0 }),
                onDrill: { store.drill(into: $0) },
                onAggregate: { store.openAggregate($0) },
                onReveal: { store.reveal($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 扫描覆盖层（设计稿 SCANNING）：环形加载 + 文件夹图标 + 目标目录名。
    private var scanningOverlay: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(look.line, lineWidth: 2)
                    .frame(width: 88, height: 88)
                RingSpinner(accent: accent, size: 88, lineWidth: 2)
                Image(systemName: "folder")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(accent.b)
            }
            Fonts.eyebrow("Scanning", size: 11)
                .foregroundStyle(look.textMute)
                .padding(.top, 24)
            HStack(spacing: 8) {
                Text(L("analyze.scanning.prefix"))
                    .font(Fonts.serif(22, .semibold))
                    .foregroundStyle(look.text)
                Text(store.scanningTitle)
                    .font(Fonts.mono(19, .medium))
                    .foregroundStyle(accent.b)
                    .lineLimit(1)
            }
            .padding(.top, 10)
            Text(L("analyze.scanning.sub", Int64(store.nodes.count)))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 左栏（设计稿两行式：名称 / 大小·占比，hover 联动 treemap）

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("analyze.list.header", Int64(store.nodes.count)))
                    .font(Fonts.ui(12))
                    .foregroundStyle(look.textMute)
                Spacer()
                sortToggle(L("analyze.sort.size"), .size)
                sortToggle(L("analyze.sort.name"), .name)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.listNodes) { node in
                        listRow(node)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func sortToggle(_ label: String, _ sort: AnalyzeStore.ListSort) -> some View {
        Button {
            store.listSort = sort
        } label: {
            Text(label)
                .font(Fonts.ui(12, store.listSort == sort ? .semibold : .regular))
                .foregroundStyle(store.listSort == sort ? accent.b : look.textMute)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private func listRow(_ node: AnalyzeSession.Node) -> some View {
        let hovered = store.hoveredPath == node.path
        let fraction = store.totalSize > 0 ? Double(max(0, node.size)) / Double(store.totalSize) : 0
        return HStack(spacing: 10) {
            Image(systemName: node.cleanable ? "wrench.adjustable" : (node.isDir ? "folder" : "doc"))
                .font(.system(size: 12))
                .foregroundStyle(node.cleanable ? Semantic.success : look.textMute)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(Fonts.ui(13, .medium))
                    .foregroundStyle(look.text)
                    .lineLimit(1)
                Text("\(fmt(node.size)) · \(Int((fraction * 100).rounded()))%")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(look.textMute)
            }
            Spacer(minLength: 6)
            if node.isDir, hovered {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(look.textDim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovered ? look.chrome : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDir { store.drill(into: node) } else { store.reveal(node) }
        }
        .onHover { inside in
            // 与 treemap 共享焦点：列表 hover → 对应色块高亮（反向亦然）
            store.hoveredPath = inside ? node.path : (store.hoveredPath == node.path ? nil : store.hoveredPath)
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

    /// 磁盘行"481 / 494 GB"里前一个数字不带单位。
    private func fmtGBOnly(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000_000)
    }
}
