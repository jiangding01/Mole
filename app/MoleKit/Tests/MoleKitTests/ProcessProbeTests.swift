import XCTest
@testable import MoleKit

/// 用自身进程验证探测器：无需 mock，所有字段对自己必然可读。
final class ProcessProbeTests: XCTestCase {
    func testProbeSelf() {
        let pid = getpid()
        let probe = ProcessProber.probe(pid: pid)

        XCTAssertEqual(probe.chain.last?.pid, pid, "链的末端应是目标进程")
        XCTAssertGreaterThanOrEqual(probe.chain.count, 2, "至少含父进程")
        XCTAssertNotNil(probe.executablePath)
        XCTAssertNotNil(probe.user)
        XCTAssertNotNil(probe.startTime)
        XCTAssertGreaterThan(probe.threadCount ?? 0, 0)
        XCTAssertGreaterThan(probe.openFileCount ?? 0, 0)
        XCTAssertNotNil(probe.workingDirectory)
    }

    func testProbeGonePidHasNoDetails() {
        // pid 99999 大概率不存在；即便存在也只验证不崩溃
        let probe = ProcessProber.probe(pid: 99999)
        XCTAssertNotNil(probe) // 不崩溃即可
    }

    func testExecutablePathOfLaunchd() {
        // launchd 是别的用户（root）的进程：路径可能拿不到，但绝不能崩
        _ = ProcessProber.executablePath(1)
    }
}
