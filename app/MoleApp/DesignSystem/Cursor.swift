import AppKit
import SwiftUI

extension View {
    /// 可点元素 hover 显示小手光标。macOS 不像 Web 有全局链接光标，
    /// 需要在每个自定义可点组件上显式声明（导航 tab、进程行、段控等）。
    func pointingCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
