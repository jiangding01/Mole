import Foundation

/// 知名路径 → 语义名映射（r3 §P2）。
///
/// 规则：只命名**位置本身能证明用途**的知名路径（DerivedData 就是构建缓存、
/// `_cacache` 就是 npm 缓存）；映射不到的返回 nil，行内回退纯路径单行——
/// **绝不编造名称**。协议 label 目前与 path 同值（见 contracts/robot_v1），
/// 语义名是纯 GUI 展示层，不进协议、不影响 plan/apply。
///
/// 匹配输入是 `abbreviatingWithTildeInPath` 后的路径（`~/Library/...`），
/// 与用户无关、与展示层同源。表序即优先级：具体规则在前（ModuleCache
/// 先于 DerivedData），首中即返回。中英文按应用语言层（L10n）取值。
enum CleanPathNames {
    static func semanticName(forAbbreviatedPath path: String) -> String? {
        for rule in rules {
            let hit = switch rule.match {
            case let .prefix(p): path.hasPrefix(p)
            case let .contains(s): path.contains(s)
            }
            if hit { return L10n.shared.isChinese ? rule.zh : rule.en }
        }
        return nil
    }

    private struct Rule {
        let match: Match
        let zh: String
        let en: String
    }

    private enum Match {
        case prefix(String)
        case contains(String)
    }

