import AppKit
import MoleKit
import Observation

/// 分析页 Store（设计 §5.4）：analyze --serve 常驻会话上的目录浏览器。
/// 面包屑既可指向真实路径（scan/缓存命中/rescan），也可指向聚合子集
/// （"其他 N 项"，纯内存切片，可继续下钻）。纯只读；删除待 robot 通道（M2）。
@Observable
@MainActor
final class AnalyzeStore {
    enum Phase: Equatable {
        case idle
        case scanning
        case loaded
        case failed(String)
    }

    struct Crumb: Identifiable {
        enum Target {
            case path(String)
            case aggregate([AnalyzeSession.Node])
        }

        let id = UUID()
        let title: String
        let target: Target
    }

    var phase: Phase = .idle
    private(set) var crumbs: [Crumb] = []
    private(set) var nodes: [AnalyzeSession.Node] = []
    private(set) var totalSize: Int64 = 0
    private(set) var progress: AnalyzeSession.Progress?
    private(set) var isCached = false

    private let session = AnalyzeSession()
    private var scanTask: Task<Void, Never>?

    // MARK: - 入口与导航

    /// 首屏：家目录一层。
    func startIfNeeded() {
        guard crumbs.isEmpty else { return }
        let home = NSHomeDirectory()
        crumbs = [Crumb(title: L("analyze.root"), target: .path(home))]
        scan(path: home, rescan: false)
    }

    func drill(into node: AnalyzeSession.Node) {
        guard node.isDir else { return }
        crumbs.append(Crumb(title: node.name, target: .path(node.path)))
        scan(path: node.path, rescan: false)
    }

    /// 聚合块点击：进入"其他 N 项"子视图（内存切片，面包屑可回退）。
    func openAggregate(_ subset: [AnalyzeSession.Node]) {
        crumbs.append(Crumb(title: L("analyze.aggregate.title", Int64(subset.count)),
                            target: .aggregate(subset)))
        scanTask?.cancel()
        nodes = subset
        totalSize = subset.reduce(0) { $0 + max(0, $1.size) }
        progress = nil
        phase = .loaded
    }

    /// 面包屑跳转（任意层级）。
    func jump(to index: Int) {
        guard index < crumbs.count - 1 else { return }
        crumbs = Array(crumbs.prefix(index + 1))
        switch crumbs[index].target {
        case let .path(path):
            scan(path: path, rescan: false) // 命中会话缓存，秒回
        case let .aggregate(subset):
            openRestoredAggregate(subset)
        }
    }

    private func openRestoredAggregate(_ subset: [AnalyzeSession.Node]) {
        scanTask?.cancel()
        nodes = subset
        totalSize = subset.reduce(0) { $0 + max(0, $1.size) }
        progress = nil
        phase = .loaded
    }

    /// 刷新按钮：强制重扫当前目录（聚合视图不可刷新）。
    func rescan() {
        guard case let .path(path) = crumbs.last?.target else { return }
        scan(path: path, rescan: true)
    }

    var canRescan: Bool {
        if case .path = crumbs.last?.target { return phase == .loaded }
        return false
    }

    // MARK: - 扫描

    private func scan(path: String, rescan: Bool) {
        scanTask?.cancel()
        nodes = []
        totalSize = 0
        progress = nil
        isCached = false
        phase = .scanning
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 流式协议：同一路径会收到多次更新（目录初值→终值），按 path 合并
                var byPath: [String: AnalyzeSession.Node] = [:]
                for try await event in self.session.scan(path: path, rescan: rescan) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .progress(progress):
                        self.progress = progress
                    case let .node(node):
                        byPath[node.path] = node
                        self.nodes = byPath.values.sorted { $0.size > $1.size }
                    case let .done(_, totalSize, _, cached):
                        self.nodes = byPath.values.sorted { $0.size > $1.size }
                        self.totalSize = totalSize
                        self.isCached = cached
                        self.phase = .loaded
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        guard case let .path(path) = crumbs.last?.target else { return }
        scan(path: path, rescan: false)
    }

    // MARK: - 行为

    func reveal(_ node: AnalyzeSession.Node) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func stop() {
        scanTask?.cancel()
        session.stop()
    }
}
