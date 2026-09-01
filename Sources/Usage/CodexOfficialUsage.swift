import Foundation

/// The Codex client's own "personal usage" numbers, fetched from the same
/// backend endpoint the official app renders its heatmap from —
/// `wham/profiles/me` (path discovered in openai/codex `backend-client`).
///
/// This is the ONLY source that matches the official panel digit-for-digit.
/// An 85-day comparison (2026-07-17) proved the server-side count is NOT
/// reconstructible from local rollout logs: the two series disagree in BOTH
/// directions (the account aggregates every device, and the server applies
/// its own request accounting), so anything derived locally must be labeled
/// as the local ledger, never as "what OpenAI says".
struct CodexOfficialProfile: Equatable {
    let lifetimeTokens: Int
    let peakDailyTokens: Int
    /// Server day-cut buckets, keyed "yyyy-MM-dd" exactly as served.
    let dailyTokens: [String: Int]
    let fetchedAt: Date
}

@MainActor
final class CodexOfficialUsageStore: ObservableObject {
    static let shared = CodexOfficialUsageStore()

    @Published private(set) var profile: CodexOfficialProfile?
    private var inflight = false
    private var lastAttempt: Date?

    /// Cheap to call on every panel open; fetches at most every 30 minutes
    /// and never overlaps requests.
    func refreshIfStale(maxAge: TimeInterval = 1800) {
        if let p = profile, Date().timeIntervalSince(p.fetchedAt) < maxAge { return }
        if let t = lastAttempt, Date().timeIntervalSince(t) < 60 { return }
        guard !inflight else { return }
        inflight = true
        lastAttempt = Date()
        Task { [weak self] in
            let fetched = await CodexOfficialUsageFetcher.fetch()
            guard let self else { return }
            self.inflight = false
            if let fetched { self.profile = fetched }
        }
    }
}

enum CodexOfficialUsageFetcher {
    static func fetch() async -> CodexOfficialProfile? {
        guard let token = readAccessToken() else { return nil }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = json["stats"] as? [String: Any]
        else { return nil }

        var daily: [String: Int] = [:]
        for bucket in (stats["daily_usage_buckets"] as? [[String: Any]]) ?? [] {
            if let day = bucket["start_date"] as? String,
               let tokens = bucket["tokens"] as? Int {
                daily[day] = tokens
            }
        }
        return CodexOfficialProfile(
            lifetimeTokens: stats["lifetime_tokens"] as? Int ?? 0,
            peakDailyTokens: stats["peak_daily_tokens"] as? Int ?? 0,
            dailyTokens: daily,
            fetchedAt: Date()
        )
    }

    private static func readAccessToken() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let tokens = json["tokens"] as? [String: Any]
        return (tokens?["access_token"] as? String) ?? (json["access_token"] as? String)
    }
}
