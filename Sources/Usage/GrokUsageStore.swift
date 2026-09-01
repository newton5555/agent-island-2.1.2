import Foundation

/// Grok's slice of the panel: the last fetched billing snapshot plus the
/// account identity from auth.json. Deliberately timer-free — it rides
/// `UsageStore.refresh()`'s existing cadence (5–30 min polls, wake, unlock,
/// network recovery, manual refresh) via `kickRefresh()`, with a small
/// attempt floor so bursty kick sources never turn into extra polling.
@MainActor
final class GrokUsageStore: ObservableObject {
    static let shared = GrokUsageStore()

    @Published private(set) var snapshot: GrokBillingSnapshot?
    /// Non-nil while the latest fetch failed. Values in `snapshot` are the
    /// preserved last-good numbers in that case, same policy as UsageStore.
    @Published private(set) var errorCaption: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var accountEmail: String?
    /// "SUPERGROK" for OIDC logins, else the raw auth_mode uppercased.
    @Published private(set) var authModeBadge: String?

    @Published private(set) var loading = false
    private var lastAttempt: Date?
    private static let cacheKey = "GrokUsageStore.lastSnapshot.v1"
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60
    /// De-dupes kick bursts (poll + boundary + manual all landing close
    /// together); the real cadence stays whatever UsageStore runs.
    private static let minAttemptGap: TimeInterval = 120

    private struct CachedSnapshot: Codable {
        var snapshot: GrokBillingSnapshot
        var updatedAt: Date
    }

    private init() {
        if AppEnvironment.isDemo {
            if AppEnvironment.demoGuestFixturesEnabled {
                let now = Date()
                snapshot = GrokBillingSnapshot(
                    weeklyUsedPercent: 0.37,
                    weeklyPeriodEnd: now.addingTimeInterval(3 * 86400 + 9 * 3600),
                    monthlyUsedCents: 123,
                    monthlyLimitCents: 4000,
                    monthlyPeriodEnd: now.addingTimeInterval(26 * 86400),
                    productUsage: [
                        GrokProductUsage(product: "grok-code", usedPercent: 0.29),
                        GrokProductUsage(product: "grok-web", usedPercent: 0.08),
                    ]
                )
                authModeBadge = "SUPERGROK"
                lastUpdated = now
            }
            return
        }
        loadIdentity()
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
              Date().timeIntervalSince(cached.updatedAt) <= Self.cacheMaxAge else { return }
        snapshot = cached.snapshot
        lastUpdated = cached.updatedAt
    }

    func kickRefresh() {
        guard !AppEnvironment.isDemo,
              ProviderVisibilityStore.shared.grokPanelShown,
              !loading else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minAttemptGap { return }
        lastAttempt = Date()
        loading = true
        Task { [weak self] in
            let outcome = await GrokUsageFetcher.fetch()
            self?.apply(outcome)
        }
    }

    private func apply(_ outcome: GrokUsageFetcher.Outcome) {
        loading = false
        switch outcome {
        case .success(let fresh):
            snapshot = fresh
            errorCaption = nil
            lastUpdated = Date()
            // The fetch may have rotated tokens or the user re-logged in
            // since launch — keep the identity row honest.
            loadIdentity()
            persist(fresh)
        case .reauthRequired:
            errorCaption = L10n.tr("sign in again — run grok login")
        case .failed(let message):
            // Keep the last good numbers; the caption admits staleness.
            errorCaption = message
        case .notInstalled:
            snapshot = nil
            errorCaption = nil
        }
    }

    private func loadIdentity() {
        guard let entry = GrokAuthFile.loadEntry() else {
            accountEmail = nil
            authModeBadge = nil
            return
        }
        accountEmail = entry.email
        authModeBadge = entry.isSuperGrok ? "SUPERGROK" : entry.authMode?.uppercased()
    }

    private func persist(_ fresh: GrokBillingSnapshot) {
        let cached = CachedSnapshot(snapshot: fresh, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
