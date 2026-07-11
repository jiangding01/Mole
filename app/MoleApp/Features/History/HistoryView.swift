import AppKit
import MoleKit
import SwiftUI

/// 历史页（设计 §5.6）：会话时间线 + 手风琴明细。只读——恢复由用户在废纸篓完成。
/// 数据来自 `mole robot history list`（operations.log 会话 + deletions.log 审计）。
struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let look = Look.ink
    /// 本页 accent 固定为灰褐（设计 THEMES.history），非品牌金。
    private let accent = ModuleAccent.history

    /// 入场动画（设计 pageIn：opacity 0→1 + translateY 5→0，0.28s ease）。
    @State private var appeared = false

    var body: some View {
        ZStack {
            look.background(accent: accent)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 5)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) { appeared = true }
            }
            Task { await store.load() }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("history.title"))
                .font(Fonts.serif(28))
                .lineSpacing(0)
                .foregroundStyle(look.text)
            Text(L("history.subtitle"))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
        }
        .padding(.bottom, 18)
    }

    // MARK: - 主体（按 Phase 分支）

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            centered {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text(L("history.loading"))
                        .font(Fonts.ui(12.5))
                        .foregroundStyle(look.textMute)
                }
            }
        case let .failed(message):
            centered {
                VStack(spacing: 12) {
                    Text(L("history.failed"))
                        .font(Fonts.ui(12.5))
                        .foregroundStyle(look.textDim)
                    Button {
                        Task { await store.load() }
                    } label: {
                        Text(L("history.retry"))
                            .font(Fonts.ui(12.5, .medium))
                            .foregroundStyle(accent.a)
                    }
                    .buttonStyle(.plain)
                    .pointingCursor()
                    .help(message)
                }
            }
        case .loaded:
            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
    }

    private func centered(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(accent.a.opacity(0.08))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 50, weight: .thin))
                    .foregroundStyle(accent.a)
            }
            .frame(width: 110, height: 110)
            .padding(.bottom, 22)

            Text(L("history.empty.title"))
                .font(Fonts.serif(24))
                .foregroundStyle(look.text)
            Text(L("history.empty.desc"))
                .font(Fonts.ui(13.5))
                .foregroundStyle(look.textDim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 会话列表

    private var sessionList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 10) {
                ForEach(store.sessions) { session in
                    HistoryCard(
                        session: session,
                        isOpen: store.openSessionId == session.id,
                        onToggle: {
                            withAnimation(.easeOut(duration: 0.2)) { store.toggle(session.id) }
                        }
                    )
                }
            }
            .padding(.trailing, 6)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 会话卡

private struct HistoryCard: View {
    let session: HistorySession
    let isOpen: Bool
    let onToggle: () -> Void

    private let look = Look.ink
    private let accent = ModuleAccent.history
    @State private var headerHover = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isOpen {
                detail
                    .transition(.opacity)
            }
        }
        .background(look.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.line, lineWidth: 1))
    }

    // MARK: 头部行（可点击，单开手风琴）

    private var headerRow: some View {
        HStack(spacing: 14) {
            iconBox
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(HistoryFormat.title(for: session.command))
                        .font(Fonts.ui(14, .semibold))
                        .foregroundStyle(look.text)
                    Text(verbatim: HistoryFormat.dateTime(session.endedAt))
                        .font(Fonts.mono(11))
                        .foregroundStyle(look.textMute)
                }
                secondLine
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(look.textMute)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .animation(.easeOut(duration: 0.2), value: isOpen)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .background(headerHover ? look.text.opacity(0.02) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { headerHover = $0 }
        .pointingCursor()
    }

    private var secondLine: some View {
        HStack(spacing: 0) {
            if session.freedBytes > 0 {
                Text(L("history.freed", HistoryFormat.freedGB(session.freedBytes)))
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(accent.a)
            } else {
                Text(L("history.completed"))
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(accent.a)
            }
            Text(verbatim: " · ")
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
            Text(L("history.count", Int64(session.itemCount)))
                .font(Fonts.ui(12.5))
                .foregroundStyle(look.textDim)
        }
    }

    private var iconBox: some View {
        let kind = HistoryFormat.kind(for: session.command)
        return RoundedRectangle(cornerRadius: 11)
            .fill(kind.boxBackground)
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(kind.iconColor)
            )
    }

    // MARK: 展开明细

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(look.line)
            VStack(alignment: .leading, spacing: 0) {
                if session.deletions.isEmpty {
                    // 该会话无逐项审计（deletions.log 未记录本次运行明细）。
                    // 只读诚实：不谎报「已移入废纸篓」，改示中性说明。
                    Text(L("history.noDetail"))
                        .font(Fonts.ui(12.5))
                        .lineSpacing(5)
                        .foregroundStyle(look.textDim)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 2)
                } else {
                    ForEach(session.deletions) { deletion in
                        DeletionRow(deletion: deletion)
                    }
                    recoverHint
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 17)
            .padding(.bottom, 14)
        }
    }

    private var recoverHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Semantic.success)
            Text(L("history.recoverable"))
                .font(Fonts.ui(12))
                .foregroundStyle(look.textMute)
        }
        .padding(.top, 12)
    }
}

