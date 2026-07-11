import MoleKit
import SwiftUI

/// 单窗口根视图（设计稿顶栏三段式）：
/// 左上 wordmark（Mole FOR MAC）· 中央胶囊 6 tab（选中 = 当前模块 accent 渐变胶囊）
/// · 右上 历史/设置 两个独立圆钮。整站随激活页 re-tint（accent 氛围光）。
struct RootView: View {
    /// 会话级导航路由（设计 §5.0）：胶囊、wordmark、智能页结论卡共用同一切页入口。
    @State private var router = Router()
    @State private var showsHistory = false
    @State private var showsSettings = false

    /// 扫描结果跨页共享的会话资产（设计 §5.0）。
    @State private var scanSession = ScanSession()

    /// 智能扫描首页 Store（会话层，跨 tab 保活；设计 §6.1）。
    @State private var smartScanStore = SmartScanStore()

    /// FDA 未授权全局横幅 Store（设计 §7.1）：topNav 之下、main 之上。
    @State private var fdaBannerStore = FDABannerStore()

    /// 各页 Store 提升到会话层（设计 §5.0 会话共享）：切 tab 只是视图重建，
    /// 状态与在途扫描/清单保留，再次进入即时呈现、不重扫。
    /// （曾经的 bug：Store 挂在页面 @State 上，每次切走即销毁，再进重扫且
    /// 旧 Store 的读流任务悬挂堆积——分析/优化页再入永久 loading。）
    @State private var cleanStore = CleanStore()
    @State private var appsStore = AppsStore()
    @State private var updatesStore = UpdatesStore()
    @State private var launchItemsStore = LaunchItemsStore()
    @State private var optimizeStore = OptimizeStore()
    @State private var analyzeStore = AnalyzeStore()
    @State private var statusStore = StatusStore()
    @State private var historyStore = HistoryStore()

    /// 首启引导（设计 §5.8）：会话级 Store，overlay 挂在根 ZStack 最顶层。
    @State private var onboardingStore = OnboardingStore()

    private let look = Look.ink
    private var accent: ModuleAccent {
        Theme.moduleAccent(for: router.tab)
    }

    var body: some View {
        ZStack(alignment: .top) {
            look.background(accent: accent)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: router.tab) // 氛围光 400ms 交叉淡入

            // topNav 之下、main 之上（设计 L97-108）：横幅在流内，出现时向下推开主内容。
            VStack(spacing: 12) {
                if fdaBannerStore.isVisible {
                    FDABannerView(store: fdaBannerStore)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
                currentPage
            }
            .padding(.top, 64)

            topBar
                .padding(.horizontal, 20)
                .padding(.top, 10)

            // 首启引导 overlay：必须是根 ZStack 最顶层直接子级，盖住 topBar 与页面
            // （设计红线：全屏弹窗不能嵌在带 transform 动画的容器里）。
            if onboardingStore.isPresented {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .environment(router)
        .environment(scanSession)
        .environment(smartScanStore)
        .environment(cleanStore)
        .environment(appsStore)
        .environment(updatesStore)
        .environment(launchItemsStore)
        .environment(optimizeStore)
        .environment(analyzeStore)
        .environment(statusStore)
        .environment(historyStore)
        .environment(onboardingStore)
        .sheet(isPresented: $showsHistory) { HistoryView() }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .onAppear {
            onboardingStore.presentIfFirstLaunch()
            fdaBannerStore.probe()
        }
        // App 回到前台时复测 FDA：授权在系统设置里完成（期间本 App 失焦），
        // 切回来即刷新横幅；只测启动一刻会让横幅永远停在旧结果上。
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            fdaBannerStore.probe()
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch router.tab {
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
            router.go(.smartScan)
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
                let isSelected = tab == router.tab
                Button {
                    router.go(tab) // Router.go 已内建同款 spring，避免双重动画
                } label: {
                    Text(tab.title)
                        .font(Fonts.ui(13, isSelected ? .semibold : .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background {
                            // 设计稿：选中 = 当前模块 accent 渐变胶囊 + on-accent 文字
                            if isSelected {
                                Capsule().fill(tabAccent.gradient)
                                    .matchedGeometryEffect(id: "navPill", in: navNamespace)
                            }
                        }
                        .foregroundStyle(isSelected ? tabAccent.onAccent : look.textDim)
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
