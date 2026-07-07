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

    /// 文案走 String Catalog（设计 §8.5）；语言切换由 L10n 驱动即时刷新。
    var title: String {
        switch self {
        case .smartScan: return L("nav.smartScan")
        case .clean: return L("nav.clean")
        case .apps: return L("nav.apps")
        case .optimize: return L("nav.optimize")
        case .analyze: return L("nav.analyze")
        case .status: return L("nav.status")
        }
    }
}
