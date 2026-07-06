import MoleKit
import SwiftUI

/// 清理页（设计 §5.1，UI 规格页面 2）。
/// 三个子 tab：快速清理 / 项目产物 / 安装包；共享 §5.0 状态机。
/// review 态需兼容"从智能扫描带结果进入"与"本页扫描后进入"两种来路。
struct CleanView: View {
    @Environment(ScanSession.self) private var scanSession

    var body: some View {
        PagePlaceholder(title: "清理", designRef: "§5.1")
        // TODO(Phase 2/3): plan/apply 全交互、分类卡片、分阶段执行日志、外置卷入口
    }
}
