import Foundation
import SQLite3

/// Cursor's session, read out of the editor's own key/value store
/// (`state.vscdb`, a SQLite file under Application Support). Cursor keeps a
/// WorkOS session JWT under `cursorAuth/accessToken`; its `sub` claim is
/// the user id every dashboard endpoint keys on.
///
/// The db stays open in Cursor while it runs, so reads go through the
/// system SQLite in read-only mode — WAL supports concurrent readers, and
/// a transient lock just means "try again next poll". Display-only: the
/// token is handed straight back to Cursor's own API and never logged.
enum CursorCredentials {
    struct Session {
        let accessToken: String
        let userId: String
    }

    static func stateDbPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    /// Detection is the state db itself — a bare ~/.cursor from an aborted
    /// install has nothing to show, and no db means no login either way.
    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: stateDbPath())
    }

    static func readSession() -> Session? {
        guard let token = readValue(key: "cursorAuth/accessToken"),
              looksLikeJWT(token),
              let subject = decodeSubject(fromJWT: token) else { return nil }
        return Session(accessToken: token, userId: subject)
    }

    /// The tier as Cursor's own billing store has it locally ("free",
    /// "pro"…). Only the fallback when the plan endpoint can't be reached —
    /// the endpoint is authoritative and this copy can lag a plan change.
    static func cachedPlan() -> String? {
        normalizePlan(readValue(key: "cursorAuth/stripeMembershipType"))
    }

    /// Account identity for hover detail only — never the default-visible
    /// caption (owner rule: rows lead with sync state, not an email).
    static func cachedEmail() -> String? {
        readValue(key: "cursorAuth/cachedEmail")
    }

    // MARK: - SQLite

    private static func readValue(key: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDbPath(), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT — SQLite copies the key before this call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Pure helpers (unit-tested)

    static func looksLikeJWT(_ token: String) -> Bool {
        token.hasPrefix("eyJ") && token.split(separator: ".").count == 3
    }

    /// The JWT's `sub` claim, e.g. "google-oauth2|user_01ABC…". Signature is
    /// irrelevant here: the token is only ever handed back to Cursor, which
    /// verifies it. Payload is base64url with the padding stripped.
    static func decodeSubject(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              !subject.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return subject
    }

    /// Cursor's known tiers, longest-match-first so "pro_plus" never reads
    /// as "pro". Unknown strings drop rather than show garbage in a chip.
    static func normalizePlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let tiers = ["free_trial", "pro_plus", "enterprise", "business", "ultra", "team", "free", "pro"]
        guard let match = tiers.first(where: { lower.hasPrefix($0) }) else { return nil }
        return match.replacingOccurrences(of: "_", with: " ")
    }
}
