import Foundation

/// robot 子进程会话：spawn → NDJSON 行流 → RobotEvent 异步序列。
/// 生命周期约定见设计 §4.4：取消 = SIGTERM；超时兜底；stderr 只进诊断日志。
///
/// 骨架状态：接口与解码路径已定，进程细节（超时、背压上限、崩溃对账）
/// 在 Phase 1 按 §4.4 补齐并配单测（假子进程脚本 mock）。
public final class RobotSession {
    public struct Command: Sendable {
        public var domain: String
        public var verb: String
        public var arguments: [String]
        /// 走 stdin 的请求文档（如 apply 的 {"plan_id":…,"ids":[…]}）。
        public var stdinPayload: Data?

        public init(domain: String, verb: String, arguments: [String] = [], stdinPayload: Data? = nil) {
            self.domain = domain
            self.verb = verb
            self.arguments = arguments
            self.stdinPayload = stdinPayload
        }
    }

    private let coreLocator: CoreBundleLocator
    private var process: Process?

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    /// 启动 `mole robot <domain> <verb> …` 并流式产出事件。
    /// 破坏性操作的全局串行（OperationGate）由调用方 Store 层保证（设计 §3.3）。
    public func run(_ command: Command) -> AsyncThrowingStream<RobotEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let moleURL = try coreLocator.moleEntrypoint()
                let process = Process()
                process.executableURL = moleURL
                process.arguments = ["robot", command.domain, command.verb] + command.arguments

                let stdout = Pipe()
                process.standardOutput = stdout
                // stderr 不解析，Phase 1 接诊断日志收集（§4.1）。
                process.standardError = Pipe()

                if let payload = command.stdinPayload {
                    let stdin = Pipe()
                    process.standardInput = stdin
                    stdin.fileHandleForWriting.write(payload)
                    stdin.fileHandleForWriting.closeFile()
                }

                self.process = process

                let lineTask = Task {
                    var buffer = Data()
                    for try await chunk in stdout.fileHandleForReading.bytes {
                        buffer.append(chunk)
                        if chunk == UInt8(ascii: "\n") {
                            if buffer.count > 1 {
                                let line = buffer.dropLast()
                                continuation.yield(try RobotEventDecoder.decode(line: Data(line)))
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish()
                }

                process.terminationHandler = { _ in
                    lineTask.cancel()
                }

                continuation.onTermination = { [weak self] _ in
                    self?.cancel()
                }

                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// 取消：SIGTERM（apply 阶段核心侧完成当前单项后退出，见 §4.4）。
    public func cancel() {
        process?.terminate()
    }
}
