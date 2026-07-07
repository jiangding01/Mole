import Darwin
import Foundation

/// 进程详情弹窗的原生探测数据（设计 §9.6 的"更丰富详情"）。
/// 全部来自本机 syscall（libproc / sysctl），同用户进程无需 root；
/// 拿不到的字段保持 nil，UI 层按"不显示假数据"原则省略对应行。
/// `status-go --proc` 落地后可切换为核心输出，字段口径保持一致。
public struct ProcessProbe: Sendable {
    public struct ChainLink: Sendable {
        public var pid: Int32
        public var name: String
    }

    /// launchd → … → 目标进程 的完整祖先链（首元素是 launchd）。
    public var chain: [ChainLink]
    public var user: String?
    public var startTime: Date?
    public var threadCount: Int?
    public var openFileCount: Int?
    public var diskBytesRead: UInt64?
    public var diskBytesWritten: UInt64?
    public var workingDirectory: String?
    public var executablePath: String?
    /// 完整命令行（KERN_PROCARGS2；跨用户进程通常拿不到）。
    public var arguments: String?
}

public enum ProcessProber {
    public static func probe(pid: Int32) -> ProcessProbe {
        let exec = executablePath(pid)
        var probe = ProcessProbe(
            chain: ancestorChain(of: pid),
            user: nil, startTime: nil, threadCount: nil, openFileCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, workingDirectory: nil,
            executablePath: exec, arguments: rawCommand(pid)
        )
        if let info = kinfo(pid) {
            probe.user = userName(uid: info.kp_eproc.e_ucred.cr_uid)
            let tv = info.kp_proc.p_starttime
            if tv.tv_sec > 0 {
                probe.startTime = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
            }
        }
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
            probe.threadCount = Int(task.pti_threadnum)
        }
        let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if fdBytes > 0 {
            probe.openFileCount = Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
        }
        var usage = rusage_info_current()
        let usageOK = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) == 0
            }
        }
        if usageOK {
            probe.diskBytesRead = usage.ri_diskio_bytesread
            probe.diskBytesWritten = usage.ri_diskio_byteswritten
        }
        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) > 0 {
            let dir = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if !dir.isEmpty { probe.workingDirectory = dir }
        }
        return probe
    }

    /// 可执行文件真实路径（proc_pidpath；不受命令行里空格路径影响）。
    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - 私有

    private static func ancestorChain(of pid: Int32) -> [ProcessProbe.ChainLink] {
        var chain: [ProcessProbe.ChainLink] = []
        var current = pid
        var depth = 0
        while current > 0, depth < 20 {
            chain.append(.init(pid: current, name: displayName(current)))
            if current == 1 { break }
            guard let info = kinfo(current) else { break }
            let ppid = info.kp_eproc.e_ppid
            if ppid == current || ppid < 0 { break }
            current = ppid
            depth += 1
        }
        return chain.reversed()
    }

    private static func displayName(_ pid: Int32) -> String {
        if let path = executablePath(pid) {
            return (path as NSString).lastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: 128)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return pid == 1 ? "launchd" : "pid \(pid)"
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    private static func userName(uid: uid_t) -> String? {
        guard let pw = getpwuid(uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    private static func rawCommand(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func readCString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let string = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return string
        }
        _ = readCString() // exec 路径，后随对齐 NUL
        while index < size, buffer[index] == 0 { index += 1 }
        var parts: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let arg = readCString() else { break }
            parts.append(arg)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
