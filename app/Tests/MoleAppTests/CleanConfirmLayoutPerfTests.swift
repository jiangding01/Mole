import MoleKit
import SwiftUI
import XCTest
@testable import MoleApp

/// 确认页大组展开/翻页的布局性能回归（hang 报告：主线程钉死在
/// SwiftUI 布局 135s）。用 NSHostingView 无头渲染真实规模数据，
/// 逐档测量翻页后的布局耗时——防"看起来修好了"的回归复发。
@MainActor
final class CleanConfirmLayoutPerfTests: XCTestCase {
    private func item(_ id: String, bytes: Int64?) -> RobotItem {
        let bytesJSON = bytes.map(String.init) ?? "null"
        // 每项独立父目录：避免 r3 §P5 聚合把 349 行折成一个节点——
        // 本测试要量的是"全部平铺行"的最坏布局成本。路径刻意用真实长度的
        // Chrome 形态（命中 §P2 语义名映射 → 双行 + 头部截断），第三次卡死
        // 的单遍成本大头就是数百个带截断的双行 Text 测量，短路径量不出来。
        let json = """
        {"id":"\(id)","section":"developer_tools","label":"\(id)",
         "path":"/Users/x/Library/Caches/Google/Chrome/Profile-\(id)/Service Worker/CacheStorage/de3a46adb71f7e4939c38bbade57a201ae127140/52c1559b",
         "bytes":\(bytesJSON),
         "kind":"cache","reversible":true,"default_selected":true,"risk":"safe"}
        """
        return try! JSONDecoder().decode(RobotItem.self, from: Data(json.utf8))
    }

    /// 复刻真机分布：349 项、其中 177 项 0 B（开发者工具组）。
    private func makeStore() -> CleanStore {
        let store = CleanStore()
        var items: [RobotItem] = []
        for i in 0..<172 { items.append(item("sized\(i)", bytes: Int64(1000 + i) * 1024) ) }
        for i in 0..<177 { items.append(item("zero\(i)", bytes: 0)) }
        store.ingestPlanForTesting(planId: "pl_perf", items: items, insights: [])
        return store
    }

    /// 展开 + 连续翻页到 0B 长尾深处，每步布局必须在预算内完成。
    /// hang 时代这里是分钟级；健康实现是毫秒级——预算给足 3s 已极宽松。
    func testExpandAndPaginateStaysResponsive() {
        let store = makeStore()
        let group = store.groups[0]
        store.toggleExpand(group)

        let host = NSHostingView(
            rootView: CleanView()
                .environment(store)
                .environment(ScanSession())
                .frame(width: 1200, height: 800)
        )
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        var worst: TimeInterval = 0
        for step in 0..<5 { // 12 → 62 → 112 → 162 → 212 → 262（穿过 0B 分隔线）
            if step > 0 { store.revealMore(group) }
            let start = Date()
            host.layoutSubtreeIfNeeded()
            let elapsed = Date().timeIntervalSince(start)
            worst = max(worst, elapsed)
            XCTAssertLessThan(
                elapsed, 3.0,
                "翻页第 \(step) 步（可见 \(store.visibleCount(group)) 行）布局耗时 \(elapsed)s"
            )
        }
        print("[perf] 最坏单步布局耗时: \(Int(worst * 1000))ms")

        // 事务重放（第三次卡死的实际形态）：翻页到顶后，任何一次状态失效
        // （勾选、滚动、动画帧）都会触发一遍布局。虚拟化拍平后每遍只测
        // 视口附近的行，必须稳定便宜；回退成"整卡实体化"会在这里翻车。
        var worstReplay: TimeInterval = 0
        let probe = store.sortedItems(group)[0]
        for _ in 0..<10 {
            store.toggle(probe)
            let start = Date()
            host.layoutSubtreeIfNeeded()
            let elapsed = Date().timeIntervalSince(start)
            worstReplay = max(worstReplay, elapsed)
            XCTAssertLessThan(elapsed, 0.3, "状态失效后的单遍布局耗时 \(elapsed)s——虚拟化失效？")
        }
        print("[perf] 事务重放最坏单遍: \(Int(worstReplay * 1000))ms")
    }
}
