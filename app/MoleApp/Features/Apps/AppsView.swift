import MoleKit
import SwiftUI

/// 软件页（设计 §5.2，UI 规格页面 3）。
/// 三个子 tab：卸载 / 更新 / 启动项。
struct AppsView: View {
    var body: some View {
        PagePlaceholder(title: "软件", designRef: "§5.2")
        // TODO(Phase 1): 卸载 tab 只读列表（robot apps list）
        // TODO(Phase 2): 卸载 plan/apply；Phase 3: 启动项；Phase 5+: 更新
    }
}
