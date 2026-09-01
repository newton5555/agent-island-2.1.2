import Foundation

/// One quota bucket from `RetrieveUserQuotaSummary`, normalized to the app's
/// used-percent vocabulary (the endpoint reports how much is *left*).
///
/// Antigravity pools by model family rather than by model: on a real account
/// the summary returns exactly two buckets — `gemini-weekly` covering Gemini
/// Flash and Pro, and `3p-weekly` covering Claude and GPT — so the old
/// per-model Pro/Flash split this file used to carry never matches anything.
/// Paid tiers are documented to add 5h windows, so `window` is kept and the
/// count is never assumed.
struct AntigravityQuotaBucket: Codable, Equatable {
    var bucketId: String
    /// Google's own group name, e.g. "Gemini Models".
    var groupLabel: String
    /// "weekly", "5h", … — nil when Google stops sending it.
    var window: String?
    /// 0...1 consumed.
    var usedPercent: Double
    var resetAt: Date?

    static let weekSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// How long this bucket's window runs, for the island pill's elapsed
    /// arc. Every bucket a real account returns is `weekly`; paid tiers are
    /// documented to add a 5h window, so that is handled rather than assumed
    /// away, and anything unrecognized falls back to the weekly reality.
    var periodSeconds: TimeInterval {
        switch (window ?? "").lowercased() {
        case "5h", "five_hour", "fivehour": return 5 * 60 * 60
        case "daily", "1d": return 24 * 60 * 60
        default: return Self.weekSeconds
        }
    }

    /// Compact name for the island strip. Known pools get a short hand-set
    /// label; anything new falls back to Google's group name so a bucket we
    /// have never seen still reads as itself instead of a raw id.
    var shortLabel: String {
        let family = bucketId.split(separator: "-").first.map(String.init) ?? bucketId
        switch family.lowercased() {
        case "gemini": return "Gemini"
        case "3p": return "Claude·GPT"
        default:
            let trimmed = groupLabel
                .replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? family : trimmed
        }
    }
}

/// What the island renders for Antigravity. Codable so the last good values survive
/// a relaunch — and, more importantly, survive Antigravity not running, which
/// is the only time its quota is unreadable at all.
struct AntigravityQuotaSnapshot: Codable, Equatable {
    var buckets: [AntigravityQuotaBucket]
    /// Raw tier id from `GetUserStatus.userTier` ("free-tier", …).
    var tierID: String?
    /// Google's own tier name, shown verbatim.
    var tierLabel: String?
    /// Google's explanation of how the shared pools burn down. Displayed as
    /// given rather than paraphrased — the rules are theirs, not ours.
    var note: String?

    /// The one pool this app surfaces: Gemini's. Antigravity also meters a
    /// Claude/GPT pool, and it is real data — but Claude and GPT are other
    /// providers' tiles in this app, so showing their pool under Antigravity
    /// read as cross-wiring (owner call, 2026-08-09: 只搞 Gemini). The raw
    /// buckets stay in the snapshot; only display narrows. An account with
    /// no Gemini-named pool falls back to whatever exists rather than
    /// showing nothing.
    var primary: AntigravityQuotaBucket? {
        buckets.first { $0.bucketId.lowercased().hasPrefix("gemini") }
            ?? buckets.first { $0.groupLabel.lowercased().contains("gemini") }
            ?? buckets.first
    }
}

/// Decoders for the local language server's JSON replies.
/// JSONSerialization-shaped like the other fetchers — absence is data here
/// too (an account can legitimately report zero buckets).
enum AntigravityQuotaParser {
    struct UserProfile: Equatable {
        var email: String?
        var tierID: String?
        var tierLabel: String?
    }

    /// `RetrieveUserQuotaSummary` → `{response:{groups:[{displayName,
    /// buckets:[{bucketId, window, remainingFraction, resetTime}]}],
    /// description}}`.
    ///
    /// The envelope key is not stable across versions (`response`, `summary`,
    /// or the groups sitting at the root), so all three are accepted.
    static func parseQuotaSummary(_ data: Data) -> (buckets: [AntigravityQuotaBucket], note: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let envelope = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        guard let groups = envelope["groups"] as? [[String: Any]] else { return ([], nil) }

        var out: [AntigravityQuotaBucket] = []
        for group in groups {
            let groupLabel = nonEmpty(group["displayName"]) ?? ""
            guard let rows = group["buckets"] as? [[String: Any]] else { continue }
            for row in rows {
                // A disabled bucket is one the account cannot use at all;
                // rendering it as "100% left" would invent headroom.
                if let disabled = row["disabled"] as? Bool, disabled { continue }
                guard let bucketId = nonEmpty(row["bucketId"]) else { continue }
                guard let remaining = fraction(row["remainingFraction"]) else { continue }
                out.append(AntigravityQuotaBucket(
                    bucketId: bucketId,
                    groupLabel: groupLabel,
                    window: nonEmpty(row["window"]),
                    usedPercent: min(1, max(0, 1 - remaining)),
                    resetAt: timestamp(row["resetTime"])
                ))
            }
        }
        return (out, nonEmpty(envelope["description"]))
    }

    /// `GetUserStatus` → identity and tier.
    ///
    /// The tier comes from `userTier.name`, never `planStatus.planInfo
    /// .planName`: on the owner's free account those read "Antigravity
    /// Starter Quota" and "Pro" respectively, and planName is the wrong one
    /// (a field inherited from Windsurf). Shown verbatim — Google keeps
    /// minting tier names and mapping them to an enum would only go stale.
    static func parseUserStatus(_ data: Data) -> UserProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let status = (root["userStatus"] as? [String: Any]) ?? root
        let tier = status["userTier"] as? [String: Any]
        return UserProfile(
            email: nonEmpty(status["email"]),
            tierID: nonEmpty(tier?["id"]),
            tierLabel: nonEmpty(tier?["name"])
        )
    }

    /// The tier chip has to read like its neighbours — Codex says PRO,
    /// Claude says MAX — and Google's tier names are sentences:
    /// "Antigravity Starter Quota", "Google AI Ultra". Dropping the filler
    /// words leaves the part that identifies the plan ("STARTER",
    /// "AI ULTRA"); the full name is still shown where there is room.
    static func compactTierBadge(label: String?, tierID: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        let filler: Set<String> = ["antigravity", "google", "quota", "plan", "tier"]
        let words = label.split(separator: " ").filter { !filler.contains($0.lowercased()) }
        guard !words.isEmpty else {
            return tierID == "free-tier" ? "FREE" : label.uppercased()
        }
        return words.joined(separator: " ").uppercased()
    }

    /// `remainingFraction` arrives as a plain 0...1 number, but the same
    /// field has been seen oneof-expanded into an object by other Connect
    /// clients, so both are accepted. Anything else is a missing value, not
    /// a full bucket — returning nil drops the row rather than claiming
    /// 100% headroom.
    static func fraction(_ value: Any?) -> Double? {
        if let direct = number(value) { return direct }
        guard let wrapper = value as? [String: Any] else { return nil }
        return number(wrapper["value"]) ?? number(wrapper["remainingFraction"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        return raw
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let raw = value as? String { return GrokTimestamp.parse(raw) }
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        return nil
    }
}
