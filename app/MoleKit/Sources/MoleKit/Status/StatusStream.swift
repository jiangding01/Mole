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

                continuation.onTermination = { [weak self] _ in self?.stop() }

                // 先 run 再起读取任务：detached 任务是立即开跑的（不像继承
                // MainActor 的 Task {} 要排队等 run() 所在的主线程代码走完），
                // 读取先于进程启动会时序倒置（AnalyzeSession 同一形状，先 run）。
                try process.run()

                // detached + PipeLines：解码在后台、逐行非阻塞读取（见
                // PipeLines 注释——FileHandle.bytes 的全局 IOActor 串行化
                // 会被常驻 analyze 引擎的空闲管道占死，状态页因此饿死）。
                // 读到 EOF 自然收尾，任何路径都必须 finish，绝不留下挂起的流。
                Task.detached {
                    let decoder = JSONDecoder()
                    var yieldedAny = false
                    for await line in PipeLines.lines(stdout.fileHandleForReading) {
                        // 解码失败的行静默跳过：watch 流偶发诊断行不致命。
                        if let snapshot = try? decoder.decode(MetricsSnapshot.self, from: line) {
                            continuation.yield(snapshot)
                            yieldedAny = true
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
