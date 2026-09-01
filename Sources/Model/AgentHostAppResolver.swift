import AppKit
import Darwin

/// Answers one question for the turn alarm: is the app hosting THIS session's
/// CLI the frontmost app right now? If yes, the user is already looking at the
/// reply prompt and a fullscreen alarm is noise (community report, 2026-07-15).
///
/// Resolution is per-session, not per-app-category: find `claude` / `codex`
/// processes whose working directory matches the thread's `cwd`, then walk
/// each one's parent-process chain (CLI → shell → terminal helper → app) and
/// check whether the frontmost application's pid appears in it. Terminal,
/// iTerm, VS Code, Claude desktop and ChatGPT desktop all resolve this way
/// without a hardcoded app list.
///
/// Fail-open by design: tmux/daemonized sessions re-parent to launchd, the
/// chain never reaches an app, and the alarm shows exactly as before.
enum AgentHostAppResolver {
    static func isHostAppFrontmost(
        provider: AlertEngine.Provider,
        cwd: String?,
        launchTarget: SessionLaunchTarget = .cli
    ) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        // Desktop-hosted sessions never surface in a parent chain — the app
        // drives the CLI over XPC/daemon, not as an ancestor (GH #30: alarms
        // fired over a frontmost ChatGPT/Claude Desktop). The desktop app
        // shows the finished turn in its own UI, so the alarm is redundant
        // while it is frontmost. Claude gates on the session actually being
        // desktop-hosted; Codex desktop rollouts all scan as `.cli`, so the
        // bundle check alone has to carry them.
        if let bundleId = front.bundleIdentifier {
            switch provider {
            case .claude where launchTarget == .claudeDesktop:
                if bundleId == "com.anthropic.claudefordesktop" { return true }
            case .codex:
                if bundleId == "com.openai.codex" || bundleId == "com.openai.chat" { return true }
            case .cursor:
                // Cursor is the editor AND the agent host: a finished turn is
                // already visible in the pane the user is looking at, so an
                // alarm on top of it is pure noise.
                if bundleId == "com.todesktop.230313mzl4w4u92" { return true }
            default:
                break
            }
        }
        guard let cwd, !cwd.isEmpty else { return false }
        // Cursor has no CLI: scanning for a stand-in process name would
        // suppress alarms whenever any codex process runs. No CLI, no match.
        guard let cliName = provider.cliName else { return false }
        let target = normalize(cwd)
        for pid in cliPids(named: cliName) {
            guard let processCwd = workingDirectory(of: pid),
                  normalize(processCwd) == target else { continue }
            if ancestorPids(of: pid).contains(front.processIdentifier) { return true }
        }
        return false
    }

    /// All live pids whose executable's last path component matches `name`.
    private static func cliPids(named name: String) -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 4 * 1024)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return (String(cString: buffer) as NSString).lastPathComponent == name
        }
    }

    /// The process's current working directory (same-user processes only,
    /// which is all we need — the CLI runs as the user).
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Parent pids walking up from `pid` (excluding launchd). Capped so a
    /// cyclic table read can never spin.
    private static func ancestorPids(of pid: pid_t) -> Set<pid_t> {
        var ancestors = Set<pid_t>()
        var current = pid
        for _ in 0..<24 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { break }
            ancestors.insert(parent)
            current = parent
        }
        return ancestors
    }

    /// `/tmp` and `/private/tmp` (and trailing slashes) must compare equal —
    /// the transcript records the logical path, the kernel reports the real one.
    private static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }
}
