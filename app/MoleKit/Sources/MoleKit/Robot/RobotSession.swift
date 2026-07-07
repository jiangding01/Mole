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
                // stderr 不解析；接诊断日志收集（§4.1）前先丢弃——
                // 挂一个无人排空的 Pipe 会在 64KB 反压时死锁子进程。
                process.standardError = FileHandle.nullDevice

                if let payload = command.stdinPayload {
                    let stdin = Pipe()
                    process.standardInput = stdin
                    stdin.fileHandleForWriting.write(payload)
                    stdin.fileHandleForWriting.closeFile()
                }

                self.process = process

                // 读取到 EOF 自然结束（进程退出会关闭写端）——绝不能在
                // terminationHandler 里取消读取任务：短命进程会在缓冲排干前
                // 就触发终止回调，事件流会永久挂起（软件页残留扫描首次踩中）。
                // 任何路径都必须 finish。
                // detached + PipeLines：解码在后台、非阻塞逐行读取（不用
                // FileHandle.bytes，其全局 IOActor 串行化会被常驻管道占死）。
                Task.detached {
                    for await line in PipeLines.lines(stdout.fileHandleForReading) {
                        Self.yieldLine(line, to: continuation)
                    }
                    continuation.finish()
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
    private static func yieldLine(_ line: Data, to continuation: AsyncThrowingStream<RobotEvent, Error>.Continuation) {
        if let event = try? RobotEventDecoder.decode(line: line) {
            continuation.yield(event)
        }
    }
}
