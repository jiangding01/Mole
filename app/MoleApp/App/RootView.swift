import MoleKit
import SwiftUI

/// 单窗口根视图（设计稿顶栏三段式）：
/// 左上 wordmark（Mole FOR MAC）· 中央胶囊 6 tab（选中 = 当前模块 accent 渐变胶囊）
/// · 右上 历史/设置 两个独立圆钮。整站随激活页 re-tint（accent 氛围光）。
struct RootView: View {
    @State private var selectedTab: MainTab = .smartScan
    @State private var showsHistory = false
    @State private var showsSettings = false

    /// 扫描结果跨页共享的会话资产（设计 §5.0）。
    @State private var scanSession = ScanSession()

    private let look = Look.ink
    private var accent: ModuleAccent { Theme.moduleAccent(for: selectedTab) }

    var body: some View {
        ZStack(alignment: .top) {
            look.background(accent: accent)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: selectedTab) // 氛围光 400ms 交叉淡入

            currentPage
                .padding(.top, 64)

            topBar
                .padding(.horizontal, 20)
                .padding(.top, 10)
        }
        .environment(scanSession)
        .sheet(isPresented: $showsHistory) { HistoryView() }
        .sheet(isPresented: $showsSettings) { SettingsView() }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch selectedTab {
        case .smartScan: SmartScanView()
        case .clean: CleanView()
        case .apps: AppsView()
        case .optimize: OptimizeView()
        case .analyze: AnalyzeView()
        case .status: StatusView()
        }
    }

    // MARK: - 顶栏（三段式）

    private var topBar: some View {
        ZStack {
            navigationCapsule // 胶囊绝对居中，不受两侧宽度影响
            HStack {
                wordmark
                Spacer()
                iconButton("clock.arrow.circlepath") { showsHistory = true }
                iconButton("gearshape") { showsSettings = true }
            }
        }
    }

    private var wordmark: some View {
        Button {
            selectedTab = .smartScan
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Mole")
                    .font(Fonts.mono(17, .bold))
                    .foregroundStyle(look.text)
                Fonts.eyebrow("For Mac", size: 9)
                    .foregroundStyle(look.textMute)
            }
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(look.textDim)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(look.chrome))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    private var navigationCapsule: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let tabAccent = Theme.moduleAccent(for: tab)
                Button {
                    withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(Fonts.ui(13, tab == selectedTab ? .semibold : .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            // 设计稿：选中 = 当前模块 accent 渐变胶囊 + on-accent 文字
                            if tab == selectedTab {
                                Capsule().fill(tabAccent.gradient)
                                    .matchedGeometryEffect(id: "navPill", in: navNamespace)
                            }
                        }
                        .foregroundStyle(tab == selectedTab ? tabAccent.onAccent : look.textDim)
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        }
        .padding(4)
        .background(Capsule().fill(look.chrome))
        .overlay(Capsule().stroke(look.line, lineWidth: 1))
    }

    @Namespace private var navNamespace
}