// MARK: - 明细行

private struct DeletionRow: View {
    let deletion: HistoryDeletion

    private let look = Look.ink
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(look.textMute)

            Text(verbatim: deletion.path)
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textDim)
                .lineLimit(1)
                // 尾部优先截断，保住文件名端（对应设计 direction:rtl）。
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: HistoryFormat.size(deletion.bytes))
                .font(Fonts.mono(11.5))
                .foregroundStyle(look.textMute)

            HStack(spacing: 4) {
                ActionButton(symbol: "trash", help: L("history.action.reveal")) {
                    revealTrash()
                }
                ActionButton(symbol: "doc.on.doc", help: L("history.action.copy")) {
                    copyPath()
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
        .background(hover ? look.text.opacity(0.015) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(look.text.opacity(0.03)).frame(height: 1)
        }
        .onHover { hover = $0 }
    }

    /// 「在废纸篓中显示」：文件进废纸篓后原路径已失效，v1 直接打开废纸篓目录
    /// （无法逐项定位到废纸篓内的具体条目，故打开目录让用户自行查找/恢复）。
    private func revealTrash() {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        NSWorkspace.shared.open(trash)
    }

    private func copyPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(deletion.path, forType: .string)
    }
}

// MARK: - 操作钮（26×26 圆角 7，hover 高亮）

private struct ActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    private let look = Look.ink
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7)
                .fill(hover ? look.text.opacity(0.06) : .clear)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(hover ? look.text : look.textMute)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pointingCursor()
        .help(help)
    }
}

// MARK: - 格式化与 kind 映射

private enum HistoryFormat {
    enum Kind {
        case clean, apps, optimize

        var symbol: String {
            switch self {
            case .clean: "trash"
            case .apps: "square.grid.2x2"
            case .optimize: "wrench.adjustable"
            }
        }

        var boxBackground: Color {
            switch self {
            case .clean: Color(hex: 0x46A588).opacity(0.14)
            case .apps: ModuleAccent.apps.a.opacity(0.16)
            case .optimize: Color(hex: 0xC0803A).opacity(0.16)
            }
        }

        var iconColor: Color {
            switch self {
            case .clean: Semantic.success
            case .apps: ModuleAccent.apps.b
            case .optimize: Semantic.warnAlt
            }
        }
    }

    /// 命令 → 图标 kind（purge 复用 clean 图标；其它一律 clean 兜底）。
    static func kind(for command: String) -> Kind {
        switch command {
        case "uninstall": .apps
        case "optimize": .optimize
        default: .clean // clean / purge / 未知
        }
    }

    /// 命令 → 卡片标题（日志无 app 名，卸载只显示「卸载」）。
    static func title(for command: String) -> String {
        switch command {
        case "clean": L("history.kind.clean")
        case "uninstall": L("history.kind.uninstall")
        case "optimize": L("history.kind.optimize")
        case "purge": L("history.kind.purge")
        default: L("history.kind.clean")
        }
    }

    /// 释放量 → GB 数字串（避免正值显示 "0.0"：<1 用两位小数）。
    static func freedGB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f", gb) }
        if gb >= 1 { return String(format: "%.1f", gb) }
        return String(format: "%.2f", gb)
    }

    /// 删除大小：0 视为未知 → "—"；≥1024MB 两位小数 GB，否则整数 MB（设计规格）。
    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }

    /// 日期 + 时间：中文 "M月d日 HH:mm"，英文 "MMM d HH:mm"（本地时区）。
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        if L10n.shared.isChinese {
            f.locale = Locale(identifier: "zh_Hans")
            f.dateFormat = "M月d日 HH:mm"
        } else {
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMM d HH:mm"
        }
        return f.string(from: date)
    }
}
