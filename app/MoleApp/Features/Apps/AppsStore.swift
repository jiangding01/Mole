import AppKit
import MoleKit
import Observation

/// 软件页 Store（设计 §5.2）：卸载 tab 的应用清单、搜索、排序与多选。
/// M0 为只读清单——卸载执行等机器人层 apps plan/apply 落地后接入，
/// 在那之前批量条的移除按钮保持禁用并说明原因（不做假按钮）。
@Observable
@MainActor
final class AppsStore {
    enum Phase: Equatable {
        case idle, loading
        case loaded
        case failed(String)
    }

    enum SortKey: String { case name, size, source }

    enum Tab: String, CaseIterable, Identifiable {
        case uninstall, update, startup
        var id: String { rawValue }
        var title: String {
            switch self {
            case .uninstall: L("apps.tab.uninstall")
            case .update: L("apps.tab.update")
            case .startup: L("apps.tab.startup")
            }
        }
    }

    var phase: Phase = .idle
    var tab: Tab = .uninstall
    var apps: [InstalledApp] = []
    var search = ""
    var sortKey: SortKey = .size
    var sortDescending = true
    var selection: Set<String> = [] // InstalledApp.id（path）

    private let client = AppInventoryClient()
    private var loadTask: Task<Void, Never>?

    /// 首次进入页面时加载；已有数据则不重扫（会话内清单复用，设计 §5.0 同源）。
    func loadIfNeeded() {
        guard phase == .idle || isFailed else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task { [weak self] in
            do {
                let apps = try await self?.client.list() ?? []
                guard let self, !Task.isCancelled else { return }
                self.apps = apps
                self.phase = .loaded
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - 派生列表

    var visibleApps: [InstalledApp] {
        var list = apps
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.bundleId.localizedCaseInsensitiveContains(query)
            }
        }
        let sorted = list.sorted { a, b in
            let ascending: Bool
            switch sortKey {
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: ascending = (a.sizeBytes ?? 0) < (b.sizeBytes ?? 0)
            case .source: ascending = a.source < b.source
            }
            return sortDescending ? !ascending : ascending
        }
        return sorted
    }

    var totalSizeText: String {
        let total = apps.compactMap(\.sizeBytes).reduce(0, +)
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortDescending.toggle() } else {
            sortKey = key
            sortDescending = key != .name
        }
    }

    // MARK: - 选择

    func toggleSelection(_ app: InstalledApp) {
        if selection.contains(app.id) { selection.remove(app.id) } else { selection.insert(app.id) }
    }

    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.id) } }

    var selectedSizeText: String {
        let total = selectedApps.compactMap(\.sizeBytes).reduce(0, +)
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: - 行为

    func reveal(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    // MARK: - 图标（按 path 缓存）

    private var iconCache: [String: NSImage] = [:]

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconCache[app.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 36, height: 36)
        iconCache[app.path] = image
        return image
    }
}
