import Foundation
import MoleKit
import Observation

/// 启动项 tab 的 Store（设计 §5.2.3）：登录项 + 后台服务两组，状态筛选，
/// 开关切换（乐观更新 + 失败回滚）。系统项整行只读。
///
/// 首次进入 tab 才加载（lazy）；刷新保留旧数据不闪。开关委托 core 侧可逆操作
/// （launchctl bootout/bootstrap + plist quarantine），本层只做乐观 UI 与回滚。
@Observable
@MainActor
final class LaunchItemsStore {
    enum Phase: Equatable {
        case idle, loading
        case loaded
        case failed(String)
    }

    /// 状态筛选（设计稿工具栏循环钮 all/on/off）。
    enum Filter: String, CaseIterable {
        case all, on, off
    }

    var phase: Phase = .idle
    var filter: Filter = .all
    private(set) var items: [LaunchItem] = []
    /// 正在切换的 id（期间禁用交互，避免连点竞态）。
    private(set) var pending: Set<String> = []

    private let client = LaunchItemsClient()
    private var loadTask: Task<Void, Never>?

    // MARK: - 派生分组

    /// 登录项组（按筛选）。
    var loginItems: [LaunchItem] {
        items.filter { $0.category.isLogin && matchesFilter($0) }
    }

    /// 后台服务组（用户/系统 LaunchAgent + LaunchDaemon，按筛选）。
    var serviceItems: [LaunchItem] {
        items.filter { !$0.category.isLogin && matchesFilter($0) }
    }

    private func matchesFilter(_ item: LaunchItem) -> Bool {
        switch filter {
        case .all: true
        case .on: item.enabled
        case .off: !item.enabled
        }
    }

    func cycleFilter() {
        let all = Filter.allCases
        let next = (all.firstIndex(of: filter).map { $0 + 1 } ?? 0) % all.count
        filter = all[next]
    }

    // MARK: - 加载

    func loadIfNeeded() {
        guard phase == .idle || isFailed else { return }
        reload()
    }

    func reload(silent: Bool = false) {
        loadTask?.cancel()
        if !silent || phase != .loaded {
            phase = .loading
        }
        loadTask = Task { [weak self] in
            do {
                let list = try await self?.client.list() ?? []
                guard let self, !Task.isCancelled else { return }
                items = list
                phase = .loaded
            } catch {
                guard let self, !Task.isCancelled else { return }
                if silent, phase == .loaded { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - 开关（乐观更新 + 失败回滚）

    func isPending(_ item: LaunchItem) -> Bool {
        pending.contains(item.id)
    }

    /// 切换开关：系统项/进行中忽略；否则先乐观翻转，再委托 core，结果不符即回滚。
    func toggle(_ item: LaunchItem) {
        guard item.mutable, !pending.contains(item.id) else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = !item.enabled
        // 乐观更新
        items[index].enabled = target
        pending.insert(item.id)
        Task { [weak self] in
            guard let self else { return }
            var success = false
            do {
                let results = try await client.setEnabled(ids: [item.id], enabled: target)
                success = results.first?.succeeded(forEnabling: target) ?? false
            } catch {
                success = false
            }
            pending.remove(item.id)
            if !success {
                // 回滚：按 id 重新定位（列表可能已被刷新重排）。
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].enabled = !target
                }
            }
        }
    }
}
