import MoleKit
import SwiftUI

/// Squarified Treemap（设计 §5.4）：自绘布局 + 小项聚合。
/// 聚合是纯渲染决策（底层数据完整保留在左栏列表）：保留可读标签的大块，
/// 尾部合并为"N 项 · X GB"中性灰聚合块，点击进入子视图继续下钻。
enum TreemapLayout {
    /// 经典 squarified：值需降序；返回与输入等长的矩形数组。
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard !values.isEmpty, total > 0, rect.width > 1, rect.height > 1 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var result: [CGRect] = []
        var remaining = rect
        var index = 0
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            // 贪心成行：加入下一项会让最差长宽比变坏时封行
            var row: [Double] = []
            var best = Double.infinity
            var j = index
            while j < areas.count {
                row.append(areas[j])
                let worst = worstRatio(row, side)
                if worst > best {
                    row.removeLast()
                    break
                }
                best = worst
                j += 1
            }
            if row.isEmpty {
                row = [areas[index]]
            }
            let rowArea = row.reduce(0, +)
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            if remaining.width >= remaining.height {
                for area in row {
                    let height = CGFloat(area) / max(thickness, 0.001)
                    result.append(CGRect(x: remaining.minX, y: remaining.minY + offset,
                                         width: thickness, height: height))
                    offset += height
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: remaining.width - thickness, height: remaining.height)
            } else {
                for area in row {
                    let width = CGFloat(area) / max(thickness, 0.001)
                    result.append(CGRect(x: remaining.minX + offset, y: remaining.minY,
                                         width: width, height: thickness))
                    offset += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: remaining.height - thickness)
            }
            index += row.count
        }
        return result
    }

    private static func worstRatio(_ row: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else {
            return .infinity
        }
        let s2 = sum * sum
        let w2 = side * side
        return max(w2 * maxArea / s2, s2 / (w2 * minArea))
    }
}

/// 渲染块：真实节点或尾部聚合。
struct TreemapBlock: Identifiable {
    enum Kind {
        case node(AnalyzeSession.Node)
        case aggregate([AnalyzeSession.Node])
    }

    let id: String
    let kind: Kind
    let bytes: Int64
}

struct TreemapView: View {
    var nodes: [AnalyzeSession.Node] // 已按大小降序
    var look: Look
    var accent: ModuleAccent
    var onDrill: (AnalyzeSession.Node) -> Void
    var onAggregate: ([AnalyzeSession.Node]) -> Void
    var onReveal: (AnalyzeSession.Node) -> Void

    @State private var hoverId: String?

    var body: some View {
        GeometryReader { geo in
            let placed = placedBlocks(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(placed, id: \.block.id) { item in
                    blockView(item.block, rect: item.rect)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .offset(x: item.rect.minX, y: item.rect.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - 聚合 + 布局

    private func placedBlocks(in size: CGSize) -> [(block: TreemapBlock, rect: CGRect)] {
        let total = nodes.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard total > 0, size.width > 10, size.height > 10 else { return [] }

        // 聚合策略：块面积低于可读阈值（随视口自适应）或超出块数上限的尾部合并
        let viewport = Double(size.width * size.height)
        let minArea = max(3200.0, viewport * 0.004)
        var real: [AnalyzeSession.Node] = []
        var tail: [AnalyzeSession.Node] = []
        for (index, node) in nodes.enumerated() {
            let area = viewport * Double(max(0, node.size)) / Double(total)
            if (area >= minArea || index < 4) && real.count < 30 && node.size > 0 {
                real.append(node)
            } else {
                tail.append(node)
            }
        }

        var blocks: [TreemapBlock] = real.map {
            TreemapBlock(id: $0.path, kind: .node($0), bytes: max(1, $0.size))
        }
        let tailBytes = tail.reduce(Int64(0)) { $0 + max(0, $1.size) }
        if !tail.isEmpty, tailBytes > 0 {
            blocks.append(TreemapBlock(id: "__aggregate__", kind: .aggregate(tail), bytes: tailBytes))
        }
        guard !blocks.isEmpty else { return [] }

        let rects = TreemapLayout.layout(
            blocks.map { Double($0.bytes) },
            in: CGRect(origin: .zero, size: size)
        )
        return Array(zip(blocks, rects)).map { ($0.0, $0.1.insetBy(dx: 1.2, dy: 1.2)) }
    }

    // MARK: - 单块

    @ViewBuilder
    private func blockView(_ block: TreemapBlock, rect: CGRect) -> some View {
        let hovered = hoverId == block.id
        let showLabel = rect.width > 72 && rect.height > 40

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fillColor(block))
            if hovered {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.09))
            }
            if showLabel {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: symbol(block))
                            .font(.system(size: 9, weight: .semibold))
                        Text(title(block))
                            .font(Fonts.ui(11, .semibold))
                            .lineLimit(1)
                    }
                    Text(subtitle(block))
                        .font(Fonts.mono(9.5))
                        .opacity(0.75)
                }
                .foregroundStyle(labelColor(block))
                .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .help(tooltip(block))
        .shadow(color: .black.opacity(hovered ? 0.35 : 0), radius: 8, y: 2)
        .onHover { inside in hoverId = inside ? block.id : (hoverId == block.id ? nil : hoverId) }
        .onTapGesture { tap(block) }
        .contextMenu { menu(block) }
        .pointingCursor()
    }

