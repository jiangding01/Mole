import MoleKit
import SwiftUI

/// 设置页（设计 §5.7）：通用/清理/权限/(菜单栏)/高级/(许可证)/关于。
/// 注意清理白名单与优化白名单是两套独立配置（robot whitelist --mode）。
struct SettingsView: View {
    var body: some View {
        PagePlaceholder(title: "设置", designRef: "§5.7")
            .frame(width: 640, height: 560)
    }
}
