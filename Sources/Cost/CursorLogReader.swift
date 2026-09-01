import Foundation
import SQLite3

/// Reads Cursor's local per-turn token ledger out of the editor's own
/// key/value store — the same `state.vscdb` `CursorCredentials` opens for auth,
/// but a different table. Cursor records each assistant turn as a `cursorDiskKV`
/// row keyed `bubbleId:<composerId>:<bubbleId>` whose value is a JSON "bubble";
/// the bubble carries `tokenCount:{inputTokens, outputTokens}`.
///
/// What Cursor does NOT record is a model or a dollar cost — a bubble has no
/// model field, so these events price to nothing (honesty rule: no model means
/// no price). Every event is emitted with model "cursor", no cache tokens, and
/// `selfReportedCostUSD == nil`; the cost pipeline surfaces Cursor as token
/// counts with no dollar figure.
///
/// The db stays open in Cursor while it runs, so the read goes through the
/// system SQLite in read-only mode (WAL supports concurrent readers, and a
/// transient lock just means "try again next poll"), mirroring
/// `CursorCredentials`.
enum CursorLogReader {
    /// Walk the bubble rows and return every turn that recorded a non-zero
    /// token count in the last `lookbackDays` days. Pure file IO; no network.
    /// Safe to call from a background thread.
    static func scan(lookbackDays: Int = 30) -> [TokenEvent] {
        let path = CursorCredentials.stateDbPath()
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        // A bubble rarely carries its own clock, so the db's mtime is the
        // fallback timestamp the cutoff filter leans on (see `bubbleDate`).
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let dbModified = (attrs?[.modificationDate] as? Date) ?? Date()

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        // Bubbles live in cursorDiskKV (auth lives in ItemTable). An older
        // Cursor without this table just fails prepare, yielding no events.
        guard sqlite3_prepare_v2(
                db,
                "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'",
                -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [TokenEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let json = String(cString: text)
            // Most bubbles (user turns, tool bubbles) carry no usage; a cheap
            // substring test skips the JSON parse for them.
            guard json.contains("tokenCount"),
                  let event = parseBubble(json, fallback: dbModified),
                  event.timestamp >= cutoff else { continue }
            out.append(event)
        }
        return out
    }

    /// Returns nil for bubbles without a usable token count. Absent or {0,0}
    /// counts are skipped (the survey machine is all historical zero sessions,
    /// so the reader must simply yield nothing then).
    static func parseBubble(_ json: String, fallback: Date) -> TokenEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenCount = obj["tokenCount"] as? [String: Any] else { return nil }

        let input = (tokenCount["inputTokens"] as? Int) ?? 0
        let output = (tokenCount["outputTokens"] as? Int) ?? 0
        if input == 0 && output == 0 { return nil }

        return TokenEvent(
            provider: .cursor,
            timestamp: bubbleDate(obj["createdAt"], fallback: fallback),
            // A Cursor bubble has no model field; a constant stands in so
            // downstream grouping has a stable key. Nothing prices it, so cost
            // stays nil.
            model: "cursor",
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            selfReportedCostUSD: nil
        )
    }

    /// A bubble's `createdAt` when present (epoch ms as Cursor writes it, or an
    /// ISO string defensively), else the db mtime. The shape is unproven on the
    /// survey machine, so parsing is best-effort and always has a real-clock
    /// fallback.
    private static func bubbleDate(_ raw: Any?, fallback: Date) -> Date {
        if let number = raw as? Double { return epochDate(number) }
        if let text = raw as? String {
            if let iso = isoFormatter.date(from: text) { return iso }
            if let number = Double(text) { return epochDate(number) }
        }
        return fallback
    }

    /// Cursor timestamps are epoch milliseconds; a value small enough to be
    /// seconds (any plausible second count sits far below this bound) is read
    /// as seconds so an out-of-shape value still lands in a sane range.
    private static func epochDate(_ value: Double) -> Date {
        let seconds = value > 1e11 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
