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

                // 读取到 EOF 自然结束（进程退出会关闭写端）——绝不能在
                // terminationHandler 里取消读取任务：短命进程会在缓冲排干前
                // 就触发终止回调，取消抛出后 finish 不会执行，事件流永久挂起
                // （软件页残留扫描首次踩中）。任何路径都必须 finish。
                Task {
                    do {
                        var buffer = Data()
                        for try await byte in stdout.fileHandleForReading.bytes {
                            if byte == UInt8(ascii: "\n") {
                                if !buffer.isEmpty {
                                    yieldLine(buffer, to: continuation)
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            } else {
                                buffer.append(byte)
                            }
                        }
                        if !buffer.isEmpty { yieldLine(buffer, to: continuation) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
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

    /// 单行解码。无法解码的行跳过（前向兼容：未知事件/杂散输出不拖垮整条流），
    /// 调用方以 done 事件判断流是否完整（见 AppsStore.fetchLeftovers）。
    private func yieldLine(_ line: Data, to continuation: AsyncThrowingStream<RobotEvent, Error>.Continuation) {
        if let event = try? RobotEventDecoder.decode(line: line) {
            continuation.yield(event)
        }
    }
}
