import Foundation

/// 订阅 `status-go --watch --interval Ns` 的 NDJSON 指标流（设计 §5.5）。
/// 生命周期由调用方（StatusStore）管理：页面可见启动、离开停止；
/// 断流由消费端检测（超过 2×interval 无快照即视为断连并重启）。
public final class StatusStream {
    private let coreLocator: CoreBundleLocator
    private var process: Process?

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    public enum StreamError: Error, LocalizedError {
        /// 子进程异常退出（如旧版 status-go 不认识新 flag）。附退出码与 stderr 尾部。
        case processFailed(exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case let .processFailed(code, stderr):
                return "status-go 退出（\(code)）：\(stderr.isEmpty ? "无错误输出" : stderr)"
            }
        }
    }

    public func snapshots(intervalSeconds: Int) -> AsyncThrowingStream<MetricsSnapshot, Error> {
        AsyncThrowingStream { continuation in
            do {
                let binary = try coreLocator.statusBinary()
                let process = Process()
                process.executableURL = binary
                // --top-procs：进程表最多 50 条（设计 §5.5；CLI 默认 5 仅供 TUI）。
                process.arguments = ["--watch", "--interval", "\(max(1, intervalSeconds))s", "--top-procs", "50"]
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                self.process = process

                let decoder = JSONDecoder()
                // detached：解码在后台跑（Task {} 会继承调用方 MainActor；
                // 50 进程的快照行不小，且 EOF 后的 waitUntilExit 不能占主线程）。
                let readTask = Task.detached {
                    var buffer = Data()
                    var yieldedAny = false
                    for try await byte in stdout.fileHandleForReading.bytes {
                        if byte == UInt8(ascii: "\n") {
                            if !buffer.isEmpty {
                                if let snapshot = try? decoder.decode(MetricsSnapshot.self, from: buffer) {
                                    continuation.yield(snapshot)
                                    yieldedAny = true
                                }
                                // 解码失败的行静默跳过：watch 流偶发诊断行不致命。
                                buffer.removeAll(keepingCapacity: true)
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    // 流结束：若进程失败且从未产出快照，把 stderr 报给上层
                    // （典型场景：旧二进制不认识 --top-procs，flag 报错即退）。
                    process.waitUntilExit()
                    if !yieldedAny, process.terminationStatus != 0 {
                        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let tail = String(data: errData.suffix(400), encoding: .utf8) ?? ""
                        continuation.finish(throwing: StreamError.processFailed(
                            exitCode: process.terminationStatus,
                            stderr: tail.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    } else {
                        continuation.finish()
                    }
                }

                process.terminationHandler = { _ in
                    // 不 cancel readTask：让它读尽残余输出后自然走 finish 分支。
                    _ = readTask
                }
                continuation.onTermination = { [weak self] _ in self?.stop() }

                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
    }
}
