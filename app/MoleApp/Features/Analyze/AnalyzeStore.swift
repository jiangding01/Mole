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

    enum ListSort { case size, name }

    var phase: Phase = .idle
    private(set) var crumbs: [Crumb] = []
    private(set) var nodes: [AnalyzeSession.Node] = []
    private(set) var totalSize: Int64 = 0
    private(set) var progress: AnalyzeSession.Progress?
    private(set) var isCached = false
    /// 列表 ↔ treemap 双向 hover 联动的共享焦点（path）。
    var hoveredPath: String?
    /// 左栏排序（treemap 恒按大小）。
    var listSort: ListSort = .size
    /// 扫描覆盖层标题（当前目标目录名）。
    private(set) var scanningTitle = ""

    private let session = AnalyzeSession()
    private var scanTask: Task<Void, Never>?
    /// 流式合并缓冲：同一路径多次更新（目录初值→终值）按 path 收敛，
    /// 由 100ms 合并刷新落到 nodes/totalSize——逐事件全量重排会把主线程打满，
    /// 表现为扫描覆盖层计数与页头统计"冻结"。
    private var byPath: [String: AnalyzeSession.Node] = [:]
    private var flushTask: Task<Void, Never>?
    /// 导航代际：drill/jump/aggregate 都会推进，滞留的旧流事件与旧刷新任务失效。
    private var scanGeneration = 0

    var listNodes: [AnalyzeSession.Node] {
        switch listSort {
        case .size: nodes
        case .name: nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// 磁盘用量（设计稿页头"磁盘 481 / 494 GB"）。
    var diskUsage: (used: Int64, total: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        return (total - free, total)
    }

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
        cancelScan()
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
        cancelScan()
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
        cancelScan()
        let generation = scanGeneration
        // 不清空 nodes：设计稿的扫描态是"旧内容模糊压暗 + 居中加载"，
        // 新流的首批 node 一到就替换。
        byPath = [:]
        progress = nil
        isCached = false
        scanningTitle = crumbs.last?.title ?? (path as NSString).lastPathComponent
        phase = .scanning
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.session.scan(path: path, rescan: rescan) {
                    guard !Task.isCancelled, self.scanGeneration == generation else { return }
                    switch event {
                    case let .progress(progress):
                        self.progress = progress
                    case let .node(node):
                        self.byPath[node.path] = node
                        self.scheduleFlush(generation)
                    case let .done(_, totalSize, _, cached):
                        self.flushTask?.cancel()
                        self.flushTask = nil
                        self.nodes = self.byPath.values.sorted { $0.size > $1.size }
                        self.totalSize = totalSize
                        self.isCached = cached
                        self.phase = .loaded
                    }
                }
            } catch {
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 100ms 合并刷新：把 byPath 的增量落到 nodes/totalSize。
    /// 排序 + 全量赋值每次都触发列表/treemap 重算，逐事件执行会饿死 UI。
    private func scheduleFlush(_ generation: Int) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.flushTask = nil
            self.nodes = self.byPath.values.sorted { $0.size > $1.size }
            self.totalSize = self.byPath.values.reduce(0) { $0 + max(0, $1.size) }
        }
    }

    /// 终止在途扫描并推进代际：旧流的滞留事件与未触发的合并刷新全部失效。
    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        flushTask?.cancel()
        flushTask = nil
        scanGeneration += 1
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
        cancelScan()
        session.stop()
    }
}
