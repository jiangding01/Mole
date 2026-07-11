import Foundation
import MoleKit
import Observation
import SwiftUI

/// 首启引导 Store（设计 §5.8）：三步状态机——产品承诺 / FDA 授权 / 可选 helper。
///
/// 生命周期：首启（`mole_onboarded` 未置位）时 `presentIfFirstLaunch()` 弹出；
/// 完成或跳过后写入 UserDefaults 并落幕，之后不再自动出现。设置页可用 `reopen()` 复看。
///
/// FDA 授权采用「打开系统设置 → 后台轮询探测」的无阻塞模型：点击后跳转系统设置深链，
/// 每 1s 在后台线程调 `PermissionProbe().hasFullDiskAccess()`，检测到授权即回主线程置
/// `.granted`，再停留 1s 自动推进到第 3 步。轮询任务句柄留存，落幕/完成时取消，避免悬挂。
@Observable
@MainActor
final class OnboardingStore {
    /// FDA 三态（对应设计稿 obFdaIdle / obFdaWaiting / obFdaOk）。
    enum FdaPhase {
        case idle // 未授权、未发起：显示「打开系统设置」CTA
        case waiting // 已跳转系统设置、后台轮询中：琥珀等待框
        case granted // 已授权：绿色对钩框
    }

    private(set) var isPresented = false
    private(set) var step = 1 // 1...3
    /// 最近一次步骤切换的方向（true=前进），供 View 决定滑动转场的进出边。
    private(set) var advancing = true
    private(set) var fdaPhase: FdaPhase = .idle

    /// 首启判定用的 UserDefaults key（写入即代表引导已完成，不再自动弹出）。
    private static let onboardedKey = "mole_onboarded"
    /// FDA 授权流程进行中标记：勾选 FDA 权限的瞬间 macOS 会杀掉 App（TCC 变更），
    /// 重启后据此恢复到 FDA 步而非从头再走。`finish()` 时清除。
    private static let fdaPendingKey = "mole_onboarding_fda_pending"

    private let probe = PermissionProbe()
    /// FDA 轮询任务句柄；落幕/完成时 cancel，防止后台探测悬挂。
    private var fdaPollTask: Task<Void, Never>?

    // MARK: - 弹出 / 复看

    /// 首启弹出：仅当 `mole_onboarded` 未置位时呈现，并按真实 FDA 状态初始化三态。
    /// 若上次运行正在走 FDA 授权（勾选权限时 macOS 会杀掉 App），恢复到 FDA 步：
    /// 已授权则直接呈现成功态，未授权则回到 CTA，不让用户从头再走。
    func presentIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardedKey) else { return }
        present()
        if UserDefaults.standard.bool(forKey: Self.fdaPendingKey) {
            step = 2
        }
    }

    /// 设置页「重新查看」入口（本期先提供 API，暂不接线）。
    func reopen() {
        present()
    }

    private func present() {
        step = 1
        advancing = true
        // 进入时若已授权，FDA 步骤直接呈现 ok 态（不再显示 CTA）。
        fdaPhase = probe.hasFullDiskAccess() ? .granted : .idle
        isPresented = true
    }

    // MARK: - 步骤导航

    /// STEP 1 →2。
    func start() {
        advancing = true
        step = 2
    }

    /// 返回上一步（下限第 1 步）。
    /// 回到 FDA 步时重新对齐真实授权状态：期间可能已完成授权（→ 成功态）；
    /// 也可能轮询已被跳过取消而界面停在等待态（→ 重置回 CTA，否则没有出路）。
    func back() {
        advancing = false
        if step == 3 {
            fdaPhase = probe.hasFullDiskAccess() ? .granted : .idle
        }
        step = max(1, step - 1)
    }

    // MARK: - FDA 授权

    /// 打开系统设置的完全磁盘访问深链，转入等待态并启动后台轮询。
    /// 已授权则忽略（此时三态区已呈现 ok）。
    func requestFda() {
        guard fdaPhase != .granted else { return }
        // 先落「授权进行中」标记再跳系统设置：勾选权限瞬间 App 就可能被杀。
        UserDefaults.standard.set(true, forKey: Self.fdaPendingKey)
        NSWorkspace.shared.open(PermissionProbe.fullDiskAccessSettingsURL)
        fdaPhase = .waiting
        startFdaPolling()
    }

    /// 每 1s 在后台探测 FDA；授权后回主线程置 `.granted`，停留 1s 自动进第 3 步。
    private func startFdaPolling() {
        fdaPollTask?.cancel()
        let probe = probe
        fdaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                // 探测在后台线程执行（文件读判定可能阻塞主线程）。
                let granted = await Task.detached { probe.hasFullDiskAccess() }.value
                if Task.isCancelled { return }
                guard granted else { continue }
                guard let self else { return }
                fdaPhase = .granted
                // 让「已授权」态展示片刻，再自动推进。
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if step == 2 {
                    advancing = true
                    step = 3
                }
                return
            }
        }
    }

    /// 跳过 FDA 授权（设计 §5.8：三步均可跳过，跳过则功能降级并在对应页面常驻提示条）。
    /// 只推进步骤，不写 onboarded 标记——那是 `finish()` 的职责。
    func skipFda() {
        fdaPollTask?.cancel()
        fdaPollTask = nil
        advancing = true
        step = 3
    }

    /// FDA 已授权态的「继续」入口。授权导致 App 重启后从恢复路径进入成功态时，
    /// 没有轮询在跑、不会自动推进，需要这个显式前进按钮。
    func continueAfterFda() {
        fdaPollTask?.cancel()
        fdaPollTask = nil
        advancing = true
        step = 3
    }

    // MARK: - 完成

    /// 完成引导：置位 `mole_onboarded`、取消轮询、落幕。
    /// - Parameter installHelper: 是否请求安装后台助手；本期 helper 未落地，恒为 false。
    func finish(installHelper: Bool = false) {
        _ = installHelper // TODO(helper): SMAppService 落地后据此触发安装
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        UserDefaults.standard.removeObject(forKey: Self.fdaPendingKey)
        fdaPollTask?.cancel()
        fdaPollTask = nil
        // 带动画落幕：给 RootView 的 .transition(.opacity) 提供动画上下文，避免瞬断。
        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
    }

    // 无需 deinit 取消：轮询 Task 持有 [weak self]，Store 释放后下一轮即自终止；
    // 且 Store 由 RootView 会话级 @State 持有，与 App 同生命周期。
}
