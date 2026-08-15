import XCTest
@testable import MoleKit

final class MetricsSnapshotTests: XCTestCase {
    /// process_alerts 解码：字段映射 + triggered_at 保持字符串（快照解码器
    /// 无日期策略，用 Date 会让整帧解码失败）。
    func testDecodesProcessAlerts() throws {
        let json = """
        {"health_score": 84, "process_alerts": [
          {"pid": 1284, "name": "Final Cut Pro", "cpu": 161.5,
           "threshold": 100, "window": "5m0s",
           "triggered_at": "2026-08-15T12:00:00Z", "status": "active"}
        ]}
        """
        let snap = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        let alert = try XCTUnwrap(snap.processAlerts?.first)
        XCTAssertEqual(alert.pid, 1284)
        XCTAssertEqual(alert.status, "active")
        XCTAssertEqual(alert.threshold, 100)
        // 12:00Z 起算的持续分钟数：应为非负整数（真实时钟，只验可解析性）
        XCTAssertNotNil(alert.sustainedMinutes)
    }

    /// 缺失 process_alerts 的旧快照仍可解码（前向兼容）。
    func testSnapshotWithoutAlertsStillDecodes() throws {
        let snap = try JSONDecoder().decode(
            MetricsSnapshot.self, from: Data(#"{"health_score": 90}"#.utf8)
        )
        XCTAssertNil(snap.processAlerts)
        XCTAssertEqual(snap.healthScore, 90)
    }

    /// 不可解析的 triggered_at 返回 nil 而不是崩。
    func testMalformedTriggeredAt() {
        var alert = MetricsSnapshot.ProcessAlert(pid: 1)
        alert.triggeredAt = "not-a-date"
        XCTAssertNil(alert.sustainedMinutes)
    }
}
