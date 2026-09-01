import Foundation

/// Walks the local Codex CLI rollout files and emits a TokenEvent for every
/// turn that recorded usage:
///   - reads ~/.codex/sessions/ AND ~/.codex/archived_sessions/ (archiving
///     moves files — zero filename overlap measured — and the archive held
///     2.5B July tokens the live tree no longer had; reconciliation audit
///     2026-07-16)
///   - tracks the most recent `turn_context.payload.model` as the active
///     model for subsequent `event_msg.token_count` events
///   - v3 accounting (2026-07-17): fork/subagent files drop their
///     copied-parent prefix (the writer clones the parent's history with
///     rewritten timestamps), and every event settles through a per-file
///     high-water mark — min(last delta, cumulative growth above the mark),
///     never-inflates. See parseFile's doc comment for the writer-side
///     evidence.
///
/// This intentionally diverges from ccusage's bucketing: we attribute usage
/// to the moment it happened (event timestamp), not to the session's start
/// day, which misplaces multi-day auto-resumed sessions wholesale.
///
/// Per-file parse results are memoized in `~/Library/Caches/.../codex-parse-cache.v3.json`
/// keyed by (path, mtime, size). Between two 5/15/30-minute polls almost no
/// rollout file has changed, so the steady-state refresh skips re-parsing.
enum CodexLogReader {
    static func scan(lookbackDays: Int = 30) -> [TokenEvent] {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var out: [TokenEvent] = []

        LogParseCache.walk(
            roots: [sessionsRoot(), archivedSessionsRoot()],
            cutoff: cutoff,
            cacheFilename: "codex-parse-cache.v3.json",
            cacheVersion: cacheVersion,
            fileFilter: { $0.lastPathComponent.hasPrefix("rollout-") },
            parse: parseFile(at:),
            emit: { (ev: CachedEvent) in
                guard ev.timestamp >= cutoff else { return }
                out.append(TokenEvent(
                    provider: .codex,
                    timestamp: ev.timestamp,
                    model: ev.model,
                    inputTokens: ev.inputTokens,
                    outputTokens: ev.outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: ev.cacheReadTokens
                ))
            }
        )
        return out
    }

    private static func sessionsRoot() -> URL {
        codexHome().appendingPathComponent("sessions", isDirectory: true)
    }

