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

    /// 各页 Store 提升到会话层（设计 §5.0 会话共享）：切 tab 只是视图重建，
    /// 状态与在途扫描/清单保留，再次进入即时呈现、不重扫。
    /// （曾经的 bug：Store 挂在页面 @State 上，每次切走即销毁，再进重扫且
    /// 旧 Store 的读流任务悬挂堆积——分析/优化页再入永久 loading。）
    @State private var cleanStore = CleanStore()
    @State private var appsStore = AppsStore()
    @State private var optimizeStore = OptimizeStore()
    @State private var analyzeStore = AnalyzeStore()
    @State private var statusStore = StatusStore()

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
        .environment(cleanStore)
        .environment(appsStore)
        .environment(optimizeStore)
        .environment(analyzeStore)
        .environment(statusStore)
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
            .contentShape(Rectangle())
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
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background {
                            // 设计稿：选中 = 当前模块 accent 渐变胶囊 + on-accent 文字
                            if tab == selectedTab {
                                Capsule().fill(tabAccent.gradient)
                                    .matchedGeometryEffect(id: "navPill", in: navNamespace)
                            }
                        }
                        .foregroundStyle(tab == selectedTab ? tabAccent.onAccent : look.textDim)
                        // 透明 padding 默认不参与命中测试：显式声明整个胶囊区域可点
                        .contentShape(Capsule())
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
