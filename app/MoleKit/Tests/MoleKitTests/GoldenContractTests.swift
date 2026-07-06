import XCTest

@testable import MoleKit

/// 双端共享的协议契约测试（设计 §11.1）。
/// golden 文件位于仓库根 `contracts/robot_v1/*.ndjson`，由 CLI 侧
/// `tests/robot_core.bats` 用同一批文件做 schema 校验——协议改动必须
/// 同时更新 golden 与两端测试。
/// 注意：monorepo 布局下用 #filePath 定位仓库根；拆分仓库后 golden
/// 随核心版本进入 CoreBundle，届时改由 fetch_core.sh 带入。
final class GoldenContractTests: XCTestCase {
    private func goldenDirectory() -> URL {
        // <repo>/app/MoleKit/Tests/MoleKitTests/GoldenContractTests.swift
        // -> <repo>/contracts/robot_v1
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MoleKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MoleKit
            .deletingLastPathComponent() // app
            .appendingPathComponent("contracts/robot_v1")
    }

    private func goldenLines(_ name: String) throws -> [Data] {
        let url = goldenDirectory().appendingPathComponent(name)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("golden file not found at \(url.path) — split-repo layout? see header comment")
        }
        return content.split(separator: "\n").map { Data($0.utf8) }
    }

    func testCleanPlanGoldenDecodes() throws {
        let lines = try goldenLines("clean_plan.ndjson")
        XCTAssertFalse(lines.isEmpty)

        var items = 0
        var sawDone = false
        for line in lines {
            let event = try RobotEventDecoder.decode(line: line)
            switch event {
            case let .item(item):
                items += 1
                XCTAssertFalse(item.id.isEmpty)
                XCTAssertNotNil(item.bytes)
                XCTAssertEqual(item.risk, "safe")
            case let .done(done):
                sawDone = true
                XCTAssertEqual(done.ok, true)
                XCTAssertNotNil(done.planId)
                XCTAssertEqual(done.summary?.items, items)
            case .progress, .insight:
                break
            default:
                XCTFail("unexpected event in clean_plan golden")
            }
        }
        XCTAssertTrue(sawDone)
    }

    func testCleanApplyGoldenCoversAllResultStatuses() throws {
        let lines = try goldenLines("clean_apply.ndjson")

        var statuses = Set<String>()
        var errorCodes = Set<String>()
        for line in lines {
            switch try RobotEventDecoder.decode(line: line) {
            case let .result(result): statuses.insert(result.status)
            case let .error(error): errorCodes.insert(error.code)
            case .done: break
            default: XCTFail("unexpected event in clean_apply golden")
            }
        }
        // The golden set must exercise every documented result status (§4.3)
        // so a decoder regression on any of them fails here.
        let documented: Set<String> = [
            "trashed", "skipped_missing", "skipped_protected",
            "skipped_whitelisted", "dry_run", "failed",
        ]
        XCTAssertTrue(documented.isSubset(of: statuses), "missing statuses: \(documented.subtracting(statuses))")
        XCTAssertTrue(errorCodes.contains("E_PLAN_EXPIRED"))
    }
}
