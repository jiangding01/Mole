import AppKit
import MoleKit
import Observation
import SwiftUI

/// 完全磁盘访问（FDA）横幅 Store（设计 §7.1）。
///
/// 探测在后台线程（文件读判定可能阻塞主线程，参考 OnboardingStore）；未授权且
/// 未被本会话关闭时显示。关闭仅本会话记忆，不落 UserDefaults。
@Observable
@MainActor
final class FDABannerStore {
    /// 默认假定已授权，探测回来再决定是否亮条，避免首帧闪现。
    private(set) var hasFullDiskAccess = true
    private(set) var dismissed = false

    var isVisible: Bool {
        !hasFullDiskAccess && !dismissed
    }

    func probe() {
        let probe = PermissionProbe()
        Task { [weak self] in
            let granted = await Task.detached { probe.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = granted
        }
    }

    func dismiss() {
        dismissed = true
    }

    func openSettings() {
        NSWorkspace.shared.open(PermissionProbe.fullDiskAccessSettingsURL)
    }
}

/// FDA 未授权提示条（设计 L97-108）：琥珀脉冲点 + 标题/副文 + 前往授权 + 关闭。
struct FDABannerView: View {
    let store: FDABannerStore
    private let look = Look.ink

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 13) {
            amberDot
            HStack(spacing: 0) {
                Text(L("smart.fda.title"))
                    .font(Fonts.ui(13, .semibold))
                    .foregroundStyle(look.text)
                Text(L("smart.fda.sub"))
                    .font(Fonts.ui(12.5))
                    .foregroundStyle(look.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)

            Button(action: store.openSettings) {
                Text(L("smart.fda.grant"))
                    .font(Fonts.ui(12.5, .semibold))
                    .foregroundStyle(look.text)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(look.lineStrong, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .pointingCursor()

            Button(action: store.dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(look.textMute)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingCursor()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.lineStrong, lineWidth: 1))
        .frame(maxWidth: Metrics.contentMaxWidth)
    }

    private var amberDot: some View {
        Circle()
            .fill(Semantic.warn)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().fill(Semantic.warn.opacity(0.15))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.4 : 1)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}
