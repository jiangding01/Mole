import AppKit
import SwiftUI

extension View {
    /// 可点元素 hover 显示小手光标。
    /// 注意：不能用 onHover + NSCursor.push/pop——SwiftUI 的内部光标管理会在
    /// 鼠标移动时把它重置回箭头（macOS 14 上几乎必现）。这里走 AppKit 的
    /// cursor rect 机制：透明 NSView 覆盖在元素上声明光标区域，由窗口统一
    /// 维护；hitTest 返回 nil 保证点击穿透到下层 SwiftUI 控件。
    func pointingCursor() -> some View {
        overlay(CursorRectView(cursor: .pointingHand))
    }
}

private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        PassthroughCursorView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    private final class PassthroughCursorView: NSView {
        let cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        // 只声明光标，不参与命中测试——点击落到下层 SwiftUI 按钮上
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
