import Foundation

/// Gemini cost reader — an honest STUB.
///
/// Gemini ships NO local token ledger as of 2026-08. The CLI keeps a
/// per-project working directory at `~/.gemini/antigravity-ide/<project>/` holding a
/// `chats/` folder of `$set` checkpoint streams plus a `logs.json` file, but
/// none of those records carry per-message token accounting — on the survey
/// machine `chats/` is empty and `logs.json` is `[]`. There is nothing here to
/// cost, so `scan` returns no events today.
///
/// Gemini's usage percentages come from the live Code Assist endpoint
/// (`AntigravityUsageFetcher`), which reports QUOTA buckets — not tokens and not
/// dollars. That path is display-only and unrelated to this reader; this file
/// never invents a cost or a token count to stand in for it.
///
/// The seam is `parse(_:cutoff:)`: `scan` already walks the same tree a real
/// build would, and the one function a future contributor fills in is marked
/// with `TODO(antigravity-tokens)` — the day a per-message usage shape appears, wire
/// it there and every downstream summary picks Gemini up automatically.
enum AntigravityLogReader {
    /// Walk `~/.gemini/antigravity-ide/<project>/{chats/*.jsonl, logs.json}` and return
    /// every usage-bearing turn from the last `lookbackDays` days. Pure file
    /// IO; no network. Safe to call from a background thread. Returns an empty
    /// list today (no local Gemini token ledger exists) and never throws on the
    /// empty / missing / unreadable case.
    static func scan(lookbackDays: Int = 30) -> [TokenEvent] {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var out: [TokenEvent] = []

        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: tmpRoot(), includingPropertiesForKeys: nil
        ) else {
            return out
        }

        for project in projects {
            // Two candidate ledgers per project, both empty as of 2026-08:
            // the chat checkpoint streams and the top-level logs.json.
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            let chatFiles = (try? fm.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil
            )) ?? []
            for file in chatFiles where file.pathExtension == "jsonl" {
                out.append(contentsOf: parse(file, cutoff: cutoff))
            }
            let logsJSON = project.appendingPathComponent("logs.json", isDirectory: false)
            out.append(contentsOf: parse(logsJSON, cutoff: cutoff))
        }
        return out
    }

    private static func tmpRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
    }

    /// The single fill-in point. Reads one ledger file's bytes (a missing,
    /// empty, or unreadable file yields nil and contributes nothing — this
    /// never throws) and hands them to the decode step.
    private static func parse(_ url: URL, cutoff: Date) -> [TokenEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }

        // TODO(antigravity-tokens): decode per-message usage from `data`. The
        // expected shape mirrors every other reader — for each assistant turn
        // recover (timestamp, model, inputTokens, outputTokens, cacheReadTokens)
        // and, guarding `timestamp >= cutoff`, append:
        //
        //   out.append(TokenEvent(
        //       provider: .antigravity,
        //       timestamp: <turn time>,
        //       model: <model id, or "" when the record omits one>,
        //       inputTokens: <in>, outputTokens: <out>,
        //       cacheCreationTokens: 0, cacheReadTokens: <cached>,
        //       selfReportedCostUSD: nil))   // Gemini ships no dollar figure
        //
        // Leave `selfReportedCostUSD` nil so the event stays table-priced
        // downstream; never fabricate a cost. If the shape turns out to be
        // line-oriented (JSONL), stream lines rather than holding the file.
        //
        // As of 2026-08 no such record exists (chats/ empty, logs.json == []),
        // so there is nothing to decode and we emit nothing.
        _ = data
        _ = cutoff
        return []
    }
}
