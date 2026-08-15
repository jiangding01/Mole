import SwiftUI

@main
struct MoleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
        }
        // 设计 §8.1：隐藏标题栏、内容延伸到窗口顶部，保留红黄绿灯
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("settings.advanced.diagnostics.menu")) {
                    // 跨层触发（App 菜单 → 设置·高级 sheet + 自动导出）：
                    // RootView 打开设置 sheet，SettingsView.onAppear 消费一次性信号并
                    // 直接开始导出（比 NotificationCenter 双端订阅时序更简单可靠）。
                    DiagnosticsMenuBridge.pendingAutoExport = true
                    NotificationCenter.default.post(name: .moleOpenSettings, object: nil)
                }
            }
        }
    }
}

/// 菜单栏「运行诊断」→ 设置页 onAppear 消费的一次性信号（设计 CHANGELOG §3.2）。
enum DiagnosticsMenuBridge {
    static var pendingAutoExport = false
}

extension Notification.Name {
    /// 菜单命令请求打开设置 sheet（RootView 订阅并翻转 `showsSettings`）。
    static let moleOpenSettings = Notification.Name("mole.openSettings")
}
