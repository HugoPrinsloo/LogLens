import Darwin
import Foundation

/// Maps a loopback TCP source port to the process that owns it, via libproc.
/// Used to attribute proxied connections to an app and to decide whether to decrypt them.
enum ProcessLookup {

    struct Owner {
        let pid: Int32
        let path: String
        var name: String { (path as NSString).lastPathComponent }
        /// Simulator apps live under ~/Library/Developer/CoreSimulator/Devices; runtime daemons under a CoreSimulator runtime root.
        var isSimulator: Bool { path.contains("/CoreSimulator/") }
    }

    private static let lock = NSLock()
    /// Recently matched PIDs are scanned first; app connections cluster by process.
    private static var recent: [Int32] = []

    static func owner(ofLocalPort port: UInt16) -> Owner? {
        lock.lock(); let hot = recent; lock.unlock()
        for pid in hot where pidOwns(port: port, pid: pid) { return makeOwner(pid) }

        var size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.stride + 32)
        size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        let count = Int(size) / MemoryLayout<Int32>.stride
        // Newest processes have the highest PIDs and are listed last; walk backwards.
        for i in stride(from: count - 1, through: 0, by: -1) {
            let pid = pids[i]
            guard pid > 0, !hot.contains(pid), pidOwns(port: port, pid: pid) else { continue }
            lock.lock()
            recent.removeAll { $0 == pid }
            recent.insert(pid, at: 0)
            if recent.count > 16 { recent.removeLast() }
            lock.unlock()
            return makeOwner(pid)
        }
        return nil
    }

    private static func makeOwner(_ pid: Int32) -> Owner {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return Owner(pid: pid, path: n > 0 ? String(cString: buf) : "")
    }

    private static func pidOwns(port: UInt16, pid: Int32) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard needed > 0 else { return false }
        let n = Int(needed) / stride
        var info = socket_fdinfo()
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for i in 0..<n where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            let got = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize)
            guard got == infoSize, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let local = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian
            if local == port { return true }
        }
        return false
    }
}
