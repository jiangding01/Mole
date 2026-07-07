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

    public func snapshots(intervalSeconds: Int) -> AsyncThrowingStream<MetricsSnapshot, Error> {
        AsyncThrowingStream { continuation in
            do {
                let binary = try coreLocator.statusBinary()
                let process = Process()
                process.executableURL = binary
                process.arguments = ["--watch", "--interval", "\(max(1, intervalSeconds))s"]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                self.process = process

                let decoder = JSONDecoder()
                let readTask = Task {
                    var buffer = Data()
                    for try await byte in stdout.fileHandleForReading.bytes {
                        if byte == UInt8(ascii: "\n") {
                            if !buffer.isEmpty {
                                if let snapshot = try? decoder.decode(MetricsSnapshot.self, from: buffer) {
                                    continuation.yield(snapshot)
                                }
                                // 解码失败的行静默跳过：watch 流偶发诊断行不致命。
                                buffer.removeAll(keepingCapacity: true)
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    continuation.finish()
                }

                process.terminationHandler = { _ in readTask.cancel() }
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
