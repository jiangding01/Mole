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
    }
}
