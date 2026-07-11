import Observation
import SwiftUI

/// 会话级导航路由（设计 §5.0 跨页跳转）。
///
/// 顶部胶囊、wordmark 与智能扫描结论卡都通过它切页；`go(_:)` 内建
/// 与胶囊 matchedGeometry 一致的弹性动画，保证任意入口切换观感统一。
/// 历史/设置是胶囊右侧独立图标入口，不在此路由（沿用 RootView 的 sheet）。
@Observable
@MainActor
final class Router {
    var tab: MainTab = .smartScan

    /// 带动画切页；智能页结论卡与导航胶囊共用此入口，动画上下文一致。
    func go(_ tab: MainTab) {
        withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
            self.tab = tab
        }
    }
}
