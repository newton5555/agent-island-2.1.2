import Foundation
import SQLite3

/// A resumable session discovered on disk, for the trigger picker.
struct ScannedSession: Identifiable, Hashable {
    var id: String { tool.rawValue + ":" + sessionId }
    let tool: TriggerTool
    let sessionId: String   // the id passed to `--resume` / `exec resume`
    let cwd: String
    let label: String       // clean display name
    let modified: Date
    let status: ActivityMonitor.State
    let transcriptPath: String?
    let turnKey: String?
    let launchTarget: SessionLaunchTarget
}

enum SessionLaunchTarget: Hashable {
    case cli
    case claudeDesktop
}

enum SessionScanner {
    private static let activeWindow: TimeInterval = 18
    private static let stallAfter: TimeInterval = 5 * 60
    private static let stallCap: TimeInterval = 15 * 60
    private static let needsYouCap: TimeInterval = 20 * 60
    /// How long a guest transcript must sit unchanged, after visible
    /// activity, before quiet counts as turn-done. Streaming writes land
    /// every few seconds; approval waits and finishes go silent for good.
    private static let guestQuietAfter: TimeInterval = 25
    static let attentionWindow: TimeInterval = 30 * 60
    private static let desktopBookkeepingGrace: TimeInterval = 25

    static func scan(now: Date = Date(), lastWorking: [String: Date] = [:]) -> [ScannedSession] {
        var out = scanClaude(now: now, lastWorking: lastWorking)
        out += scanCodex(now: now, lastWorking: lastWorking)
        out += scanGrok(now: now, lastWorking: lastWorking)
        out += scanAntigravity(now: now, lastWorking: lastWorking)
        out += scanCursor(now: now, lastWorking: lastWorking)
        out.sort { $0.modified > $1.modified }
        // Dedupe by session: the Claude desktop store commonly holds the SAME
        // cliSessionId under two project folders (23 of 41 on the reporting
        // machine), so a raw file scan lists every such session twice in the
        // trigger picker. Sorted newest-first, keep the first sighting of each
        // (tool, sessionId).
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.tool.rawValue):\($0.sessionId)").inserted }
        return out
    }

    // MARK: - Claude: desktop session store (titles + archived flag)

    private static func scanClaude(now: Date, lastWorking: [String: Date]) -> [ScannedSession] {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        let transcripts = claudeTranscriptIndex()
        var out: [ScannedSession] = []
        for case let rel as String in enumerator
        where rel.hasSuffix(".json") && (rel as NSString).lastPathComponent.hasPrefix("local_") {
            let path = root + "/" + rel
            guard let data = fm.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Skip archived threads — the picker only lists active ones.
            if object["isArchived"] as? Bool == true { continue }
            guard let resume = object["cliSessionId"] as? String, !resume.isEmpty else { continue }
            let cwd = object["cwd"] as? String ?? ""
            let title = object["title"] as? String ?? ""
            let ms = (object["lastActivityAt"] as? Double) ?? (object["createdAt"] as? Double) ?? 0
            let desktopActivity = Date(timeIntervalSince1970: ms / 1000)
            let transcript = transcripts[resume]
            let state = sessionState(
                for: transcript,
                now: now,
                lastWorking: lastWorking,
                externalActivityDate: desktopActivity,
                turnState: SessionTurnState.claude
            )
            out.append(ScannedSession(
                tool: .claude,
                sessionId: resume,
                cwd: cwd,
                label: title.isEmpty ? fallback(cwd, resume) : title,
                modified: state.modified,
                status: state.status,
                transcriptPath: transcript,
                turnKey: state.turnKey,
                launchTarget: .claudeDesktop
            ))
        }
        return out
    }

    // MARK: - Codex: ~/.codex/sessions, one entry per project folder

    static func scanCodex(
        now: Date,
        lastWorking: [String: Date],
        limit: Int = 30,
        dedupeProjects: Bool = true
    ) -> [ScannedSession] {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.codex/sessions"
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        let titles = codexTitleIndex()
        var files: [String] = []
        for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
            files.append(root + "/" + rel)
        }
        // Stat each file ONCE, then sort by the cached mtime. Calling mtime()
        // inside the comparator re-stats every file O(n log n) times — the
        // dominant cost of the every-few-seconds monitoring scan.
        files = files
            .map { (path: $0, modified: mtime($0)) }
            .sorted { $0.modified > $1.modified }
            .map(\.path)
        var out: [ScannedSession] = []
        var seenProjects = Set<String>()
        for path in files {
            guard let (sid, cwd) = codexMeta(path), !sid.isEmpty else { continue }
            let projectKey = cwd.isEmpty ? sid : cwd
            if dedupeProjects {
                if seenProjects.contains(projectKey) { continue }
                seenProjects.insert(projectKey)
            }
            let state = sessionState(for: path, now: now, lastWorking: lastWorking, turnState: SessionTurnState.codex)
            out.append(ScannedSession(
                tool: .codex,
                sessionId: sid,
                cwd: cwd,
                label: titles[sid] ?? fallback(cwd, sid),
                modified: state.modified,
                status: state.status,
                transcriptPath: path,
                turnKey: state.turnKey,
                launchTarget: .cli
            ))
            if out.count >= limit { break }
        }
        return out
    }

    /// Reads the first JSONL line in full. Codex's `session_meta` is line 1 but
    /// can be tens of KB (it embeds the full base instructions), so a fixed-size
    /// read truncates it — keep pulling chunks until the first newline.
    private static func codexMeta(_ path: String) -> (String, String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.firstIndex(of: 0x0A) == nil {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 2_000_000 { break }
        }
        let firstLine = buffer.firstIndex(of: 0x0A).map { buffer.prefix(upTo: $0) } ?? buffer.prefix(buffer.count)
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        // Two tiers of machine-driven sessions, told apart on session_meta
        // (originator can't separate them — a spawned subagent carries the SAME
        // "Codex Desktop" originator as an interactive session):
        //
        // 1. AUTOMATION — never surfaced, no opt-in: `codex exec` runs, probes,
        //    bridges (originator substrings), source == "exec"/"mcp" strings,
        //    and {"internal": …} probe objects. A human is never "up" in these.
        let originator = (payload["originator"] as? String ?? "").lowercased()
        if originator.contains("exec") || originator.contains("probe") || originator.contains("bridge") {
            return nil
        }
        if let source = payload["source"] as? String, source == "exec" || source == "mcp" {
            return nil
        }
        if let source = payload["source"] as? [String: Any], source["internal"] != nil {
            return nil
        }
        // 2. SUBAGENT / child threads (orchestrator fan-out: spawned/review/
        //    compact) — filtered by DEFAULT because they finish constantly, but
        //    (History: an opt-in toggle existed briefly; deleted 2026-08-08.)
        //    threads"). All three spawn markers must honor the toggle, or an
        //    enabled toggle would still be dead: thread_source == "subagent",
        //    a non-empty parent_thread_id, and a {"subagent": …} source object
        //    co-occur on the same rollouts. UserDefaults is thread-safe; this
        //    runs off the main actor.
        let isSubagent = (payload["thread_source"] as? String) == "subagent"
            || (payload["parent_thread_id"] as? String).map({ !$0.isEmpty }) == true
            || (payload["source"] as? [String: Any])?["subagent"] != nil
        // Subagent/child threads NEVER alarm — the feature (and its toggle)
        // is deleted outright, not defaulted off (owner call, 2026-08-08:
        // 默认所有模型的子线程全部不打开,直接关掉这个功能).
        if isSubagent { return nil }
        return (payload["id"] as? String ?? "", payload["cwd"] as? String ?? "")
    }

    // MARK: - Grok: ~/.grok/sessions/<url-encoded cwd>/<uuid>/

    /// Grok mirrors Claude's layout almost exactly — one directory per
    /// percent-encoded cwd, one per session inside it. `summary.json` gives
    /// identity + title; `updates.jsonl` is the live event stream the turn
    /// detector reads (chat_history.jsonl is the fallback when a session
    /// predates the updates stream).
    static func scanGrok(now: Date, lastWorking: [String: Date]) -> [ScannedSession] {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.grok/sessions"
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [ScannedSession] = []
        for project in projects {
            let projectPath = root + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue,
                  let sessionDirs = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            let cwd = project.removingPercentEncoding ?? project
            for sid in sessionDirs {
                let dir = projectPath + "/" + sid
                guard fm.fileExists(atPath: dir + "/summary.json") else { continue }
                var title = ""
                if let data = fm.contents(atPath: dir + "/summary.json"),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    title = (object["session_summary"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let updates = dir + "/updates.jsonl"
                let transcript = fm.fileExists(atPath: updates) ? updates : dir + "/chat_history.jsonl"
                let state = sessionState(
                    for: transcript, now: now, lastWorking: lastWorking,
                    turnState: SessionTurnState.grok
                )
                out.append(ScannedSession(
                    tool: .grok,
                    sessionId: sid,
                    cwd: cwd,
                    label: title.isEmpty ? fallback(cwd, sid) : title,
                    modified: state.modified,
                    status: state.status,
                    transcriptPath: transcript,
                    turnKey: state.turnKey,
                    launchTarget: .cli
                ))
            }
        }
        return out
    }

    // MARK: - Antigravity

    /// Antigravity keeps a readable transcript per conversation at
    /// `<root>/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`
    /// — the desktop IDE and the `agy` CLI write the same shape into their
    /// own roots. Always `transcript_full`, never `transcript` (the latter is
    /// truncated).
    ///
    /// Records are `{step_index, source, type, status, created_at, content, …}`
    /// where `source` is USER_EXPLICIT / SYSTEM / MODEL. A MODEL record last
    /// means the agent spoke last — the same boundary Claude's stop_reason
    /// gives us. The `status` field's value set is not documented, so it is
    /// deliberately NOT trusted yet; recency plus the quiet gap carries the
    /// verdict until a real install proves what it contains.
    static func scanAntigravity(now: Date, lastWorking: [String: Date]) -> [ScannedSession] {
        let fm = FileManager.default
        var out: [ScannedSession] = []
        for root in antigravityRoots() {
            let brain = root + "/brain"
            guard let conversations = try? fm.contentsOfDirectory(atPath: brain) else { continue }
            let summaries = antigravitySummaries(root: root)
            for conversation in conversations {
                let path = brain + "/" + conversation
                    + "/.system_generated/logs/transcript_full.jsonl"
                guard fm.fileExists(atPath: path) else { continue }
                let state = sessionState(
                    for: path, now: now, lastWorking: lastWorking,
                    quietMeansDone: true,
                    turnState: SessionTurnState.antigravity
                )
                let summary = summaries[conversation]
                out.append(ScannedSession(
                    tool: .antigravity,
                    sessionId: conversation,
                    cwd: summary?.workspace
                        ?? antigravityWorkspace(root: root, conversation: conversation) ?? "",
                    label: summary?.title
                        ?? antigravityTitle(root: root, conversation: conversation)
                        ?? String(conversation.prefix(8)),
                    modified: state.modified,
                    status: state.status,
                    transcriptPath: path,
                    turnKey: state.turnKey,
                    launchTarget: .cli
                ))
            }
        }
        return out
    }

    /// Google has renamed this directory twice already (1.x `antigravity`,
    /// 2.x `antigravity-ide`, plus the separate `antigravity-cli` root), so
    /// every known variant is probed rather than one hardcoded guess.
    static func antigravityRoots() -> [String] {
        let home = NSHomeDirectory()
        return ["antigravity", "antigravity-ide", "antigravity-cli"]
            .map { home + "/.gemini/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// One row per conversation in `conversation_summaries.db`, the plain
    /// SQLite index the CLI keeps beside `brain/`. The IDE's `task.md` and
    /// `history.jsonl` (which earlier recon assumed) are never written by the
    /// CLI, so this table is the only place a real title or workspace lives.
    /// Fields it leaves empty stay empty — the caller falls back rather than
    /// inventing a value.
    struct AntigravitySummary {
        let title: String?
        let workspace: String?
    }

    /// Read once per scan and shared across that root's conversations —
    /// opening the db per conversation would be a needless connection each.
    static func antigravitySummaries(root: String) -> [String: AntigravitySummary] {
        let path = root + "/conversation_summaries.db"
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        // The db is WAL-mode. A read-only open needs the -shm file, which
        // only exists while the CLI holds the db open; with agy not running,
        // plain read-only fails at prepare with SQLITE_CANTOPEN. So: try the
        // live path first (sees committed WAL frames), then fall back to
        // immutable, which skips the WAL entirely — safe here because a
        // cleanly closed db is fully checkpointed, and a stale miss only
        // costs a nicer label.
        if let rows = antigravitySummaryRows(uri: path, useURI: false) { return rows }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return antigravitySummaryRows(uri: "file:" + escaped + "?immutable=1", useURI: true) ?? [:]
    }

    /// nil means this open/prepare failed and the caller should try the other
    /// mode; an empty dictionary means the table really had nothing.
    private static func antigravitySummaryRows(uri: String, useURI: Bool) -> [String: AntigravitySummary]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | (useURI ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)

        var statement: OpaquePointer?
        let sql = "SELECT conversation_id, title, preview, workspace_uris FROM conversation_summaries"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var out: [String: AntigravitySummary] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: rawID)
            guard !id.isEmpty else { continue }
            // title is usually blank; preview carries the generated name.
            let title = column(statement, 1) ?? column(statement, 2)
            out[id] = AntigravitySummary(
                title: title.map { String($0.prefix(48)) },
                workspace: column(statement, 3).flatMap(antigravityWorkspacePath)
            )
        }
        return out
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// `workspace_uris` is a JSON array of file:// URIs; the first one is the
    /// session's directory. Empty for CLI sessions started outside a project.
    private static func antigravityWorkspacePath(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        for entry in list {
            guard let text = entry as? String, !text.isEmpty else { continue }
            if let url = URL(string: text), url.isFileURL { return url.path }
            return text
        }
        return nil
    }

    /// The first user message, unwrapped from the `<USER_REQUEST>` envelope
    /// the CLI writes. Used when the summaries table has no name yet — it is
    /// written asynchronously, so a brand-new conversation has no row.
    private static func antigravityTitle(root: String, conversation: String) -> String? {
        let path = root + "/brain/" + conversation
            + "/.system_generated/logs/transcript_full.jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 16_384), as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "USER_INPUT",
                  let content = object["content"] as? String else { continue }
            return antigravityRequestText(content)
        }
        return nil
    }

    static func antigravityRequestText(_ content: String) -> String? {
        var body = content
        if let start = content.range(of: "<USER_REQUEST>"),
           let end = content.range(of: "</USER_REQUEST>"), start.upperBound <= end.lowerBound {
            body = String(content[start.upperBound..<end.lowerBound])
        }
        let clean = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : String(clean.prefix(48))
    }

    /// `history.jsonl` maps conversationId to its workspace.
    private static func antigravityWorkspace(root: String, conversation: String) -> String? {
        guard let text = try? String(contentsOfFile: root + "/history.jsonl", encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") {
            guard let object = json(String(line)),
                  object["conversationId"] as? String == conversation,
                  let workspace = object["workspace"] as? String,
                  !workspace.isEmpty
            else { continue }
            return workspace
        }
        return nil
    }

    private static func antigravitySessionId(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4096)
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any]
        else { return nil }
        return object["sessionId"] as? String
    }

    // MARK: - Cursor: workspaceStorage state.vscdb activity

    /// Cursor conversations, read from the same globalStorage db the cost
    /// reader opens. Rows keyed `composerData:<id>` are the conversations;
    /// rows keyed `bubbleId:<composerId>:<bubbleId>` are the messages, and a
    /// bubble's `type` is a REAL turn boundary — 1 is the user, 2 is the
    /// assistant (verified against live text on the survey machine). So the
    /// same rule Claude gets applies: assistant spoke last and has gone
    /// quiet means it is your turn.
    ///
    /// The whole pass is skipped when the db has not been written since the
    /// last scan — this runs every 6 s and the db is hundreds of megabytes.
    static func scanCursor(now: Date, lastWorking: [String: Date]) -> [ScannedSession] {
        let path = cursorGlobalDBPath
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        // Live writes land in the -wal journal and DO NOT touch the main
        // file's mtime — SQLite only folds them back on checkpoint, minutes
        // later. Keying the cache on the main file alone froze the scan on
        // a pre-checkpoint snapshot: the logo never spun while Cursor
        // worked, and the your-turn alarm arrived only when the checkpoint
        // finally landed (owner repro, 2026-08-08). The wal's mtime+size
        // must be part of the fingerprint.
        let wal = path + "-wal"
        let walSize = (try? FileManager.default
            .attributesOfItem(atPath: wal)[.size] as? Int64).flatMap { $0 } ?? 0
        let stamp = "\(mtime(path).timeIntervalSince1970)|\(mtime(wal).timeIntervalSince1970)|\(walSize)"

        cursorLock.lock()
        let cached = (stamp == cursorCacheStamp) ? cursorCache : nil
        cursorLock.unlock()
        if let cached {
            // Cache hit means the db (main + WAL) has not moved since the
            // last scan — the assistant has written nothing new — so every
            // conversation is stable by definition. Status is still
            // recomputed against the current clock (needsYou ages to idle).
            return cached.map { session(from: $0, now: now, stable: true, lastWorking: lastWorking) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        // Cursor writes while we read; WAL readers don't block writers, but
        // a checkpoint can hold the lock for a beat. A short wait beats
        // returning nothing for the whole 6 s tick.
        sqlite3_busy_timeout(db, 150)

        var parsed: [CursorConversation] = []
        for composerID in cursorComposerIDs(db) {
            guard let bubble = cursorNewestBubble(db, composerID: composerID) else { continue }
            let turn = SessionTurnState.cursor([bubble.json])
            // No usable bubble timestamp means we cannot say WHEN this
            // conversation last moved. Falling back to the db mtime was the
            // bug behind a permanently spinning logo: Cursor rewrites that
            // file continuously while it is merely open, so every stale
            // conversation looked like it had just been touched.
            guard let stamp = turn.activityDate else { continue }
            parsed.append(CursorConversation(
                id: composerID,
                label: bubble.title ?? String(composerID.prefix(8)),
                isDone: turn.isDone,
                turnKey: turn.key,
                stamp: stamp,
                generating: cursorIsGenerating(db, composerID: composerID)
            ))
        }
        parsed.sort { $0.stamp > $1.stamp }

        cursorLock.lock()
        let previousTurns = cursorLastTurn
        var nextTurns: [String: String] = [:]
        for conversation in parsed { nextTurns[conversation.id] = conversation.turnKey ?? "" }
        cursorLastTurn = nextTurns
        cursorCacheStamp = stamp
        cursorCache = parsed
        cursorLock.unlock()
        // A conversation is stable when its newest bubble is the SAME one we
        // saw last scan. The db changed (we are on the cold path), but this
        // particular conversation may not have — its turn is done only if it
        // held still while some other conversation moved.
        return parsed.map { conversation in
            let stable = previousTurns[conversation.id] == (conversation.turnKey ?? "")
            return session(from: conversation, now: now, stable: stable, lastWorking: lastWorking)
        }
    }

    /// One parsed conversation. Deliberately holds no status: the status is
    /// a function of the CURRENT clock and is recomputed on every scan.
    struct CursorConversation {
        let id: String
        let label: String
        let isDone: Bool
        let turnKey: String?
        let stamp: Date
        /// Cursor's own verdict; nil when the row was unreadable.
        let generating: Bool?
    }

    private static func session(
        from conversation: CursorConversation, now: Date,
        stable: Bool, lastWorking: [String: Date]
    ) -> ScannedSession {
        let key = "cursor:" + conversation.id
        let turn = SessionTurnStatus(
            isDone: conversation.isDone, key: conversation.turnKey, activityDate: conversation.stamp
        )
        return ScannedSession(
            tool: .cursor,
            sessionId: conversation.id,
            cwd: "",
            label: conversation.label,
            modified: conversation.stamp,
            status: cursorStatus(
                turn: turn, stamp: conversation.stamp, now: now,
                key: key, stable: stable, generating: conversation.generating,
                lastWorking: lastWorking
            ),
            transcriptPath: key,
            turnKey: conversation.turnKey,
            launchTarget: .cli
        )
    }

    /// Assistant-last plus a quiet gap means the turn finished; assistant-last
    /// while still streaming reads as working. A user bubble last means the
    /// agent is thinking.
    /// Cursor has no explicit "turn finished" marker like Claude's
    /// stop_reason, and a single reply streams in as several assistant
    /// bubbles seconds apart (measured up to 8.3s between them). So the real
    /// completion signal is "no NEW bubble since the last scan": `stable`
    /// means this exact newest bubble was already present one scan ago, i.e.
    /// the assistant has stopped writing. That gives a your-turn latency of
    /// one scan tick (~6s) — the same ballpark as Claude/Codex — without the
    /// 25s guess that made the alarm feel broken, and without firing mid-
    /// stream on an interim bubble.
    private static func cursorStatus(
        turn: SessionTurnStatus, stamp: Date, now: Date,
        key: String, stable: Bool, generating: Bool?, lastWorking: [String: Date]
    ) -> ActivityMonitor.State {
        let age = now.timeIntervalSince(stamp)
        if turn.isDone {
            // Cursor publishes its own verdict on composerData: status
            // "completed" with an empty generatingBubbleIds means the reply
            // is done. When we can read it, trust it — the alarm fires on the
            // very next scan (sub-second, since FSEvents watches the store),
            // with no settle timer at all.
            if let generating {
                guard !generating else { return .working }
                return age < needsYouCap ? .needsYou : .idle
            }
            // Unreadable row: fall back to timing. Both conditions must hold
            // or a mid-reply pause fires a false alarm — `stable` (no new
            // bubble since last scan) AND the bubble having sat still for a
            // real beat, because event-driven rescans can land <1s apart
            // while bubbles within one reply arrive up to 8.3s apart.
            guard stable, age >= cursorSettle else { return .working }
            return age < needsYouCap ? .needsYou : .idle
        }
        // Newest bubble is the user's: the agent is thinking.
        if age < stallAfter { return .working }
        if let seen = lastWorking[key], now.timeIntervalSince(seen) < stallCap, age < stallCap {
            return .stalled
        }
        return .idle
    }

    /// Minimum age of the newest assistant bubble before its turn counts as
    /// finished. Above the sub-second event-rescan interval, below the
    /// smallest gap a human waits for a reply — tuned against a measured
    /// max intra-reply bubble gap of 8.3s (we do NOT wait that long; the
    /// `stable` flag already proves no new bubble arrived, this just guards
    /// the fast-rescan race).
    private static let cursorSettle: TimeInterval = 3

    private static var cursorGlobalDBPath: String {
        NSHomeDirectory()
            + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    private static let cursorLock = NSLock()
    private static var cursorCacheStamp = ""
    private static var cursorCache: [CursorConversation] = []
    /// composerId → the newest bubble id seen last scan. Used to tell a
    /// still-streaming reply (bubble changed) from a finished one (unchanged).
    private static var cursorLastTurn: [String: String] = [:]

    /// Cursor's own generation state, straight from composerData:
    ///   status == "completed" and generatingBubbleIds empty  → the reply is
    ///   finished; anything else (status "none"/"generating", or a non-empty
    ///   generatingBubbleIds) → still producing.
    /// This is authoritative — far better than inferring completion from how
    /// long the newest bubble has sat still, which is what the settle timer
    /// was doing. Returns nil when the row cannot be read, so the caller
    /// falls back to the timing heuristic rather than guessing "done".
    private static func cursorIsGenerating(_ db: OpaquePointer, composerID: String) -> Bool? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let key = "composerData:" + composerID
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              let data = String(cString: raw).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let generating = object["generatingBubbleIds"] as? [Any], !generating.isEmpty {
            return true
        }
        guard let status = object["status"] as? String else { return nil }
        return status != "completed"
    }

    private static func cursorComposerIDs(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT key FROM cursorDiskKV WHERE key LIKE 'composerData:%'", -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: raw)
            let id = String(key.dropFirst("composerData:".count))
            if !id.isEmpty { ids.append(id) }
        }
        return ids
    }

    /// Newest message in a conversation. rowid order is insertion order, so
    /// the highest rowid for a composer is its latest bubble — far cheaper
    /// than decoding every bubble to sort by timestamp.
    private static func cursorNewestBubble(
        _ db: OpaquePointer, composerID: String
    ) -> (json: String, title: String?)? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let pattern = "bubbleId:" + composerID + ":%"
        sqlite3_bind_text(statement, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        let json = String(cString: raw)
        return (json, cursorTitle(json))
    }

    /// A bubble's own text, trimmed to one line, stands in for a conversation
    /// title — Cursor leaves composerData.name empty on most threads.
    private static func cursorTitle(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(48))
    }

    /// workspace.json carries the folder URI ("file:///Users/…"); missing on
    /// special windows (empty-window), where the hash directory name is all
    /// we have.
    private static func cursorWorkspaceFolder(_ dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: dir + "/workspace.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["folder"] as? String,
              let url = URL(string: folder)
        else { return nil }
        return url.path
    }

    // MARK: - Helpers

    static func fallback(_ cwd: String, _ sid: String) -> String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? String(sid.prefix(8)) : base
    }

    private static func codexTitleIndex() -> [String: String] {
        let path = NSHomeDirectory() + "/.codex/session_index.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let object = json(String(line)),
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String
            else { continue }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && !clean.isEmpty { out[id] = clean }
        }
        return out
    }

    /// Rebuilt at most once per poll interval. FSEvents drives ticks as fast as
    /// ~2/s while a transcript streams, but those events mean "a line was
    /// appended", not "a session appeared" — and the walk itself costs 0.32 s of
    /// CPU plus ~5 MB of transient allocations on a machine with 33k transcripts
    /// (measured). Rebuilding it per tick is what pins a core and inflates RSS
    /// into the gigabytes as freed small-zone regions pile up. A newly created
    /// session still surfaces within one poll, exactly as it did back when the
    /// timer was the only trigger.
    private static let indexTTL: TimeInterval = 6
    private static let indexLock = NSLock()
    private static var indexCache: [String: String] = [:]
    private static var indexBuiltAt: Date = .distantPast

    static func claudeTranscriptIndex() -> [String: String] {
        indexLock.lock()
        let cached = indexCache
        let isFresh = Date().timeIntervalSince(indexBuiltAt) < indexTTL
        indexLock.unlock()
        if isFresh { return cached }

        let rebuilt = buildClaudeTranscriptIndex()
        indexLock.lock()
        indexCache = rebuilt
        indexBuiltAt = Date()
        indexLock.unlock()
        return rebuilt
    }

    private static func buildClaudeTranscriptIndex() -> [String: String] {
        let root = NSHomeDirectory() + "/.claude/projects"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [:] }
        var out: [String: String] = [:]
        for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
            // Subagent transcripts: subagents/ dirs (current layout) or
            // agent-*.jsonl names (flat layouts). Main sessions are always
            // UUID-named. Machine fan-out must not drive alarms or the logo.
            if rel.contains("/subagents/") { continue }
            if ((rel as NSString).lastPathComponent).hasPrefix("agent-") { continue }
            let path = root + "/" + rel
            let sid = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            out[sid] = path
        }
        return out
    }

    static func status(
        for path: String?,
        now: Date,
        lastWorking: [String: Date],
        turnDone: ([String]) -> Bool
    ) -> ActivityMonitor.State {
        sessionState(
            for: path,
            now: now,
            lastWorking: lastWorking,
            turnState: { lines in SessionTurnStatus(isDone: turnDone(lines), key: nil, activityDate: nil) }
        ).status
    }

    static func sessionState(
        for path: String?,
        now: Date,
        lastWorking: [String: Date],
        externalActivityDate: Date? = nil,
        quietMeansDone: Bool = false,
        turnState: ([String]) -> SessionTurnStatus
    ) -> (status: ActivityMonitor.State, turnKey: String?, modified: Date) {
        guard let path else {
            return (.idle, nil, externalActivityDate ?? .distantPast)
        }
        let fileModified = mtime(path)
        let lines = tailLines(path)
        var turn = turnState(lines)
        // Providers whose transcripts carry no explicit turn boundary
        // (Gemini's checkpoint stream, Cursor's workspace db) still have an
        // honest completion signal: the file was being written moments ago
        // and has now gone quiet. A CLI that stopped writing is either
        // finished or waiting on an approval — both mean "your turn". The
        // quiet threshold sits well above streaming gaps so a thinking
        // pause never fires it.
        if quietMeansDone, !turn.isDone,
           let lastActive = lastWorking[path] {
            let quietFor = now.timeIntervalSince(fileModified)
            if quietFor > Self.guestQuietAfter,
               now.timeIntervalSince(lastActive) < needsYouCap {
                turn = SessionTurnStatus(
                    isDone: true,
                    key: "quiet:\(Int(lastActive.timeIntervalSince1970))",
                    activityDate: turn.activityDate
                )
            }
        }
        let semanticModified = latestDate(turn.activityDate, externalActivityDate)
        let effectiveModified = semanticModified ?? fileModified
        // Claude Desktop writes lastActivityAt a few seconds AFTER the final
        // assistant event as turn-completion bookkeeping (measured 2.3-4.2s on
        // real threads). For a finished turn, external activity inside that
        // window is the bookkeeping write — not the user returning — so it
        // must not suppress needsYou, or the alarm only fires when the 6s scan
        // tick happens to land inside the gap. Genuine "user came back"
        // activity lands minutes later, far past the grace.
        let externalReference = turn.isDone
            ? turn.activityDate.map { $0.addingTimeInterval(desktopBookkeepingGrace) }
            : turn.activityDate
        let externalIsNewer = isLater(externalActivityDate, than: externalReference)
        let age = now.timeIntervalSince(effectiveModified)
        if age > attentionWindow { return (.idle, turn.key, effectiveModified) }
        if externalIsNewer {
            if age < stallAfter { return (.working, turn.key, effectiveModified) }
            if let seen = lastWorking[path],
               now.timeIntervalSince(seen) < stallCap,
               age < stallCap {
                return (.stalled, turn.key, effectiveModified)
            }
            return (.idle, turn.key, effectiveModified)
        }
        if turn.isDone { return (age < needsYouCap ? .needsYou : .idle, turn.key, effectiveModified) }
        if age < activeWindow { return (.working, turn.key, effectiveModified) }
        if age < stallAfter { return (.working, turn.key, effectiveModified) }
        if let seen = lastWorking[path],
           now.timeIntervalSince(seen) < stallCap,
           age < stallCap {
            return (.stalled, turn.key, effectiveModified)
        }
        return (.idle, turn.key, effectiveModified)
    }

    static func claudeTurnDone(_ lines: [String]) -> Bool {
        SessionTurnState.claude(lines).isDone
    }

    private static func codexTurnDone(_ lines: [String]) -> Bool {
        SessionTurnState.codex(lines).isDone
    }

    private static func tailLines(_ path: String, bytes: UInt64 = 131_072, keep: Int = 200) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return Array(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).suffix(keep))
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Modification time via a single `stat(2)` syscall. `FileManager`'s
    /// `attributesOfItem` fetches the *entire* attribute set (owner,
    /// permissions, size, every timestamp) and bridges it into an NSDictionary
    /// — dozens of times more work than we need. The monitoring scan runs every
    /// few seconds over every session file, so this hot path takes only the one
    /// field it uses.
    static func mtime(_ path: String) -> Date {
        var info = stat()
        guard stat(path, &info) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970:
            TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func latestDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    private static func isLater(_ lhs: Date?, than rhs: Date?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs.timeIntervalSince(rhs) > 0.5
    }
}
