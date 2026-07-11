import Foundation
import MoleKit
import Observation

/// 历史页 Store（设计 §5.6）：只读拉取 `mole robot history list` 两路合流后的
/// 会话时间线；手风琴单开（同一时刻仅展开一张卡）。
///
/// 纯只读——不涉及任何删除/恢复动作。数据获取与 NDJSON 解析在 MoleKit
/// `HistoryReader` 内完成，Store 仅消费结果。
@Observable
@MainActor
final class HistoryStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var sessions: [HistorySession] = []
    /// 当前展开的会话 id（单开手风琴；nil = 全部收起）。
    var openSessionId: String?

    private let reader = HistoryReader()

    /// 拉取历史（sheet onAppear 调用）。已 loaded 也允许重拉刷新，避免过期。
    func load() async {
        // 首次进入才切 loading 骨架；刷新时保留旧数据不闪。
        if sessions.isEmpty { phase = .loading }
        do {
            let result = try await reader.load()
            sessions = result
            // 若原展开项已不在新列表中，收起以免悬挂。
            if let open = openSessionId, !result.contains(where: { $0.id == open }) {
                openSessionId = nil
            }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 手风琴切换：点已展开的 → 收起；点其他的 → 单开。
    func toggle(_ id: String) {
        openSessionId = (openSessionId == id) ? nil : id
    }
}
