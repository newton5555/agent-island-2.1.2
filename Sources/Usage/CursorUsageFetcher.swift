import Foundation

/// One billing-period allowance, the number Cursor's own usage bar shows.
/// Cursor meters a single included-usage pool per billing cycle — not a
/// 5h/weekly pair — so the strip shows one meter and one reset date.
struct CursorUsageSnapshot: Codable, Equatable {
    /// 0…1 of the included allowance consumed (`planUsage.totalPercentUsed`).
    var usedPercent: Double
    /// End of the current billing cycle (`billingCycleEnd`, ms since epoch).
    var periodEnd: Date?
    /// "free" / "pro" / … from GetPlanInfo, lowercased.
    var planName: String?
}

/// Cursor's real numbers, from the RPC its own usage bar reads:
///   POST api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
///   POST …/GetPlanInfo
/// The legacy `cursor.com/api/usage` still answers but reports a retired
/// per-request counter — zeros and a null cap on current plans — so it is
/// deliberately not used. Verified live 2026-08-08 (free tier): 200 with
/// `planUsage.totalPercentUsed` and a real `billingCycleEnd`.
enum CursorUsageFetcher {
    enum Outcome {
        case success(CursorUsageSnapshot)
        /// 401/403 from the dashboard — the Cursor login itself is stale.
        case reauthRequired
        case failed(String)
        /// No state db — Cursor never signed in on this machine.
        case notInstalled
    }

    private static let rpcBase = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
    /// Cursor gates these endpoints on a Connect client User-Agent the same
    /// way Anthropic gates its usage endpoint on the CLI's.
    private static let userAgent = "connect-es/1.6.1"

    static func fetch() async -> Outcome {
        guard CursorCredentials.exists() else { return .notInstalled }
        guard let session = CursorCredentials.readSession() else { return .reauthRequired }

        switch await post(method: "GetCurrentPeriodUsage", session: session) {
        case .transport(let message):
            return .failed(message)
        case .http(401, _), .http(403, _):
            return .reauthRequired
        case .http(let status, let data):
            guard status == 200 else { return .failed("http \(status)") }
            guard var snapshot = parseUsage(data) else { return .failed("parse error") }
            // Plan is garnish — a failure only costs the chip, never the bar.
            if case .http(200, let planData) = await post(method: "GetPlanInfo", session: session) {
                snapshot.planName = parsePlanName(planData)
            }
            if snapshot.planName == nil { snapshot.planName = CursorCredentials.cachedPlan() }
            return .success(snapshot)
        }
    }

    // MARK: - Parsing (unit-tested)

    static func parseUsage(_ data: Data) -> CursorUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["planUsage"] as? [String: Any] else { return nil }
        // totalPercentUsed covers the whole included allowance (agent +
        // API); when absent, the larger half is the better "how close am I"
        // signal since only one is usually in play.
        let percent = doubleValue(usage["totalPercentUsed"])
            ?? max(doubleValue(usage["autoPercentUsed"]) ?? 0,
                   doubleValue(usage["apiPercentUsed"]) ?? 0)
        return CursorUsageSnapshot(
            usedPercent: min(1, max(0, percent / 100)),
            periodEnd: epochMillisDate(root["billingCycleEnd"]),
            planName: nil
        )
    }

    static func parsePlanName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["planInfo"] as? [String: Any],
              let name = info["planName"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name.lowercased()
    }

    /// Connect encodes int64 as STRING in JSON ("1786296946267"); tolerate
    /// both that and a plain number.
    static func epochMillisDate(_ value: Any?) -> Date? {
        guard let millis = doubleValue(value), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    // MARK: - HTTP

    private enum HTTPOutcome {
        case http(Int, Data)
        case transport(String)
    }

    private static func post(method: String, session: CursorCredentials.Session) async -> HTTPOutcome {
        guard let url = URL(string: rpcBase + method) else { return .transport("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25 // never let a wedged tunnel hang the poll loop
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        // Connect refuses a request that doesn't state its protocol version.
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .http(status, data)
        } catch {
            return .transport(error is URLError ? L10n.tr("network drop") : error.localizedDescription)
        }
    }
}
