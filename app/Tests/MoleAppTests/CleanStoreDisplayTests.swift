import MoleKit
import XCTest
@testable import MoleApp

/// 确认页折叠态逻辑（设计 r2 §P1）：展示序、0 B 计数、分页、组统计。
@MainActor
final class CleanStoreDisplayTests: XCTestCase {
    /// RobotItem 无公开 init（协议解码型），经 JSON 构造——顺带走真实解码路径。
    private func item(_ id: String, bytes: Int64?) -> RobotItem {
        let bytesJSON = bytes.map(String.init) ?? "null"
        let json = """
        {"id":"\(id)","section":"s","label":"\(id)","path":"/tmp/\(id)",
         "bytes":\(bytesJSON),"kind":"cache","reversible":true,
         "default_selected":true,"risk":"safe"}
        """
        return try! JSONDecoder().decode(RobotItem.self, from: Data(json.utf8))
    }

    private func makeStore(_ bytes: [Int64?]) -> (CleanStore, CleanStore.Group) {
        let store = CleanStore()
        let items = bytes.enumerated().map { item("i\($0.offset)", bytes: $0.element) }
        store.ingestPlanForTesting(planId: "pl_test", items: items, insights: [])
        return (store, store.groups[0])
    }

    /// 展示序：体积降序 → 未知 → 0 B（未知在 0 B 分隔线之前，r2 §P1.4 两回事）。
    func testDisplayOrderSinksZerosAfterUnknown() {
        let (store, group) = makeStore([0, 500, nil, 2000, 0, 100])
        let order = store.sortedItems(group).map(\.bytes)
        XCTAssertEqual(order, [2000, 500, 100, nil, 0, 0])
        XCTAssertEqual(store.zeroCount(group), 2) // 未知不计入 0 B
    }

    /// 同体积项保持扫描序（稳定排序）。
    func testDisplayOrderIsStable() {
        let (store, group) = makeStore([100, 100, 100])
        XCTAssertEqual(store.sortedItems(group).map(\.id), ["i0", "i1", "i2"])
    }

    /// 分页：首屏 12，revealMore 每次 +50，封顶组内条数。
    func testPagination() {
        let (store, group) = makeStore(Array(repeating: Int64(10), count: 80))
        XCTAssertEqual(store.visibleCount(group), 12)
        store.revealMore(group)
        XCTAssertEqual(store.visibleCount(group), 62)
        store.revealMore(group)
        XCTAssertEqual(store.visibleCount(group), 80) // 不超过总数
    }

    /// 全 0 B 组边界态（§P1.5）。
    func testAllZeroGroup() {
        let (store, group) = makeStore([0, 0, 0])
        XCTAssertTrue(store.isAllZero(group))
        let (store2, group2) = makeStore([0, nil]) // 含未知 ≠ 全 0 B
        XCTAssertFalse(store2.isAllZero(group2))
    }

    /// 折叠/展开默认与重置：ingest 后全折叠。
    func testCollapsedByDefaultAndGroupStats() {
        let (store, group) = makeStore([100, 0, nil])
        XCTAssertFalse(store.isExpanded(group))
        store.toggleExpand(group)
        XCTAssertTrue(store.isExpanded(group))
        XCTAssertEqual(store.groupSelectedCount(group), 3) // 默认全选
        XCTAssertEqual(store.groupSelectedBytes(group), 100) // 只计已知
    }
}
