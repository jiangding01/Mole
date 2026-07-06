import XCTest

@testable import MoleKit

/// Robot Protocol v1 解码契约测试（设计 §11.1）。
/// M0 落地后，本文件的内联样本替换为 CLI 仓库 `contracts/*.ndjson` golden 文件，
/// 两端共享同一批样本——协议改动必须同时更新 golden 与两端测试。
final class RobotEventDecodingTests: XCTestCase {
    private func decode(_ line: String) throws -> RobotEvent {
        try RobotEventDecoder.decode(line: Data(line.utf8))
    }

    func testDecodesProgress() throws {
        let line = #"{"v":1,"event":"progress","phase":"scan","section":"app_caches","current":"~/Library/Caches/x","done":36,"total":129,"bytes_found":331350016}"#
        guard case let .progress(progress) = try decode(line) else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(progress.section, "app_caches")
        XCTAssertEqual(progress.bytesFound, 331_350_016)
    }

    func testDecodesItemWithRiskAndI18nKeys() throws {
        let line = #"{"v":1,"event":"item","id":"cl.app_caches.7f3a9c","section":"app_caches","label":"Chrome GPU Cache","path":"~/Library/Caches/Google/Chrome/GPUCache","bytes":58720256,"kind":"cache","reversible":true,"default_selected":true,"risk":"safe","detail":"rebuilt on relaunch","detail_key":"rebuilt_on_relaunch"}"#
        guard case let .item(item) = try decode(line) else {
            return XCTFail("expected item")
        }
        XCTAssertEqual(item.id, "cl.app_caches.7f3a9c")
        XCTAssertEqual(item.risk, "safe")
        XCTAssertEqual(item.defaultSelected, true)
        XCTAssertEqual(item.detailKey, "rebuilt_on_relaunch")
    }

    func testDecodesResultAndDone() throws {
        let result = #"{"v":1,"event":"result","id":"cl.a.1","status":"trashed","freed_bytes":1024}"#
        guard case let .result(res) = try decode(result) else {
            return XCTFail("expected result")
        }
        XCTAssertEqual(res.status, "trashed")

        let done = #"{"v":1,"event":"done","ok":true,"plan_id":"pl_x","summary":{"items":2,"freed_bytes":2048,"failed":0}}"#
        guard case let .done(d) = try decode(done) else {
            return XCTFail("expected done")
        }
        XCTAssertEqual(d.planId, "pl_x")
        XCTAssertEqual(d.summary?.freedBytes, 2048)
    }

    func testDecodesErrorCodes() throws {
        let line = #"{"v":1,"event":"error","code":"E_PLAN_EXPIRED","message":"plan expired","fatal":true}"#
        guard case let .error(err) = try decode(line) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(err.code, "E_PLAN_EXPIRED")
        XCTAssertEqual(err.fatal, true)
    }

    func testRejectsUnsupportedVersion() {
        let line = Data(#"{"v":2,"event":"done","ok":true}"#.utf8)
        XCTAssertThrowsError(try RobotEventDecoder.decode(line: line)) { error in
            XCTAssertEqual(error as? RobotEventDecodingError, .unsupportedVersion(2))
        }
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try RobotEventDecoder.decode(line: Data("not json".utf8)))
    }
}

final class ScanSessionTests: XCTestCase {
    func testPlanExpiresAfterTTL() {
        let session = ScanSession()
        let plan = ScanSession.DomainPlan(
            planId: "pl_1", items: [], insights: [],
            createdAt: Date(timeIntervalSinceNow: -31 * 60)
        )
        session.store(plan, for: .clean)
        XCTAssertNil(session.activePlan(for: .clean))
    }

    func testInvalidateOnlyAffectsOneDomain() {
        let session = ScanSession()
        let fresh = ScanSession.DomainPlan(planId: "pl_2", items: [], insights: [], createdAt: Date())
        session.store(fresh, for: .clean)
        session.store(fresh, for: .installer)
        session.invalidate(.clean)
        XCTAssertNil(session.activePlan(for: .clean))
        XCTAssertNotNil(session.activePlan(for: .installer))
    }
}
