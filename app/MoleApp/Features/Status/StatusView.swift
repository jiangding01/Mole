import MoleKit
import SwiftUI

/// 状态页（设计 §5.5，UI 规格页面 6）：8 卡固定区 + 进程表。
/// 数据源：status-go --watch --interval（现成 NDJSON 流）。
struct StatusView: View {
    var body: some View {
        PagePlaceholder(title: "状态", designRef: "§5.5")
        // TODO(Phase 1): MetricsSnapshot 订阅 + 卡片网格 + 进程表 + 详情弹窗(--proc)
    }
}
