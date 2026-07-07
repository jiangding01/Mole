import XCTest
@testable import MoleKit

/// RobotSession 子进程流回归。核心场景：**瞬间退出的进程**——
/// 曾经 terminationHandler 抢在读取任务排干缓冲前取消它，取消异常
/// 跳过 finish()，事件流永久挂起（软件页残留扫描首次踩中）。
final class RobotSessionTests: XCTestCase {
    /// 写一个立即输出 NDJSON 并退出的假核心脚本。
    private func makeFakeCore(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("molekit-robot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("mole")
        let body = "#!/bin/sh\n" + lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func collect(_ script: URL) async throws -> [RobotEvent] {
        let session = RobotSession(coreLocator: CoreBundleLocator(overridePath: script.path))
        var events: [RobotEvent] = []
        for try await event in session.run(.init(domain: "apps", verb: "files")) {
            events.append(event)
        }
        return events
    }

    func testFastExitingProcessDeliversAllEventsAndFinishes() async throws {
        let script = try makeFakeCore(lines: [
            #"{"v":1,"event":"item","id":"ap.1","label":"~/Library/Caches/x","path":"~/Library/Caches/x","bytes":4096,"default_selected":true,"risk":"safe"}"#,
            #"{"v":1,"event":"done","ok":true,"summary":{"items":1,"bytes_total":4096}}"#,
        ])
        // 流必须结束（曾经挂死）且一个事件都不能丢
        let events = try await withThrowingTaskGroup(of: [RobotEvent].self) { group in
            group.addTask { try await self.collect(script) }
            struct StreamHung: Error {}
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw StreamHung() // 流挂死（本 bug 的历史形态）→ 测试失败
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(events.count, 2)
        guard case let .item(item) = events[0] else { return XCTFail("expected item, got \(events[0])") }
        XCTAssertEqual(item.id, "ap.1")
        XCTAssertEqual(item.defaultSelected, true)
        guard case let .done(done) = events[1] else { return XCTFail("expected done, got \(events[1])") }
        XCTAssertEqual(done.ok, true)
        XCTAssertEqual(done.summary?.items, 1)
    }

    func testUndecodableLinesAreSkippedNotFatal() async throws {
        let script = try makeFakeCore(lines: [
            "stray shell output that is not JSON",
            #"{"v":1,"event":"done","ok":true}"#,
        ])
        let events = try await collect(script)
        XCTAssertEqual(events.count, 1)
        guard case .done = events[0] else { return XCTFail("expected done, got \(events[0])") }
    }

    func testMissingTrailingNewlineStillDelivered() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("molekit-robot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("mole")
        let body = #"""
        #!/bin/sh
        printf '{"v":1,"event":"done","ok":true}'
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let events = try await collect(script)
        XCTAssertEqual(events.count, 1)
    }
}
