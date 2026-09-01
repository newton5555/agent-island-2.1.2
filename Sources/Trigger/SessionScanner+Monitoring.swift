import Foundation

extension SessionScanner {
    private static let monitoringCodexLimit = 120

    static func monitoringScan(now: Date = Date(), lastWorking: [String: Date] = [:]) -> [ScannedSession] {
        var out = scanClaudeTranscripts(now: now, lastWorking: lastWorking)
        out += scanCodex(
            now: now,
            lastWorking: lastWorking,
            limit: monitoringCodexLimit,
            dedupeProjects: false
        )
        out += scanGrok(now: now, lastWorking: lastWorking)
        out += scanAntigravity(now: now, lastWorking: lastWorking)
        out += scanCursor(now: now, lastWorking: lastWorking)
        out.sort { $0.modified > $1.modified }
        return out
    }

    private static func scanClaudeTranscripts(now: Date, lastWorking: [String: Date]) -> [ScannedSession] {
        let desktopSessions = claudeDesktopIndex()
        // Drop transcripts that cannot produce anything but .idle before paying
        // for their I/O. `sessionState` returns .idle outright once the session
        // is older than `attentionWindow`, yet reaching that early return still
        // costs a 128 KiB tail read plus a 64 KiB cwd probe per file — on a
        // machine with 33k transcripts that is ~6 GB of reads on EVERY 6 s tick,
        // which pins several cores and gets the process jetsam-killed.
        //
        // stat(2) is the cheapest way to tell the two apart. The desktop store's
        // `lastActivityAt` can legitimately run ahead of the transcript's own
        // mtime (it is written as turn-completion bookkeeping), so a session is
        // only skipped when BOTH clocks are outside the window — keeping this
        // strictly equivalent to scanning everything.
        let cutoff = now.addingTimeInterval(-attentionWindow)
        return claudeTranscriptIndex().compactMap { sid, path -> ScannedSession? in
            let desktop = desktopSessions[sid]
            guard mtime(path) > cutoff || (desktop?.lastActivityAt ?? .distantPast) > cutoff else {
                return nil
            }
            let cwd = desktop.flatMap { $0.cwd.isEmpty ? nil : $0.cwd }
                ?? cwdFromClaudeTranscript(path)
            let title = desktop?.title ?? ""
            let state = sessionState(
                for: path,
                now: now,
                lastWorking: lastWorking,
                externalActivityDate: desktop?.lastActivityAt,
                turnState: SessionTurnState.claude
            )
            return ScannedSession(
                tool: .claude,
                sessionId: sid,
                cwd: cwd,
                label: title.isEmpty ? fallback(cwd, sid) : title,
                modified: state.modified,
                status: state.status,
                transcriptPath: path,
                turnKey: state.turnKey,
                launchTarget: desktop == nil ? .cli : .claudeDesktop
            )
        }
    }

    private static func claudeDesktopIndex() -> [String: (title: String, cwd: String, lastActivityAt: Date?)] {
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [:] }
        var out: [String: (title: String, cwd: String, lastActivityAt: Date?)] = [:]
        for case let rel as String in enumerator
        where rel.hasSuffix(".json") && (rel as NSString).lastPathComponent.hasPrefix("local_") {
            let path = root + "/" + rel
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = object["cliSessionId"] as? String,
                  !sid.isEmpty
            else { continue }
            let ms = object["lastActivityAt"] as? Double
            out[sid] = (
                object["title"] as? String ?? "",
                object["cwd"] as? String ?? "",
                ms.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        return out
    }

    /// The transcript itself records the true working directory on nearly
    /// every entry ("cwd"). The encoded folder name is lossy — dashes that
    /// belong to the real path (~/agent-island) un-munge into a wrong
    /// directory, which then breaks `claude --resume` from that cwd.
    private static func cwdFromClaudeTranscript(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return projectFromClaudeTranscript(path)
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 65_536)
        // Lenient decode: a fixed-size read can split a multi-byte UTF-8
        // sequence at the tail, and strict decoding would fail the whole
        // buffer — discarding a valid cwd on line 1. U+FFFD lands only on
        // the truncated final line, which the loop never reaches.
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", maxSplits: 30, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = object["cwd"] as? String,
                  !cwd.isEmpty
            else { continue }
            return cwd
        }
        return projectFromClaudeTranscript(path)
    }

    /// Display-only fallback when the transcript carries no cwd.
    private static func projectFromClaudeTranscript(_ path: String) -> String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let name = parent.replacingOccurrences(of: "-", with: "/")
        return name.isEmpty ? "" : "/" + name
    }
}
