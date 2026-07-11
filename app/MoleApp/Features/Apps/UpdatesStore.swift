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

    /// 全部更新：对当前可见项串行逐个执行（core 侧 brew 本就串行，避免并发抢锁）。
    func updateAll() {
        guard !bulkRunning else { return }
        let targets = visibleUpdates.filter { !running.contains($0.id) }
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
            updates.removeAll { $0.id == item.id }
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

    func failure(_ item: AppUpdate) -> String? {
        failures[item.id]
    }
}
