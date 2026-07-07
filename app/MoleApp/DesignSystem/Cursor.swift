import AppKit
import SwiftUI

extension View {
    /// 可点元素 hover 显示小手光标。
    ///
    /// 实现踩坑史（都在真机验证失败过，勿回退）：
    /// 1. onHover + NSCursor.push/pop —— SwiftUI 内部光标管理在鼠标移动时重置回箭头。
    /// 2. addCursorRect（resetCursorRects）—— SwiftUI 托管视图用自己的 tracking area
    ///    接管了光标更新，窗口 cursor rect 机制被绕过，同样不生效。
    /// 现方案：NSTrackingArea 直听 mouseMoved，每个事件都强制 set 光标——
    /// 无论谁把光标改回箭头，下一个移动事件立刻盖回小手。离开时恢复箭头。
    func pointingCursor() -> some View {
        overlay(CursorTrackingView(cursor: .pointingHand))
    }
}

private struct CursorTrackingView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        TrackingNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingNSView: NSView {
        let cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        // 只管光标，不参与命中测试——点击穿透到下层 SwiftUI 按钮
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
