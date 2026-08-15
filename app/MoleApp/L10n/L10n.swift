import Foundation
import Observation

/// 应用内语言层（设计 §8.5）。
///
/// - 资源：`Localizable.xcstrings`（key 采用 `feature.semantic` 命名）
/// - 产品规则：默认跟随系统——**仅当系统首选语言为简体中文（zh-Hans*）时显示中文，
///   其余一律英文**（含繁体中文）；后续语言在 catalog 加列即可，零架构改造
/// - 设置可覆盖为 自动 / 简体中文 / English；运行时切换免重启
///   （自定义 lproj bundle 查表，@Observable 驱动全 UI 即时刷新）
@Observable
final class L10n {
    static let shared = L10n()

    enum Language: String, CaseIterable {
        case system
        case zhHans = "zh-Hans"
        case english = "en"

        var label: String {
            switch self {
            case .system: "自动 / Auto"
            case .zhHans: "简体中文"
            case .english: "English"
            }
        }
    }

    var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            reloadBundle()
        }
    }

    private static let defaultsKey = "mole.language"
    private var bundle: Bundle = .main

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        language = Language(rawValue: stored) ?? .system
        reloadBundle()
    }

    /// 语言解析（产品规则见类型注释）。
    var isChinese: Bool {
        switch language {
        case .zhHans: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true
        }
    }

    private func reloadBundle() {
        let code = isChinese ? "zh-Hans" : "en"
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } else {
            bundle = .main // 开发期 catalog 未编译时兜底：显示 key
        }
    }

    func string(_ key: String) -> String {
        _ = language // 注册观察：语言变化时所有读取过文案的视图自动重渲
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 键不存在时返回 nil（string() 的回退语义是"显示 key"，
    /// 对动态拼接的键——如 optimize.task.<id>.result——需要可探测的缺失）。
    func optionalString(_ key: String) -> String? {
        _ = language
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        return value == "\u{0}" ? nil : value
    }
}

/// 全局便捷函数：`L("apps.tab.uninstall")`。
func L(_ key: String) -> String {
    L10n.shared.string(key)
}

/// 带插值：`L("apps.header.count", Int64(n))`。整数一律传 Int64 配 %lld。
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.shared.string(key), arguments: args)
}

/// 键可能不存在的动态查表（如 `optimize.task.<id>.result`）：缺失返回 nil。
func LOpt(_ key: String) -> String? {
    L10n.shared.optionalString(key)
}
