import Foundation

/// 顶部胶囊导航的六个主页面（设计 §8.1）。
/// 历史与设置不在枚举内：它们是导航胶囊右侧的独立图标入口。
enum MainTab: String, CaseIterable, Identifiable {
    case smartScan
    case clean
    case apps
    case optimize
    case analyze
    case status

    var id: String { rawValue }

    /// 骨架阶段直接返回中文；Phase 4 i18n 时迁入 String Catalog（设计 §8.5）。
    var title: String {
        switch self {
        case .smartScan: return "智能扫描"
        case .clean: return "清理"
        case .apps: return "软件"
        case .optimize: return "优化"
        case .analyze: return "分析"
        case .status: return "状态"
        }
    }
}
