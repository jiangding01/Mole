import Foundation

/// 管道行流：readabilityHandler 驱动的非阻塞 NDJSON 读取。
///
/// 不用 `FileHandle.bytes`——它的 AsyncBytes 在 Foundation 里把阻塞 read(2)
/// 串行化到一个全局 IOActor 上：任何一条空闲的长连管道（如 analyze --serve
/// 等下一个请求时）会让自己的读取端一直阻塞在 read() 里，占住该 actor，
/// 其他所有 `.bytes` 流（状态页指标流、robot 事件流）随之饿死。
/// Store 提升为会话常驻后 analyze 引擎不再随切页退出，这个串行化第一次
/// 暴露成"状态页永久 loading"。readabilityHandler 由 GCD 回调驱动、
/// 每条管道独立，无共享阻塞点。
public enum PipeLines {
    /// 把 handle 的输出切成行（不含换行符，空行跳过）；EOF 后正常结束。
    /// 消费方取消（onTermination）即撤下 handler，停止读取。
    public static func lines(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            // buffer 只在 readabilityHandler 的串行回调队列上读写
            var buffer = Data()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { // EOF：写端全部关闭
                    h.readabilityHandler = nil
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer.subdata(in: buffer.startIndex ..< newline)
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    if !line.isEmpty { continuation.yield(line) }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}
