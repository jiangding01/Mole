import MoleKit
import SwiftUI

/// 智能扫描首页（设计 §6.1，UI 规格页面 1）。
/// 状态机：idle → scanning → results（结论卡矩阵）。
/// 结果写入 ScanSession，供各模块 tab 直接消费（§5.0 跨页共享）。
struct SmartScanView: View {
    @Environment(ScanSession.self) private var scanSession

    var body: some View {
        PagePlaceholder(title: "智能扫描", designRef: "§6.1")
        // TODO(Phase 4): 光谱环 idle/scanning/donut 三态 + 结论卡矩阵
    }
}
