import Foundation

/// One selected login entry from the Grok CLI credential store.
struct GrokAuthEntry: Equatable {
    let scope: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let authMode: String?
    let email: String?
    let oidcIssuer: String
    let oidcClientID: String?

    var isSuperGrok: Bool { authMode?.lowercased() == "oidc" }
}

/// Reader/rotator for `~/.grok/auth.json` (0600). Top-level keys are OIDC
/// scope URLs — "https://auth.x.ai::<client-id>" for SuperGrok logins, with
/// the client id riding after the "::". `expires_at` is epoch milliseconds.
///
/// The token endpoint rotates the refresh token on every exchange, so a
/// successful refresh MUST be written back — losing the new refresh token
/// strands the user's `grok` CLI login. The writeback is atomic
/// (tmp file created 0600 in the same directory, then rename(2)) and
/// re-reads the file first so every field this app doesn't understand is
/// preserved byte-for-value.
enum GrokAuthFile {
    static let defaultIssuer = "https://auth.x.ai"
    private static let oidcScopeMarker = "auth.x.ai"

    static func defaultURL() -> URL {
        let home: String
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            home = NSString(string: custom).expandingTildeInPath
        } else {
            home = NSString("~/.grok").expandingTildeInPath
        }
        return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
    }

    static func exists(at url: URL = defaultURL()) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func loadEntry(from url: URL = defaultURL()) -> GrokAuthEntry? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let (scope, raw) = selectEntry(root) else { return nil }
        return entry(scope: scope, raw: raw)
    }

    /// Refresh a minute early so an in-flight request never races the clock.
    static func needsRefresh(_ entry: GrokAuthEntry,
                             now: Date = Date(),
                             skew: TimeInterval = 60) -> Bool {
        guard let expiresAt = entry.expiresAt else { return false }
        return now.addingTimeInterval(skew) >= expiresAt
    }

    /// Apply an OAuth token response (`access_token` / rotated
    /// `refresh_token` / `expires_in` seconds) to the entry at `scope` and
    /// persist. Returns the updated entry, or nil when nothing was written
    /// (malformed response, missing file/scope, write failure) — the caller
    /// keeps using its in-memory token.
    @discardableResult
    static func applyRefreshResponse(_ data: Data,
                                     to url: URL,
                                     scope: String,
                                     now: Date = Date()) -> GrokAuthEntry? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = nonEmpty(response["access_token"]) else { return nil }

        guard let fileData = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              var raw = root[scope] as? [String: Any] else { return nil }

        raw["key"] = accessToken
        if let rotated = nonEmpty(response["refresh_token"]) {
            raw["refresh_token"] = rotated
        }
        if let expiresIn = seconds(response["expires_in"]), expiresIn > 0 {
            raw["expires_at"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        }
        root[scope] = raw

        guard let output = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".auth.json.tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: output,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return entry(scope: scope, raw: raw)
    }

    // MARK: - Entry selection

    /// Prefer "auth.x.ai" scopes (the SuperGrok OIDC login); among
    /// candidates prefer non-expired, then latest expiry, then stable scope
    /// order. Legacy session scopes are a last resort.
    private static func selectEntry(_ root: [String: Any]) -> (String, [String: Any])? {
        var oidc: [(String, [String: Any])] = []
        var legacy: [(String, [String: Any])] = []
        for (scope, value) in root {
            guard let raw = value as? [String: Any], nonEmpty(raw["key"]) != nil else { continue }
            if scope.contains(oidcScopeMarker) {
                oidc.append((scope, raw))
            } else {
                legacy.append((scope, raw))
            }
        }
        let now = Date()
        func rank(_ candidates: [(String, [String: Any])]) -> (String, [String: Any])? {
            candidates.min { lhs, rhs in
                let lhsExpiry = parseExpiry(lhs.1["expires_at"])
                let rhsExpiry = parseExpiry(rhs.1["expires_at"])
                let lhsExpired = (lhsExpiry ?? .distantFuture) <= now
                let rhsExpired = (rhsExpiry ?? .distantFuture) <= now
                if lhsExpired != rhsExpired { return rhsExpired }
                let lhsAt = lhsExpiry ?? .distantPast
                let rhsAt = rhsExpiry ?? .distantPast
                if lhsAt != rhsAt { return lhsAt > rhsAt }
                return lhs.0 < rhs.0
            }
        }
        return rank(oidc) ?? rank(legacy)
    }

    private static func entry(scope: String, raw: [String: Any]) -> GrokAuthEntry? {
        guard let accessToken = nonEmpty(raw["key"]) else { return nil }
        return GrokAuthEntry(
            scope: scope,
            accessToken: accessToken,
            refreshToken: nonEmpty(raw["refresh_token"]),
            expiresAt: parseExpiry(raw["expires_at"]),
            authMode: nonEmpty(raw["auth_mode"]),
            email: nonEmpty(raw["email"]),
            oidcIssuer: nonEmpty(raw["oidc_issuer"]) ?? defaultIssuer,
            oidcClientID: nonEmpty(raw["oidc_client_id"]) ?? clientID(fromScope: scope)
        )
    }

    private static func clientID(fromScope scope: String) -> String? {
        guard let range = scope.range(of: "::") else { return nil }
        let id = String(scope[range.upperBound...])
        return id.isEmpty ? nil : id
    }

    /// `expires_at` is epoch milliseconds on current CLI logins; tolerate
    /// epoch seconds and ISO strings from other writer versions.
    static func parseExpiry(_ value: Any?) -> Date? {
        if let raw = value as? Double {
            return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
        }
        if let raw = value as? Int {
            return parseExpiry(Double(raw))
        }
        if let raw = value as? String {
            return GrokTimestamp.parse(raw)
        }
        return nil
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let raw = value as? Double { return raw }
        if let raw = value as? Int { return TimeInterval(raw) }
        if let raw = value as? String { return TimeInterval(raw) }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        return raw
    }
}