    /// 约 50 类知名路径。`contains` 仅用于位置可变的 profile 型路径
    /// （Caches 与 Application Support 两处都会出现），其余一律前缀锚定。
    private static let rules: [Rule] = [
        // Xcode / Apple 开发链（具体在前）
        .init(match: .prefix("~/Library/Developer/Xcode/DerivedData/ModuleCache"),
              zh: "Xcode 模块缓存", en: "Xcode module cache"),
        .init(match: .prefix("~/Library/Developer/Xcode/DerivedData"),
              zh: "Xcode 构建缓存（DerivedData）", en: "Xcode DerivedData"),
        .init(match: .prefix("~/Library/Developer/Xcode/Archives"),
              zh: "Xcode 归档", en: "Xcode archives"),
        .init(match: .prefix("~/Library/Developer/Xcode/iOS DeviceSupport"),
              zh: "iOS 设备支持文件", en: "iOS device support"),
        .init(match: .prefix("~/Library/Developer/Xcode/watchOS DeviceSupport"),
              zh: "watchOS 设备支持文件", en: "watchOS device support"),
        .init(match: .prefix("~/Library/Developer/CoreSimulator/Caches"),
              zh: "模拟器缓存", en: "Simulator caches"),
        .init(match: .prefix("~/Library/Developer/CoreSimulator/Devices"),
              zh: "模拟器设备数据", en: "Simulator devices"),
        .init(match: .prefix("~/Library/Caches/com.apple.dt.Xcode"),
              zh: "Xcode 缓存", en: "Xcode cache"),
        .init(match: .prefix("~/Library/Caches/org.swift.swiftpm"),
              zh: "Swift 包管理器缓存", en: "Swift Package Manager cache"),

        // JS / Node 工具链
        .init(match: .prefix("~/.npm/_cacache"), zh: "npm 缓存", en: "npm cache"),
        .init(match: .prefix("~/.npm/_npx"), zh: "npx 缓存", en: "npx cache"),
        .init(match: .prefix("~/Library/pnpm"), zh: "pnpm 存储", en: "pnpm store"),
        .init(match: .prefix("~/.pnpm-store"), zh: "pnpm 存储", en: "pnpm store"),
        .init(match: .prefix("~/Library/Caches/Yarn"), zh: "Yarn 缓存", en: "Yarn cache"),
        .init(match: .prefix("~/.yarn/cache"), zh: "Yarn 缓存", en: "Yarn cache"),
        .init(match: .prefix("~/.bun/install/cache"), zh: "Bun 缓存", en: "Bun cache"),
        .init(match: .prefix("~/Library/Caches/deno"), zh: "Deno 缓存", en: "Deno cache"),
        .init(match: .prefix("~/Library/Caches/node-gyp"),
              zh: "node-gyp 构建缓存", en: "node-gyp build cache"),
        .init(match: .prefix("~/Library/Caches/electron"),
              zh: "Electron 缓存", en: "Electron cache"),
        .init(match: .prefix("~/Library/Caches/ms-playwright"),
              zh: "Playwright 浏览器缓存", en: "Playwright browsers"),
        .init(match: .prefix("~/Library/Caches/Cypress"),
              zh: "Cypress 缓存", en: "Cypress cache"),

        // 其它语言工具链
        .init(match: .prefix("~/.cargo/registry"),
              zh: "Cargo 注册表缓存", en: "Cargo registry cache"),
        .init(match: .prefix("~/.cargo/git"), zh: "Cargo Git 缓存", en: "Cargo git cache"),
        .init(match: .prefix("~/Library/Caches/go-build"),
              zh: "Go 构建缓存", en: "Go build cache"),
        .init(match: .prefix("~/go/pkg/mod/cache"), zh: "Go 模块缓存", en: "Go module cache"),
        .init(match: .prefix("~/Library/Caches/pip"), zh: "pip 缓存", en: "pip cache"),
        .init(match: .prefix("~/.cache/pip"), zh: "pip 缓存", en: "pip cache"),
        .init(match: .prefix("~/Library/Caches/uv"), zh: "uv 缓存", en: "uv cache"),
        .init(match: .prefix("~/Library/Caches/pypoetry"),
              zh: "Poetry 缓存", en: "Poetry cache"),
        .init(match: .prefix("~/.gradle/caches"), zh: "Gradle 缓存", en: "Gradle caches"),
        .init(match: .prefix("~/.m2/repository"),
              zh: "Maven 本地仓库", en: "Maven local repository"),
        .init(match: .prefix("~/Library/Caches/CocoaPods"),
              zh: "CocoaPods 缓存", en: "CocoaPods cache"),
        .init(match: .prefix("~/Library/Caches/Homebrew"),
              zh: "Homebrew 下载缓存", en: "Homebrew downloads"),
        .init(match: .prefix("~/.composer/cache"), zh: "Composer 缓存", en: "Composer cache"),

        // 浏览器（profile 路径在 Caches 与 Application Support 两处出现）。
        // Service Worker 两条须在泛浏览器规则之前：聚合锚点上提后的父行
        // 与散列子行都命中这里，得到比"Chrome 缓存"更准确的名字。
        .init(match: .contains("/Service Worker/CacheStorage"),
              zh: "Service Worker 缓存", en: "Service Worker cache"),
        .init(match: .contains("/Service Worker/ScriptCache"),
              zh: "Service Worker 脚本缓存", en: "Service Worker script cache"),
        .init(match: .contains("/Google/Chrome"), zh: "Chrome 缓存", en: "Chrome cache"),
        .init(match: .contains("/Microsoft Edge"), zh: "Edge 缓存", en: "Edge cache"),
        .init(match: .contains("/BraveSoftware"), zh: "Brave 缓存", en: "Brave cache"),
        .init(match: .contains("/Firefox/Profiles"), zh: "Firefox 缓存", en: "Firefox cache"),
        .init(match: .contains("/company.thebrowser.Browser"), zh: "Arc 缓存", en: "Arc cache"),
        .init(match: .contains("/Arc/User Data"), zh: "Arc 缓存", en: "Arc cache"),
        .init(match: .contains("/com.operasoftware"), zh: "Opera 缓存", en: "Opera cache"),
        .init(match: .contains("/Vivaldi"), zh: "Vivaldi 缓存", en: "Vivaldi cache"),

        // 编辑器 / IDE
        .init(match: .contains("/Application Support/Code/Cache"),
              zh: "VS Code 缓存", en: "VS Code cache"),
        .init(match: .contains("/Application Support/Code/Code Cache"),
              zh: "VS Code 缓存", en: "VS Code cache"),
        .init(match: .prefix("~/Library/Caches/com.microsoft.VSCode"),
              zh: "VS Code 缓存", en: "VS Code cache"),
        .init(match: .contains("/Application Support/Cursor/Cache"),
              zh: "Cursor 缓存", en: "Cursor cache"),
        .init(match: .contains("/JetBrains"), zh: "JetBrains 缓存", en: "JetBrains caches"),
        .init(match: .prefix("~/Library/Caches/dev.zed.Zed"), zh: "Zed 缓存", en: "Zed cache"),

        // 常见应用（bundle id 锚定，避免误伤用户数据目录）
        .init(match: .contains("/com.tencent.xinWeChat"), zh: "微信缓存", en: "WeChat cache"),
        .init(match: .contains("/com.tencent.QQMusicMac"),
              zh: "QQ 音乐缓存", en: "QQ Music cache"),
        .init(match: .contains("/com.alibaba.DingTalk"), zh: "钉钉缓存", en: "DingTalk cache"),
        .init(match: .contains("/com.netease.163music"),
              zh: "网易云音乐缓存", en: "NetEase Music cache"),
        .init(match: .contains("/Application Support/Slack/Cache"),
              zh: "Slack 缓存", en: "Slack cache"),
        .init(match: .contains("/Application Support/Slack/Service Worker"),
              zh: "Slack 缓存", en: "Slack cache"),
        .init(match: .prefix("~/Library/Caches/com.tinyspeck.slackmacgap"),
              zh: "Slack 缓存", en: "Slack cache"),
        .init(match: .contains("/Application Support/discord/Cache"),
              zh: "Discord 缓存", en: "Discord cache"),
        .init(match: .contains("/Telegram"), zh: "Telegram 缓存", en: "Telegram cache"),
        .init(match: .contains("/zoom.us"), zh: "Zoom 缓存", en: "Zoom cache"),
        .init(match: .contains("/com.spotify.client"), zh: "Spotify 缓存", en: "Spotify cache"),
        .init(match: .contains("/com.kingsoft.wpsoffice"), zh: "WPS 缓存", en: "WPS cache"),
        .init(match: .contains("/com.baidu.netdisk"),
              zh: "百度网盘缓存", en: "Baidu Netdisk cache"),
        .init(match: .prefix("~/Library/Caches/com.getdropbox.dropbox"),
              zh: "Dropbox 缓存", en: "Dropbox cache"),
        .init(match: .prefix("~/Library/Caches/com.microsoft.OneDrive"),
              zh: "OneDrive 缓存", en: "OneDrive cache"),

        // 系统侧个人域
        .init(match: .prefix("~/Library/Caches/CloudKit"),
              zh: "CloudKit 缓存", en: "CloudKit cache"),
        .init(match: .prefix("~/Library/Logs/DiagnosticReports"),
              zh: "诊断报告", en: "Diagnostic reports"),
        .init(match: .prefix("~/Library/Application Support/CrashReporter"),
              zh: "崩溃报告", en: "Crash reports"),
    ]
}
