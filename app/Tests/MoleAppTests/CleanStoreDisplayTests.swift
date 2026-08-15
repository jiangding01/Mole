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

    /// 白名单行与选择的联动（r3 §P3）：不可勾、除名统计、组全选/推荐集除名。
    func testWhitelistedSelectionInteraction() {
        let store = CleanStore()
        let items = [item("a", bytes: 100), item("b", bytes: 200), item("c", bytes: 300)]
        store.ingestPlanForTesting(planId: "pl_test", items: items, insights: [])
        store.markWhitelistedForTesting("b")
        // 已加白：勾选被移除且不可再勾
        XCTAssertFalse(store.checked.contains("b"))
        store.toggle(items[1])
        XCTAssertFalse(store.checked.contains("b"))
        // 统计除名：checkedBytes 不含 b
        XCTAssertEqual(store.checkedBytes, 400)
        // 组全选态：全部可勾项已勾即视为全选；toggleGroup 不会勾进白名单行
        let group = store.groups[0]
        XCTAssertTrue(store.groupChecked(group))
        store.toggleGroup(group) // 取消全选
        store.toggleGroup(group) // 再全选
        XCTAssertFalse(store.checked.contains("b"))
        // 推荐集除名：恰等（扣除白名单后的）推荐集仍算"推荐"态
        store.selectRecommended()
        XCTAssertTrue(store.isRecommendedSelection)
        XCTAssertFalse(store.checked.contains("b"))
        store.selectAll()
        XCTAssertFalse(store.checked.contains("b"))
    }

    /// 行级锁定（r3 §P4）：blocked_by 非空 → 不可勾、推荐集除名、组全选除名；
    /// 体积照常计入组总量（扫到了）；blocked_by 解析两态。
    func testLockedRows() {
        func lockedItem(_ id: String, bytes: Int64, blockedBy: String) -> RobotItem {
            let json = """
            {"id":"\(id)","section":"s","label":"\(id)","path":"/tmp/\(id)",
             "bytes":\(bytes),"kind":"cache","reversible":true,
             "default_selected":true,"risk":"safe","blocked_by":"\(blockedBy)"}
            """
            return try! JSONDecoder().decode(RobotItem.self, from: Data(json.utf8))
        }
        let store = CleanStore()
        let items = [
            item("free", bytes: 100),
            lockedItem("byapp", bytes: 200, blockedBy: "app:Google Chrome"),
            lockedItem("bysys", bytes: 300, blockedBy: "sys"),
        ]
        store.ingestPlanForTesting(planId: "pl_test", items: items, insights: [])
        // 锁定行从初始勾选与推荐集除名，且不可勾
        XCTAssertEqual(store.checked, ["free"])
        XCTAssertTrue(store.isRecommendedSelection)
        store.toggle(items[1])
        XCTAssertFalse(store.checked.contains("byapp"))
        store.selectAll()
        XCTAssertEqual(store.checked, ["free"])
        // 组全选态把锁定行除名；组总量照常计入锁定行体积（扫到了）
        let group = store.groups[0]
        XCTAssertTrue(store.groupChecked(group))
        XCTAssertEqual(group.bytes, 600)
        XCTAssertEqual(store.checkedBytes, 100)
        // blocked_by 解析
        XCTAssertEqual(CleanStore.lockAppName("app:Google Chrome"), "Google Chrome")
        XCTAssertNil(CleanStore.lockAppName("sys"))
        XCTAssertNil(CleanStore.lockAppName(nil))
        // 聚合父行继承：全锁才算锁
        XCTAssertFalse(store.aggregateLocked(items))
        XCTAssertTrue(store.aggregateLocked([items[1], items[2]]))
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

    /// 同父目录聚合（r3 §P5）：非共享父目录 ≥2 子项折聚合节点；
    /// 共享位置（拒绝表）与孤子项保持单行；父行三态与批量勾选联动。
    func testAggregationNodes() {
        func pathItem(_ id: String, _ path: String, bytes: Int64) -> RobotItem {
            let json = """
            {"id":"\(id)","section":"s","label":"\(path)","path":"\(path)",
             "bytes":\(bytes),"kind":"cache","reversible":true,
             "default_selected":true,"risk":"safe"}
            """
            return try! JSONDecoder().decode(RobotItem.self, from: Data(json.utf8))
        }
        let home = NSHomeDirectory()
        let store = CleanStore()
        store.ingestPlanForTesting(planId: "pl_test", items: [
            // 同一应用容器下三个子项 → 聚合
            pathItem("a1", "\(home)/Library/Caches/TestApp/Cache", bytes: 300),
            pathItem("a2", "\(home)/Library/Caches/TestApp/Code Cache", bytes: 200),
            pathItem("a3", "\(home)/Library/Caches/TestApp/GPUCache", bytes: 100),
            // 共享位置（~/Library/Caches 直接子项）→ 拒绝聚合，保持单行
            pathItem("s1", "\(home)/Library/Caches/com.vendor.one", bytes: 500),
            pathItem("s2", "\(home)/Library/Caches/com.vendor.two", bytes: 400),
        ], insights: [])
        let group = store.groups[0]
        let nodes = store.displayNodes(group)
        XCTAssertEqual(nodes.count, 3) // 聚合 ×1 + 单行 ×2
        // 聚合节点位于其最大子项（300B）的展示序位置：500/400 之后
        guard case let .aggregate(parent, children) = nodes[2] else {
            return XCTFail("第三个节点应为聚合，实际 \(nodes[2])")
        }
        XCTAssertTrue(parent.hasSuffix("/Library/Caches/TestApp"))
        XCTAssertEqual(children.map(\.id), ["a1", "a2", "a3"]) // 子项保持体积降序
        XCTAssertEqual(store.aggregateBytes(children), 600)
        // 三态联动：默认全选 → 摘一个成半选 → toggleAggregate 勾满 → 再 toggle 全清
        XCTAssertTrue(store.aggregateAllChecked(children))
        store.toggle(children[1])
        XCTAssertFalse(store.aggregateAllChecked(children))
        XCTAssertTrue(store.aggregateAnyChecked(children))
        store.toggleAggregate(children)
        XCTAssertTrue(store.aggregateAllChecked(children))
        store.toggleAggregate(children)
        XCTAssertFalse(store.aggregateAnyChecked(children))
        // 默认收起
        XCTAssertFalse(store.isAggregateExpanded(nodes[2]))
        // 分页单位是节点
        XCTAssertEqual(store.visibleCount(group), 3)
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
