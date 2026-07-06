import MoleKit
import SwiftUI

/// 首启引导（设计 §5.8）：三步——产品承诺 / FDA 授权 / 可选 helper。
struct OnboardingView: View {
    var body: some View {
        PagePlaceholder(title: "欢迎使用 Mole", designRef: "§5.8")
        // TODO(Phase 1): FDA 轮询检测（MoleKit PermissionProbe）
    }
}
