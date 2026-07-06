import MoleKit
import SwiftUI

/// 单窗口根视图：顶部居中胶囊分段导航 + 页面容器（设计 §8.1）。
struct RootView: View {
    @State private var selectedTab: MainTab = .smartScan
    @State private var showsHistory = false
    @State private var showsSettings = false

    /// 扫描结果跨页共享的会话资产（设计 §5.0）。
    @State private var scanSession = ScanSession()

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background(for: selectedTab)
                .ignoresSafeArea()

            currentPage
                .padding(.top, 64)

            navigationCapsule
                .padding(.top, 12)
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

    private var navigationCapsule: some View {
        HStack(spacing: 4) {
            // 品牌徽标：点击回智能扫描页
            Button {
                selectedTab = .smartScan
            } label: {
                Image(systemName: "circle.fill") // TODO: 替换为鼹鼠徽标资产
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            ForEach(MainTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            // 选中项实心高亮胶囊；位移过渡动画在 DesignSystem 打磨阶段接入
                            Capsule().fill(tab == selectedTab ? Theme.capsuleSelected : .clear)
                        )
                        .foregroundStyle(tab == selectedTab ? Theme.capsuleSelectedText : Theme.capsuleText)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            Button { showsHistory = true } label: { Image(systemName: "clock") }
                .buttonStyle(.plain)
            Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.capsuleBackground))
    }
}
