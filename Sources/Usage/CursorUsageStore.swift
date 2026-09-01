import Foundation

/// Cursor's slice of the panel: the last fetched billing-period snapshot
/// plus identity from the editor's own store. Timer-free — it rides
/// `UsageStore.refresh()`'s cadence via `kickRefresh()` behind the slot
/// selection, with an attempt floor so kick bursts never add polling.
@MainActor
final class CursorUsageStore: ObservableObject {
    static let shared = CursorUsageStore()

    @Published private(set) var snapshot: CursorUsageSnapshot?
    /// Non-nil while the latest fetch failed. Values in `snapshot` are the
    /// preserved last-good numbers in that case, same policy as UsageStore.
    @Published private(set) var errorCaption: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var accountEmail: String?

    @Published private(set) var loading = false
    private var lastAttempt: Date?
    private static let cacheKey = "CursorUsageStore.lastSnapshot.v1"
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60
    private static let minAttemptGap: TimeInterval = 120

    /// "FREE" / "PRO" chip text for the Settings row.
    var planBadge: String? {
        (snapshot?.planName ?? CursorCredentials.cachedPlan())?.uppercased()
    }

    private struct CachedSnapshot: Codable {
        var snapshot: CursorUsageSnapshot
        var updatedAt: Date
    }

    private init() {
        if AppEnvironment.isDemo {
            if AppEnvironment.demoGuestFixturesEnabled {
                let now = Date()
                snapshot = CursorUsageSnapshot(
                    usedPercent: 0.21,
                    periodEnd: now.addingTimeInterval(12 * 86400),
                    planName: "pro"
                )
                lastUpdated = now
            }
            return
        }
        accountEmail = CursorCredentials.cachedEmail()
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
              Date().timeIntervalSince(cached.updatedAt) <= Self.cacheMaxAge else { return }
        snapshot = cached.snapshot
        lastUpdated = cached.updatedAt
    }

    func kickRefresh() {
        guard !AppEnvironment.isDemo,
              ProviderVisibilityStore.shared.cursorPanelShown,
              !loading else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minAttemptGap { return }
        lastAttempt = Date()
        loading = true
        Task { [weak self] in
            let outcome = await CursorUsageFetcher.fetch()
            self?.apply(outcome)
        }
    }

    private func apply(_ outcome: CursorUsageFetcher.Outcome) {
        loading = false
        switch outcome {
        case .success(let fresh):
            snapshot = fresh
            errorCaption = nil
            lastUpdated = Date()
            accountEmail = CursorCredentials.cachedEmail()
            persist(fresh)
        case .reauthRequired:
            errorCaption = L10n.tr("sign in again — open Cursor")
        case .failed(let message):
            // Keep the last good numbers; the caption admits staleness.
            errorCaption = message
        case .notInstalled:
            snapshot = nil
            errorCaption = nil
        }
    }

    private func persist(_ fresh: CursorUsageSnapshot) {
        let cached = CachedSnapshot(snapshot: fresh, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
