import SwiftUI

/// 骨架阶段的页面占位。每个 Feature 落地时删除对应使用处。
struct PagePlaceholder: View {
    let title: String
    let designRef: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(title)
                .font(.system(size: 28, weight: .semibold))
            // verbatim：开发期占位文案，不进 String Catalog（避免 Xcode 自动抽取）
            Text(verbatim: "规格见 docs/MAC_APP_DESIGN.md \(designRef)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
