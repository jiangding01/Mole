import MoleKit
import XCTest
@testable import MoleApp

/// 确认页折叠态逻辑（设计 r2 §P1）：展示序、0 B 计数、分页、组统计。
@MainActor
final class CleanStoreDisplayTests: XCTestCase {
    /// RobotItem 无公开 init（协议解码型），经 JSON 构造——顺带走真实解码路径。
    private func item(_ id: String, bytes: Int64?, defaultSelected: Bool = true) -> RobotItem {
        let bytesJSON = bytes.map(String.init) ?? "null"
        let json = """
        {"id":"\(id)","section":"s","label":"\(id)","path":"/tmp/\(id)",
         "bytes":\(bytesJSON),"kind":"cache","reversible":true,
         "default_selected":\(defaultSelected),"risk":"safe"}
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

    /// 选择预设（r3 §P6）：推荐集 = default_selected；全选/清空/推荐三动作
    /// 与"选择恰等推荐集"高亮判定。
    func testSelectionPresets() {
        let store = CleanStore()
        let items = [
            item("safe1", bytes: 100),
            item("safe2", bytes: 200),
            item("caution1", bytes: 300, defaultSelected: false),
        ]
        store.ingestPlanForTesting(planId: "pl_test", items: items, insights: [])
        // ingest 即推荐集
        XCTAssertEqual(store.checked, ["safe1", "safe2"])
        XCTAssertTrue(store.isRecommendedSelection)
        store.selectAll()
        XCTAssertEqual(store.checked.count, 3)
        XCTAssertFalse(store.isRecommendedSelection)
        store.selectNone()
        XCTAssertTrue(store.checked.isEmpty)
        XCTAssertFalse(store.isRecommendedSelection)
        store.selectRecommended()
        XCTAssertEqual(store.checked, ["safe1", "safe2"])
        XCTAssertTrue(store.isRecommendedSelection)
    }

    /// 语义名映射（r3 §P2）：知名路径命中、具体规则优先、未知路径回退 nil。
    func testSemanticPathNames() {
        // 具体在前：ModuleCache 命中模块缓存而非 DerivedData 泛条目
        let module = CleanPathNames.semanticName(
            forAbbreviatedPath: "~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
        XCTAssertNotNil(module)
        XCTAssertTrue(module!.contains("模块") || module!.lowercased().contains("module"))
        XCTAssertNotNil(CleanPathNames.semanticName(
            forAbbreviatedPath: "~/Library/Caches/Google/Chrome/Default/Cache"))
        XCTAssertNotNil(CleanPathNames.semanticName(forAbbreviatedPath: "~/.npm/_cacache"))
        // 映射不到 = nil（回退纯路径行，绝不编造）
        XCTAssertNil(CleanPathNames.semanticName(
            forAbbreviatedPath: "~/Library/Caches/com.unknown.vendor.tool"))
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
