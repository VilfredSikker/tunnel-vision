import AppKit
import Darwin
import Foundation

/// Finds the terminal app that hosts the herdr client, so herdr rules can
/// carry its bundle id and the app-level lock lets the terminal live.
enum HerdrHost {
    /// Bundle id of the regular (Dock-visible) app whose process tree
    /// contains a `herdr` client. The server's tree ends at launchd and is
    /// skipped naturally.
    @MainActor
    static func terminalBundleID() -> String? {
        for pid in allPIDs() where processName(pid) == "herdr" {
            var current = parentPID(pid)
            var hops = 0
            while current > 1, hops < 12 {
                if let app = NSRunningApplication(processIdentifier: current),
                   app.activationPolicy == .regular,
                   let bundle = app.bundleIdentifier {
                    return bundle
                }
                current = parentPID(current)
                hops += 1
            }
        }
        return nil
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let bytes = proc_listallpids(&pids, capacity)
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids[..<count]).filter { $0 > 0 }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func processName(_ pid: pid_t) -> String? {
        guard var info = bsdInfo(pid) else { return nil }
        return withUnsafePointer(to: &info.pbi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        guard let info = bsdInfo(pid) else { return 0 }
        return pid_t(info.pbi_ppid)
    }
}