    private func tap(_ block: TreemapBlock) {
        switch block.kind {
        case let .node(node):
            if node.isDir { onDrill(node) } else { onReveal(node) }
        case let .aggregate(nodes):
            onAggregate(nodes)
        }
    }

    @ViewBuilder
    private func menu(_ block: TreemapBlock) -> some View {
        if case let .node(node) = block.kind {
            Button(L("analyze.menu.reveal")) { onReveal(node) }
            Button(L("analyze.menu.trash")) {}.disabled(true) // M2：经 robot 通道
            if node.isDir {
                Button(L("analyze.menu.open")) { onDrill(node) }
            }
        } else if case let .aggregate(nodes) = block.kind {
            Button(L("analyze.menu.openAggregate", Int64(nodes.count))) { onAggregate(nodes) }
        }
    }

    // MARK: - 视觉

    private func fillColor(_ block: TreemapBlock) -> Color {
        switch block.kind {
        case let .node(node):
            if node.cleanable { return accent.b.opacity(0.55) }
            // 暖陶土深浅阶梯（按块 id 稳定散列，避免刷新跳色）
            let shades: [Double] = [0.78, 0.62, 0.5, 0.4, 0.32, 0.26]
            let index = abs(node.path.hashValue) % shades.count
            return accent.a.opacity(shades[index])
        case .aggregate:
            return Color.white.opacity(0.10) // 中性灰，区别于真实目录块
        }
    }

    private func labelColor(_ block: TreemapBlock) -> Color {
        if case .aggregate = block.kind { return look.textDim }
        return Color(hex: 0xF6EFE6)
    }

    private func symbol(_ block: TreemapBlock) -> String {
        switch block.kind {
        case let .node(node):
            if node.cleanable { return "sparkles" }
            return node.isDir ? "folder.fill" : "doc.fill"
        case .aggregate:
            return "square.grid.2x2"
        }
    }

    private func title(_ block: TreemapBlock) -> String {
        switch block.kind {
        case let .node(node): node.name
        case let .aggregate(nodes): L("analyze.aggregate.title", Int64(nodes.count))
        }
    }

    private func subtitle(_ block: TreemapBlock) -> String {
        ByteCountFormatter.string(fromByteCount: block.bytes, countStyle: .file)
    }

    private func tooltip(_ block: TreemapBlock) -> String {
        switch block.kind {
        case let .node(node):
            var parts = [node.path, subtitle(block)]
            if let access = node.lastAccess { parts.append(L("analyze.tooltip.access", access)) }
            return parts.joined(separator: "\n")
        case let .aggregate(nodes):
            return L("analyze.aggregate.tooltip", Int64(nodes.count), subtitle(block))
        }
    }
}
