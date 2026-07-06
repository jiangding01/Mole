import MoleKit
import SwiftUI

/// 历史页（设计 §5.6）：会话时间线 + 展开明细（operations/deletions 双日志）。
struct HistoryView: View {
    var body: some View {
        PagePlaceholder(title: "历史", designRef: "§5.6")
            .frame(width: 720, height: 520)
        // TODO(Phase 2): robot history list --json；v1.1: 结构化恢复
    }
}
