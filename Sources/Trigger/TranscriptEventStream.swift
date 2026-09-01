import Foundation
import CoreServices

/// FSEvents watcher over the transcript roots. Polling alone means a state
/// change waits up to a full tick to surface; file events let the monitor
/// react the moment a transcript line lands, so the logo starts and stops
/// with the run instead of seconds behind it. The poll stays as a fallback
/// sweep for anything events miss.
final class TranscriptEventStream {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "TranscriptEventStream", qos: .utility)
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        guard stream == nil else { return }
        let home = NSHomeDirectory()
        let roots = [
            home + "/.claude/projects",
            home + "/.codex/sessions",
            home + "/Library/Application Support/Claude/claude-code-sessions",
            // The three guests were poll-only until now: their roots were
            // never watched, so a finished Grok/Gemini/Cursor turn waited up
            // to a full 6s tick (Cursor worst-case ~12s, since it needs a
            // second scan to confirm the reply stopped growing). Watching
            // their roots gives them the same sub-second reaction Claude and
            // Codex get (owner: make the guests react in real time).
            home + "/.grok/sessions",
            // Google renamed this twice (1.x antigravity, 2.x
            // antigravity-ide) and the CLI keeps its own root, so all three
            // are watched; missing ones are filtered out below.
            home + "/.gemini/antigravity",
            home + "/.gemini/antigravity-ide",
            home + "/.gemini/antigravity-cli",
            home + "/Library/Application Support/Cursor/User/globalStorage",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<TranscriptEventStream>.fromOpaque(info).takeUnretainedValue()
            guard let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            if changed.contains(where: { watcher.isRelevant($0) }) {
                watcher.onChange()
            }
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    private func isRelevant(_ path: String) -> Bool {
        // Claude/Codex transcripts, Claude desktop store, Grok chat/updates:
        if path.hasSuffix(".jsonl") { return true }
        if (path as NSString).lastPathComponent.hasPrefix("local_") { return true }
        // Cursor writes its conversation store as SQLite. The main db moves
        // only on checkpoint, so the -wal journal is where a live reply
        // actually lands — watch both. The -shm shared-memory file churns
        // many times a second as pure bookkeeping and carries no new content,
        // so it must NOT trigger a rescan or it becomes a scan storm.
        if path.hasSuffix("state.vscdb") || path.hasSuffix("state.vscdb-wal") { return true }
        return false
    }
}
