import Foundation

/// Fetches the Grok weekly credit pool + monthly budget from the CLI's own
/// proxy (`cli-chat-proxy.grok.com/v1/billing`), authenticating with the
/// `~/.grok/auth.json` access token and refreshing it through auth.x.ai
/// when it is expired or rejected. Display-only — no transcript monitoring,
/// no alarms live here.
enum GrokUsageFetcher {
    enum Outcome {
        case success(GrokBillingSnapshot)
        /// Refresh path exhausted — the user has to run `grok login`.
        case reauthRequired
        case failed(String)
        /// No auth.json — Grok CLI never logged in on this machine.
        case notInstalled
    }

    private static let billingBase = "https://cli-chat-proxy.grok.com/v1/billing"
    private static let clientVersion = "0.2.114"
    private static let userAgent =
        "grok-pager/0.2.114 grok-shell/0.2.114 (macos; aarch64)"

    static func fetch() async -> Outcome {
        let authURL = GrokAuthFile.defaultURL()
        guard var entry = GrokAuthFile.loadEntry(from: authURL) else { return .notInstalled }

        // Proactive refresh near expiry (the access token lives ~6h). A
        // failed refresh still tries the billing call with the old token —
        // clock skew can make a working token look expired.
        if GrokAuthFile.needsRefresh(entry), entry.refreshToken != nil,
           let refreshed = await refresh(entry: entry, authURL: authURL) {
            entry = refreshed
        }

        switch await fetchBilling(token: entry.accessToken) {
        case .success(let snapshot):
            return .success(snapshot)
        case .unauthorized:
            guard entry.refreshToken != nil,
                  let refreshed = await refresh(entry: entry, authURL: authURL) else {
                return .reauthRequired
            }
            switch await fetchBilling(token: refreshed.accessToken) {
            case .success(let snapshot): return .success(snapshot)
            case .unauthorized:          return .reauthRequired
            case .failed(let message):   return .failed(message)
            }
        case .failed(let message):
            return .failed(message)
        }
    }

    // MARK: - Billing

    private enum BillingResult {
        case success(GrokBillingSnapshot)
        case unauthorized
        case failed(String)
    }

    private static func fetchBilling(token: String) async -> BillingResult {
        async let weeklyResponse = get(url: "\(billingBase)?format=credits", token: token)
        async let monthlyResponse = get(url: billingBase, token: token)
        let weekly = await weeklyResponse
        let monthly = await monthlyResponse

        switch weekly {
        case .http(401, _), .http(403, _):
            return .unauthorized
        case .http(let status, let data):
            guard status == 200 else { return .failed("http \(status)") }
            guard let pool = GrokBillingParser.parseWeekly(data) else {
                return .failed("parse error")
            }
            // Monthly is best-effort garnish — a failure only costs the
            // dollar caption, never the weekly bar.
            var budget: GrokBillingParser.MonthlyBudget?
            if case .http(200, let monthlyData) = monthly {
                budget = GrokBillingParser.parseMonthly(monthlyData)
            }
            return .success(GrokBillingSnapshot(
                weeklyUsedPercent: pool.usedPercent,
                weeklyPeriodEnd: pool.periodEnd,
                monthlyUsedCents: budget?.usedCents,
                monthlyLimitCents: budget?.limitCents,
                monthlyPeriodEnd: budget?.periodEnd,
                productUsage: pool.products.isEmpty ? nil : pool.products
            ))
        case .transport(let message):
            return .failed(message)
        }
    }

    private enum HTTPOutcome {
        case http(Int, Data)
        case transport(String)
    }

    private static func get(url: String, token: String) async -> HTTPOutcome {
        guard let requestURL = URL(string: url) else { return .transport("bad url") }
        var req = URLRequest(url: requestURL)
        req.timeoutInterval = 25 // never let a wedged tunnel hang the poll loop
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .http(status, data)
        } catch {
            return .transport(error is URLError ? L10n.tr("network drop") : error.localizedDescription)
        }
    }

    // MARK: - Token refresh

    /// Exchange the refresh token at the issuer's token endpoint. The
    /// response rotates the refresh token, so success is defined as "the
    /// writeback landed" — an in-memory-only rotation would strand the
    /// user's `grok` CLI login on the next refresh.
    private static func refresh(entry: GrokAuthEntry, authURL: URL) async -> GrokAuthEntry? {
        guard let refreshToken = entry.refreshToken,
              let clientID = entry.oidcClientID else { return nil }

        let endpoint = await tokenEndpoint(issuer: entry.oidcIssuer)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GrokAuthFile.applyRefreshResponse(data, to: authURL, scope: entry.scope)
    }

    /// OIDC discovery for the token endpoint, with the conventional
    /// `/oauth2/token` path as the offline fallback.
    private static func tokenEndpoint(issuer: String) async -> URL {
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        let fallback = URL(string: "\(base)/oauth2/token")
            ?? URL(fileURLWithPath: "/dev/null")
        guard let wellKnown = URL(string: "\(base)/.well-known/openid-configuration") else {
            return fallback
        }
        var req = URLRequest(url: wellKnown)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["token_endpoint"] as? String,
              let url = URL(string: raw) else {
            return fallback
        }
        return url
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(escaped)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
