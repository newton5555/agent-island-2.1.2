import Foundation

enum UsageFetcher {
    // MARK: - Transport

    /// SSL handshakes through flaky proxies/VPNs fail in bursts that clear
    /// within seconds ("安全连接失败"). Retry transient transport errors
    /// twice (0.8s / 2.4s backoff) before letting anything reach the UI.
    private static func transientRetryData(for req: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await URLSession.shared.data(for: req)
            } catch let error as URLError where isTransient(error.code) && attempt < 2 {
                attempt += 1
                try? await Task.sleep(nanoseconds: attempt == 1 ? 800_000_000 : 2_400_000_000)
            }
        }
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .secureConnectionFailed, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Tile-sized message instead of the full system sentence — the values
    /// themselves are preserved upstream, this only captions the staleness.
    private static func shortError(_ error: Error) -> String {
        (error is URLError) ? L10n.tr("network drop") : error.localizedDescription
    }

    // MARK: - Codex

    /// Codex usage lives at chatgpt.com/backend-api/wham/usage and accepts
    /// the access_token from ~/.codex/auth.json. The endpoint is reliable
    /// and rarely rate-limited, so this is the easy half of the integration.
    static func fetchCodex() async -> AppUsage {
        guard let token = readCodexAccessToken() else {
            return errorPair("no codex auth")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 25 // never let a wedged tunnel hang the poll loop
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await transientRetryData(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 401 means the access_token in ~/.codex/auth.json has expired.
            // The Codex CLI rotates this token on its own — there's nothing
            // we can do from here, so surface the exact remediation step.
            if status == 401 {
                return errorPair("auth expired — codex login")
            }
            if status != 200 {
                return errorPair("http \(status)")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = obj["rate_limit"] as? [String: Any] else {
                return errorPair("parse error")
            }
            var usage = AppUsage(
                fiveHour: parseCodexWindow(rl["primary_window"]),
                weekly: parseCodexWindow(rl["secondary_window"]),
                plan: obj["plan_type"] as? String
            )
            // Banked resets ("reset cards") ride the same payload:
            // rate_limit_reset_credits.available_count.
            if let credits = obj["rate_limit_reset_credits"] as? [String: Any] {
                usage.resetCards = (credits["available_count"] as? Int)
                    ?? (credits["available_count"] as? Double).map(Int.init)
            }
            // Per-card detail (title + expiry) lives on its own endpoint.
            // Best-effort: a failure only costs the expiry rows, never the
            // count above.
            if (usage.resetCards ?? 0) > 0 {
                usage.resetCardDetails = await fetchResetCardDetails(token: token)
            }
            return usage
        } catch {
            return errorPair(shortError(error))
        }
    }

    private static func errorPair(_ message: String) -> AppUsage {
        AppUsage(
            fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: message),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: message)
        )
    }

    private static func readCodexAccessToken() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }

    /// GET wham/rate-limit-reset-credits → the available cards, each with
    /// OpenAI's own title ("Full reset") and expires_at. Returns nil on any
    /// failure so the caller keeps the count-only display.
    private static func fetchResetCardDetails(token: String) async -> [ResetCard]? {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["credits"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard (row["status"] as? String) == "available",
                  let id = row["id"] as? String else { return nil }
            let title = (row["title"] as? String) ?? "Reset"
            let expires = (row["expires_at"] as? String).flatMap {
                iso.date(from: $0) ?? fallback.date(from: $0)
            }
            return ResetCard(id: id, title: title, expiresAt: expires)
        }
    }

    private static func parseCodexWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        let used = (d["used_percent"] as? Double) ?? 0
        let resetAt = (d["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        // The payload states its own window length (604800s = the single
        // weekly window Codex moved to in July 2026). Labels render from it.
        let period = d["limit_window_seconds"] as? Double
        return WindowUsage(usedPercent: used / 100, resetAt: resetAt, error: nil, periodSeconds: period)
    }

    // MARK: - Claude

    /// Anthropic doesn't ship a usage endpoint for end users — Claude Code
    /// itself talks to api.anthropic.com/api/oauth/usage with a beta header
    /// and a User-Agent that identifies as the CLI. We replicate that.
    ///
    /// Token acquisition (env → keychain → refresh → rotation writeback) lives
    /// behind `ClaudeCredentials`. We hand it the usage probe and render its
    /// resolution: a parsed `AppUsage`, or an error caption (re-auth or last
    /// error) via `errorPair`.
    static func fetchClaude() async -> AppUsage {
        let resolution = await ClaudeCredentials.resolveUsage { token, plan in
            await fetchClaudeUsage(token: token, plan: plan)
        }
        switch resolution {
        case .usage(let u):              return u
        case .reauthRequired(let msg):   return errorPair(msg)
        case .failed(let msg):           return errorPair(msg)
        }
    }

    private static func fetchClaudeUsage(token: String, plan: String?) async -> ClaudeCredentials.ProbeOutcome {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 25 // never let a wedged tunnel hang the poll loop
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic gates this endpoint on a CLI User-Agent. Without it the
        // request 401s even with a valid token.
        req.setValue("claude-code/2.1.121", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await transientRetryData(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 403 { return .scopeInsufficient }
            if http.statusCode == 429 { return .rateLimited }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            // The endpoint also returns 200 with a rate_limit_error body
            // sometimes; don't trust the status code alone.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = obj["error"] as? [String: Any],
                   let type = err["type"] as? String, type == "rate_limit_error" {
                    return .rateLimited
                }
                return .success(AppUsage(
                    fiveHour: parseClaudeWindow(obj["five_hour"], periodSeconds: 5 * 3600),
                    weekly: parseClaudeWindow(obj["seven_day"], periodSeconds: 7 * 86400),
                    plan: plan
                ))
            }
            return .otherError("parse error")
        } catch {
            return .otherError(shortError(error))
        }
    }

    private static func parseClaudeWindow(_ obj: Any?, periodSeconds: TimeInterval) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        // Anthropic returns `utilization` as a percentage in [0, 100], not a
        // normalized [0, 1] fraction. An earlier `raw > 1 ? raw / 100 : raw`
        // heuristic broke the moment the 5h window reset: utilization values
        // in (0, 1] (e.g. 0.5% used → 0.5) were treated as already-normalized
        // and rendered as 50%–100%. Always divide by 100; clamp below.
        let raw = (d["utilization"] as? Double) ?? (d["used_percent"] as? Double) ?? 0
        let normalized = raw / 100.0
        var resetAt: Date?
        if let r = d["resets_at"] as? Double {
            resetAt = Date(timeIntervalSince1970: r)
        } else if let s = d["resets_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return WindowUsage(usedPercent: min(1, max(0, normalized)), resetAt: resetAt, error: nil, periodSeconds: periodSeconds)
    }
}
