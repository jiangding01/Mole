import Foundation
import MoleKit
import Observation

/// 更新 tab 的 Store（设计 §5.2.2）：可更新应用清单 + 单项/全部更新 + 忽略更新。
///
/// 首次进入 tab 才加载（lazy）；刷新保留旧数据不闪。更新委托 Homebrew（core 侧
/// `brew upgrade --cask`），本层只驱动行内进行中态与失败呈现。忽略集合持久化在
/// UserDefaults（按 cask token），列表过滤，不影响 core。
@Observable
@MainActor
final class UpdatesStore {
    enum Phase: Equatable {
        case idle, loading
        case loaded
        case failed(String)
    }

    static let ignoredDefaultsKey = "mole_ignored_updates"

    var phase: Phase = .idle
    private(set) var updates: [AppUpdate] = []
    /// 进行中的更新 id（行内 ProgressView）。
    private(set) var running: Set<String> = []
    /// 更新失败的 id → stderr 摘要（行内诚实呈现，按钮转「重试」）。
    private(set) var failures: [String: String] = [:]
    /// 刚完成的 id：绿色「已更新」驻留 1s 后行淡出移除（设计 CHANGELOG §1.3）。
    private(set) var completed: Set<String> = []
    /// 「全部更新」串行进行中（避免重入、按钮转进行态）。
    private(set) var bulkRunning = false
    /// 被忽略的 cask token（持久化，列表过滤）。
    private(set) var ignored: Set<String>

    private let client = UpdatesClient()
    private var loadTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.ignoredDefaultsKey) as? [String] ?? []
        ignored = Set(stored)
    }

    /// 过滤掉被忽略的项（token 命中即隐藏）。
    var visibleUpdates: [AppUpdate] {
        updates.filter { !ignored.contains($0.token) }
    }

    var visibleCount: Int {
        visibleUpdates.count
    }

    /// 是否有可执行的「全部更新」（存在未在进行中的可见项）。
    var canUpdateAll: Bool {
        !bulkRunning && visibleUpdates.contains { !running.contains($0.id) }
    }

    // MARK: - 加载

    func loadIfNeeded() {
        guard phase == .idle || isFailed else { return }
        reload()
    }

    /// silent：后台静默校准，不翻转 loading，失败保留现有列表。
    func reload(silent: Bool = false) {
        loadTask?.cancel()
        if !silent || phase != .loaded {
            phase = .loading
        }
        loadTask = Task { [weak self] in
            do {
                let list = try await self?.client.list() ?? []
                guard let self, !Task.isCancelled else { return }
                updates = list
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

    // MARK: - 更新执行

    /// 单项更新：置进行中 → 委托 brew → 成功移除该行 / 失败记录摘要。
    func update(_ item: AppUpdate) {
        guard !running.contains(item.id) else { return }
        Task { await performUpdate(item) }
    }

    /// 全部更新：只作用于 Homebrew 项（设计 §1.3），串行逐个执行
    /// （core 侧 brew 本就串行，避免并发抢锁）。跳转类来源不代为执行。
    func updateAll() {
        guard !bulkRunning else { return }
        let targets = brewUpdates.filter { !running.contains($0.id) }
        guard !targets.isEmpty else { return }
        bulkRunning = true
        Task { [weak self] in
            guard let self else { return }
            for item in targets {
                // 期间可能已被单独更新/忽略而移除，跳过失效项。
                guard updates.contains(where: { $0.id == item.id }),
                      !ignored.contains(item.token) else { continue }
                await performUpdate(item)
            }
            bulkRunning = false
        }
    }

    private func performUpdate(_ item: AppUpdate) async {
        running.insert(item.id)
        failures[item.id] = nil
        do {
            try await client.upgrade(id: item.id)
            running.remove(item.id)
            // 设计行内状态机：done（绿色「已更新」）驻留 1s，随后行淡出。
            completed.insert(item.id)
            try? await Task.sleep(for: .seconds(1))
            completed.remove(item.id)
            updates.removeAll { $0.id == item.id } // 行淡出动画由列表侧 .animation 驱动
        } catch {
            running.remove(item.id)
            failures[item.id] = error.localizedDescription
        }
    }

    // MARK: - 忽略

    /// 忽略某项更新（持久化 token；列表即时过滤）。
    func ignore(_ item: AppUpdate) {
        ignored.insert(item.token)
        failures[item.id] = nil
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredDefaultsKey)
    }

    func isRunning(_ item: AppUpdate) -> Bool {
        running.contains(item.id)
    }

    func isCompleted(_ item: AppUpdate) -> Bool {
        completed.contains(item.id)
    }

    /// 可在 Mole 内一键更新的可见项（Homebrew）；跳转类来源不计入。
    var brewUpdates: [AppUpdate] {
        visibleUpdates.filter(\.isBrewManaged)
    }

    /// 需前往来源更新的可见项数（App Store / Sparkle / Electron 等）。
    var jumpCount: Int {
        visibleUpdates.count - brewUpdates.count
    }

    func failure(_ item: AppUpdate) -> String? {
        failures[item.id]
    }
}
