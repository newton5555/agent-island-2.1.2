import Darwin
import Foundation

/// libproc/sysctl primitives shared by everything that needs to reason about
/// running CLI sessions — Antigravity's port discovery and the alarm
/// navigator's "front the terminal that already hosts this session" path.
/// All in-process: shelling out to `ps`/`lsof` on every refresh tick would
/// fork for the life of the app.
enum ProcessTree {
    static func allPIDs() -> [pid_t] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, capacity)
        guard used > 0 else { return [] }
        return buffer.prefix(Int(used) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not surfaced to Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Processes whose executable's file name matches exactly. Exact, not
    /// substring — `/usr/bin/legacy` must never match "agy".
    static func pids(named names: Set<String>) -> [pid_t] {
        allPIDs().filter { pid in
            let path = executablePath(pid)
            guard !path.isEmpty else { return false }
            return names.contains((path as NSString).lastPathComponent)
        }
    }

    /// The process's current working directory, kernel-resolved (so /tmp
    /// reads as /private/tmp). Used to match a running CLI to the session
    /// an alarm points at.
    static func currentWorkingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// Walks up the process tree to the GUI application that owns this
    /// process's terminal session — Terminal, iTerm, Ghostty, VS Code,
    /// whatever the user runs the CLI inside. The `.app/Contents/MacOS/`
    /// marker separates an application from the shells in between (cli ←
    /// zsh ← login ← Terminal). A headless process (launchd, CI) never
    /// reaches one and returns nil, which is exactly the "nothing to front"
    /// answer.
    ///
    /// The parent hop uses sysctl, not proc_pidinfo: Terminal's `login`
    /// intermediary runs as root, proc_pidinfo denies it to a user process,
    /// and the walk died right there on the owner's machine (2026-08-09).
    /// The kinfo_proc table is world-readable.
    static func owningGUIApplication(_ pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<12 {
            if executablePath(current).contains(".app/Contents/MacOS/") { return current }
            guard let parent = parentPID(current), parent > 1, parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
