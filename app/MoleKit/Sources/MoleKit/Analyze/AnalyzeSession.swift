import Foundation

/// `analyze-go --serve` 常驻会话（设计 §5.4）：单进程、stdin 请求、stdout
/// NDJSON 事件，按请求 id 路由到各自的事件流。纯只读——删除走 mole robot。
public final class AnalyzeSession: @unchecked Sendable {
    public struct Node: Codable, Sendable, Identifiable, Equatable {
        public var name: String
        public var path: String
        public var size: Int64
        public var isDir: Bool
        public var cleanable: Bool
        public var lastAccess: String?

        public var id: String { path }

        enum CodingKeys: String, CodingKey {
            case name, path, size, cleanable
            case isDir = "is_dir"
            case lastAccess = "last_access"
        }
    }

    public struct Progress: Sendable, Equatable {
        public var files: Int64
        public var dirs: Int64
        public var bytes: Int64
        public var current: String
    }

    public enum Event: Sendable {
        case progress(Progress)
        case node(Node)
        case done(dir: String, totalSize: Int64, itemCount: Int, cached: Bool)
    }

    public enum SessionError: LocalizedError {
        case engine(String)
        case terminated

        public var errorDescription: String? {
            switch self {
            case let .engine(message): message
            case .terminated: "analyze 引擎已退出"
            }
        }
    }

    private let coreLocator: CoreBundleLocator
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?

    private let lock = NSLock()
    private var continuations: [String: AsyncThrowingStream<Event, Error>.Continuation] = [:]
    private var nextId = 0

    public init(coreLocator: CoreBundleLocator = CoreBundleLocator()) {
        self.coreLocator = coreLocator
    }

    // MARK: - 生命周期

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        let binary = try coreLocator.analyzeBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--serve"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // 不挂无人排空的 Pipe：stderr 写满 64KB 缓冲会反压死锁子进程
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        stdinHandle = stdin.fileHandleForWriting

        let handle = stdout.fileHandleForReading
        // detached：解码路由在后台跑。Task {} 会继承调用方的 MainActor，
        // 大扫描的逐字节流会把主线程打满（UI 计数冻结的元凶之一）。
        readTask = Task.detached { [weak self] in
            var buffer = Data()
            do {
                for try await byte in handle.bytes {
                    if byte == UInt8(ascii: "\n") {
                        if !buffer.isEmpty {
                            self?.route(line: buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch {}
            // 引擎退出：所有在途请求以 terminated 收尾（绝不挂起）
            self?.failAll(with: SessionError.terminated)
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        readTask?.cancel()
        failAll(with: SessionError.terminated)
    }

    private func failAll(with error: Error) {
        lock.lock()
        let pending = continuations
        continuations = [:]
        lock.unlock()
        for continuation in pending.values {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - 请求

    /// 扫描一层：scan（命中缓存秒回）/ rescan（强制重扫）。
    /// 流在 scan_done 后正常结束；消费方提前终止 → 发 cancel op。
    public func scan(path: String, rescan: Bool = false) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            do {
                try ensureRunning()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            lock.lock()
            nextId += 1
            let id = "q\(nextId)"
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    self?.send(op: "cancel", id: id, path: nil)
                    self?.removeContinuation(id)
                }
            }
            send(op: rescan ? "rescan" : "scan", id: id, path: path)
        }
    }

    private func send(op: String, id: String, path: String?) {
        var request: [String: String] = ["op": op, "id": id]
        if let path { request["path"] = path }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let handle = stdinHandle else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    @discardableResult
    private func removeContinuation(_ id: String) -> AsyncThrowingStream<Event, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.removeValue(forKey: id)
    }

    // MARK: - 事件路由

    private func route(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return }
        let id = object["id"] as? String ?? ""

        lock.lock()
        let continuation = continuations[id]
        lock.unlock()
        guard let continuation else { return }

        switch event {
        case "scan_progress":
            continuation.yield(.progress(Progress(
                files: int64(object["files"]), dirs: int64(object["dirs"]),
                bytes: int64(object["bytes"]), current: object["current"] as? String ?? ""
            )))
        case "node":
            if let node = try? JSONDecoder().decode(Node.self, from: line) {
                continuation.yield(.node(node))
            }
        case "scan_done":
            continuation.yield(.done(
                dir: object["dir"] as? String ?? "",
                totalSize: int64(object["total_size"]),
                itemCount: Int(int64(object["item_count"])),
                cached: object["cached"] as? Bool ?? false
            ))
            removeContinuation(id)?.finish()
        case "error":
            let message = object["message"] as? String ?? "unknown engine error"
            removeContinuation(id)?.finish(throwing: SessionError.engine(message))
        default:
            break // 前向兼容：未知事件忽略
        }
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }
}
