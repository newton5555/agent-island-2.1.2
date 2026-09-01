import Foundation

/// Timestamp parser tolerant of the Grok endpoints' 6-digit fractional
/// seconds ("2026-07-31T15:48:23.488813+00:00") — Foundation's ISO8601
/// formatter only matches millisecond fractions, so microsecond stamps are
/// trimmed to 3 digits before the fractional parse.
enum GrokTimestamp {
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        guard let range = raw.range(of: #"\.\d+"#, options: .regularExpression) else { return nil }
        let trimmed = raw.replacingCharacters(in: range, with: String(raw[range].prefix(4)))
        if let date = fractional.date(from: trimmed) { return date }
        return plain.date(from: raw.replacingCharacters(in: range, with: ""))
    }
}

/// One per-product consumption row inside the weekly credit pool
/// (`config.productUsage`) — what the hover tooltip breaks the pool into.
struct GrokProductUsage: Codable, Equatable {
    var product: String
    /// Normalized to 0...1 like the pool percent. nil when the endpoint
    /// lists the product without a percent (absence is data, not zero).
    var usedPercent: Double?
}

/// What the island renders for Grok: the weekly credit pool (the number
/// SuperGrok users budget around) plus the monthly dollar budget. Codable
/// so the last good values survive a relaunch via the UserDefaults cache.
struct GrokBillingSnapshot: Codable, Equatable {
    /// Weekly pool consumption, normalized to 0...1.
    var weeklyUsedPercent: Double
    var weeklyPeriodEnd: Date?
    var monthlyUsedCents: Int?
    var monthlyLimitCents: Int?
    var monthlyPeriodEnd: Date?
    /// Per-product weekly breakdown. Optional so pre-1.8.1 cached snapshots
    /// keep decoding.
    var productUsage: [GrokProductUsage]? = nil
}

/// Decoders for the two `cli-chat-proxy.grok.com/v1/billing` payloads.
/// Kept JSONSerialization-shaped (like `UsageFetcher`) because the weekly
/// response omits `creditUsagePercent` entirely at zero usage — absence is
/// data, not an error.
enum GrokBillingParser {
    struct WeeklyPool: Equatable {
        var usedPercent: Double
        var periodEnd: Date?
        var products: [GrokProductUsage] = []
    }

    struct MonthlyBudget: Equatable {
        var usedCents: Int?
        var limitCents: Int?
        var periodEnd: Date?
    }

    /// `GET /v1/billing?format=credits` — config.currentPeriod carries the
    /// weekly window; creditUsagePercent is 0–100 and omitted when nothing
    /// has been used this period yet.
    static func parseWeekly(_ data: Data) -> WeeklyPool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { return nil }
        let percent = number(config["creditUsagePercent"]) ?? number(root["creditUsagePercent"]) ?? 0
        let period = config["currentPeriod"] as? [String: Any]
        let end = timestamp(period?["end"]) ?? timestamp(config["billingPeriodEnd"])
        return WeeklyPool(
            usedPercent: min(1, max(0, percent / 100)),
            periodEnd: end,
            products: productUsage(config["productUsage"])
        )
    }

    /// `config.productUsage` rows — proxy builds have shipped the percent
    /// under both `usagePercent` and `creditUsagePercent`, so accept either.
    private static func productUsage(_ value: Any?) -> [GrokProductUsage] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let product = row["product"] as? String, !product.isEmpty else { return nil }
            let percent = number(row["usagePercent"]) ?? number(row["creditUsagePercent"])
            return GrokProductUsage(
                product: product,
                usedPercent: percent.map { min(1, max(0, $0 / 100)) }
            )
        }
    }

    /// `GET /v1/billing` — monthlyLimit/used are `{ "val": <cents> }`.
    static func parseMonthly(_ data: Data) -> MonthlyBudget? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { return nil }
        return MonthlyBudget(
            usedCents: cents(config["used"]),
            limitCents: cents(config["monthlyLimit"]),
            periodEnd: timestamp(config["billingPeriodEnd"])
        )
    }

    /// "$40" for whole dollars, "$1.23" otherwise — the strip has no room
    /// for trailing ".00" noise. Caller prepends the currency symbol.
    static func dollars(fromCents rawCents: Int) -> String {
        let cents = max(0, rawCents)
        if cents % 100 == 0 { return "\(cents / 100)" }
        return String(format: "%.2f", Double(cents) / 100)
    }

    private static func cents(_ value: Any?) -> Int? {
        guard let box = value as? [String: Any] else { return nil }
        return number(box["val"]).map { Int($0.rounded()) }
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return GrokTimestamp.parse(raw)
    }
}
