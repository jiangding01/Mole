import XCTest
@testable import MoleKit

/// AnalyzeSession 协议路由回归：假引擎脚本回放 NDJSON，验证按 id 路由、
/// scan_done 收尾、error 抛错、引擎退出不挂起。
final class AnalyzeSessionTests: XCTestCase {
    /// 假引擎：忽略 stdin 请求内容，直接回放固定事件流。
    private func makeFakeEngine(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("molekit-analyze-\(UUID().uuidString)")
        // CoreBundleLocator.analyzeBinary 在 mole 同级或 bin/ 下找 analyze-go
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mole = dir.appendingPathComponent("mole")
        try "#!/bin/sh\nexit 0\n".write(to: mole, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mole.path)
        let engine = dir.appendingPathComponent("analyze-go")
        let body = "#!/bin/sh\n" + "read _line\n"
            + lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        return mole
    }

    private func collect(mole: URL, path: String = "/tmp") async throws -> [AnalyzeSession.Event] {
        let session = AnalyzeSession(coreLocator: CoreBundleLocator(overridePath: mole.path))
        defer { session.stop() }
        var events: [AnalyzeSession.Event] = []
        for try await event in session.scan(path: path) {
            events.append(event)
        }
        return events
    }

    func testRoutesNodesAndFinishesOnDone() async throws {
        let mole = try makeFakeEngine(lines: [
            #"{"event":"scan_progress","id":"q1","files":10,"dirs":2,"bytes":4096,"current":"/tmp/x"}"#,
            #"{"event":"node","id":"q1","name":"docs","path":"/tmp/docs","size":3000,"is_dir":true,"cleanable":false}"#,
            #"{"event":"node","id":"q1","name":"a.txt","path":"/tmp/a.txt","size":500,"is_dir":false,"cleanable":false}"#,
            #"{"event":"scan_done","id":"q1","dir":"/tmp","total_size":3500,"item_count":2,"cached":false}"#,
        ])
        let events = try await collect(mole: mole)
        XCTAssertEqual(events.count, 4)
        guard case let .progress(progress) = events[0] else { return XCTFail("expected progress") }
        XCTAssertEqual(progress.files, 10)
        guard case let .node(node) = events[1] else { return XCTFail("expected node") }
        XCTAssertEqual(node.name, "docs")
        XCTAssertTrue(node.isDir)
        guard case let .done(_, totalSize, itemCount, cached) = events[3] else { return XCTFail("expected done") }
        XCTAssertEqual(totalSize, 3500)
        XCTAssertEqual(itemCount, 2)
        XCTAssertFalse(cached)
    }

    func testEngineErrorThrows() async throws {
        let mole = try makeFakeEngine(lines: [
            #"{"event":"error","id":"q1","message":"permission denied"}"#,
        ])
        do {
            _ = try await collect(mole: mole)
            XCTFail("expected engine error")
        } catch let AnalyzeSession.SessionError.engine(message) {
            XCTAssertTrue(message.contains("permission denied"))
        }
    }

    func testEngineExitWithoutDoneThrowsTerminated() async throws {
        // 引擎回放一条 node 后退出（无 scan_done）：流必须以 terminated 收尾而非挂起
        let mole = try makeFakeEngine(lines: [
            #"{"event":"node","id":"q1","name":"x","path":"/tmp/x","size":1,"is_dir":false,"cleanable":false}"#,
        ])
        do {
            _ = try await collect(mole: mole)
            XCTFail("expected terminated error")
        } catch AnalyzeSession.SessionError.terminated {
            // 期望路径
        }
    }
}