    private static func archivedSessionsRoot() -> URL {
        codexHome().appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private static func codexHome() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Parse a single file end-to-end: buffer the raw usage events, then run
    /// the v3 accounting pass. Two truths from the openai/codex writer force
    /// this shape (2026-07-17 archaeology, four-repo + writer-source study):
    ///
    ///  1. A fork/subagent file begins with the PARENT's entire token_count
    ///     history, copied verbatim with timestamps rewritten to the fork
    ///     instant — event-summing recounts the parent wholesale (111亿 of
    ///     phantom tokens on one real machine). The copy is a tight burst:
    ///     consecutive gaps ≤2s. Skip it, and seed the watermark from its
    ///     final cumulative so the child's own turns count from there.
    ///  2. The runtime re-emits stale events on 429/cancel/compaction and
    ///     interleaves several subagent counters into one file. The fix is
    ///     CodexBar's conservative invariant: count
    ///     min(last_delta, cumulative growth above the file's high-water
    ///     mark), clamped ≥0 — never-inflates by construction.
    private static func parseFile(at url: URL) -> [CachedEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFractional = ISO8601DateFormatter()
        formatterNoFractional.formatOptions = [.withInternetDateTime]

        var currentModel: String?
        var isForkFile = false
        var raws: [RawUsageEvent] = []

        // `maxLineBytes` skips the multi-MB `response_item` blobs (base64
        // screenshots, large tool output) at the reader level — they're never
        // the records we want and assembling them is what stalls big sessions.
        LogParseCache.streamLines(at: url, maxLineBytes: maxUsefulLineBytes) { lineData in
            // Cheap byte-scan before paying for JSON: usage lines carry
            // `token_count`, model lines `turn_context`, and the fork flag
            // lives in the head `session_meta` line.
            let isMetaCandidate = !isForkFile && lineData.range(of: sessionMetaMarker) != nil
            guard lineData.range(of: tokenCountMarker) != nil
                    || lineData.range(of: turnContextMarker) != nil
                    || isMetaCandidate else { return }

            guard let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = raw["type"] as? String else { return }

            if type == "session_meta", let payload = raw["payload"] as? [String: Any] {
                let source = String(describing: payload["source"] ?? "")
                if payload["forked_from_id"] != nil
                    || payload["parent_thread_id"] != nil
                    || source.contains("subagent") || source.contains("thread_spawn") {
                    isForkFile = true
                }
                return
            }

            if type == "turn_context",
               let payload = raw["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
                return
            }

            guard type == "event_msg",
                  let payload = raw["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any]
            else { return }

            let timestampString = raw["timestamp"] as? String ?? ""
            let timestamp = formatter.date(from: timestampString)
                ?? formatterNoFractional.date(from: timestampString)
                ?? Date.distantPast

            var cumulative: (input: Int, output: Int)?
            if let total = info["total_token_usage"] as? [String: Any] {
                cumulative = (
                    input: (total["input_tokens"] as? Int) ?? 0,
                    output: (total["output_tokens"] as? Int) ?? 0
                )
            }

            raws.append(RawUsageEvent(
                timestamp: timestamp,
                model: currentModel ?? "gpt-5.4",
                lastInput: (last["input_tokens"] as? Int) ?? 0,
                lastCached: (last["cached_input_tokens"] as? Int) ?? 0,
                lastOutput: (last["output_tokens"] as? Int) ?? 0,
                cumulative: cumulative
            ))
        }
        return settle(raws, isForkFile: isForkFile)
    }

    /// The v3 accounting pass over one file's buffered events.
    private static func settle(_ raws: [RawUsageEvent], isForkFile: Bool) -> [CachedEvent] {
        // ① Fork files: drop the copied-prefix burst (≥3 events, consecutive
        //    gaps ≤2s from the head) and seed the watermark from its end.
        var cut = 0
        if isForkFile && raws.count >= 3 {
            var run = 1
            while run < raws.count,
                  raws[run].timestamp.timeIntervalSince(raws[run - 1].timestamp) <= 2.0 {
                run += 1
            }
            if run >= 3 { cut = run }
        }

        var watermark: (input: Int, output: Int) = (0, 0)
        if cut > 0, let seed = raws[cut - 1].cumulative { watermark = seed }

        var out: [CachedEvent] = []
        out.reserveCapacity(max(0, raws.count - cut))
        for ev in raws.dropFirst(cut) {
            let countedInput: Int
            let countedOutput: Int
            if let cum = ev.cumulative {
                // ② Watermark rule: only growth above the high-water mark is
                //    new ground; stale re-emissions (cumulative unchanged) and
                //    interleaved-lineage overlap settle to zero.
                let growthIn = max(0, cum.input - watermark.input)
                let growthOut = max(0, cum.output - watermark.output)
                countedInput = max(0, min(ev.lastInput, growthIn))
                countedOutput = max(0, min(ev.lastOutput, growthOut))
                watermark.input = max(watermark.input, cum.input)
                watermark.output = max(watermark.output, cum.output)
            } else {
                // Ancient CLI builds without a cumulative: pass through.
                countedInput = ev.lastInput
                countedOutput = ev.lastOutput
            }

            // Codex reports input_tokens INCLUDING the cached portion. When a
            // partial count clips the input, attribute the counted part to
            // the cached (cheap) side first so cost never inflates.
            let countedCached = min(ev.lastCached, countedInput)
            let nonCachedInput = countedInput - countedCached
            if nonCachedInput == 0 && countedCached == 0 && countedOutput == 0 { continue }

            out.append(CachedEvent(
                timestamp: ev.timestamp,
                model: ev.model,
                inputTokens: nonCachedInput,
                outputTokens: countedOutput,
                cacheReadTokens: countedCached
            ))
        }
        return out
    }

    private struct RawUsageEvent {
        let timestamp: Date
        let model: String
        let lastInput: Int
        let lastCached: Int
        let lastOutput: Int
        let cumulative: (input: Int, output: Int)?
    }

    // MARK: - Line pre-filter

    /// Upper bound for a usage/model line. `token_count` payloads are well
    /// under 1KB and even a tool-heavy `turn_context` stays small; 1MB leaves
    /// generous headroom while skipping the multi-MB image/payload lines that
    /// dominate large sessions.
    private static let maxUsefulLineBytes = 1 << 20
    private static let tokenCountMarker = Data("token_count".utf8)
    private static let turnContextMarker = Data("turn_context".utf8)
    private static let sessionMetaMarker = Data("session_meta".utf8)

    // MARK: - Per-file cache

    private static let cacheVersion = 3

    private struct CachedEvent: Codable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
    }
}
