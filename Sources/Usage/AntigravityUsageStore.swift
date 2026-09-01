import Foundation

/// Gemini's slice of the panel: the last fetched quota snapshot plus the
/// account identity from oauth_creds.json. Timer-free like GrokUsageStore —
/// it rides `UsageStore.refresh()`'s cadence via `kickRefresh()` behind the
/// same 120s attempt floor, with a UserDefaults snapshot cache so relaunch
/// doesn't blank the strip.
@MainActor
final class AntigravityUsageStore: ObservableObject {
    static let shared = AntigravityUsageStore()

    @Published private(set) var snapshot: AntigravityQuotaSnapshot?
    /// Non-nil while the latest fetch ended in anything but data. Values in
    /// `snapshot` are the preserved last-good numbers in that case.
    @Published private(set) var statusCaption: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var accountEmail: String?
    @Published private(set) var loading = false

    /// Detection is launch-static, same as the other providers.
    let detection: AntigravityAuthDetection

    private var lastAttempt: Date?
    private static let cacheKey = "AntigravityUsageStore.lastSnapshot.v2"
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60
    private static let minAttemptGap: TimeInterval = 120

    private struct CachedSnapshot: Codable {
        var snapshot: AntigravityQuotaSnapshot
        var updatedAt: Date
    }

    private init() {
        if AppEnvironment.isDemo {
            if AppEnvironment.demoGuestFixturesEnabled {
                let now = Date()
                detection = .signedIn
                snapshot = AntigravityQuotaSnapshot(
                    buckets: [
                        AntigravityQuotaBucket(
                            bucketId: "gemini-weekly",
                            groupLabel: "Gemini Models",
                            window: "weekly",
                            usedPercent: 0.43,
                            resetAt: now.addingTimeInterval(4 * 24 * 3600)
                        ),
                        AntigravityQuotaBucket(
                            bucketId: "3p-weekly",
                            groupLabel: "Claude and GPT models",
                            window: "weekly",
                            usedPercent: 0.18,
                            resetAt: now.addingTimeInterval(4 * 24 * 3600)
                        ),
                    ],
                    tierID: "free-tier",
                    tierLabel: "Antigravity Starter Quota"
                )
                lastUpdated = now
            } else {
                detection = .notInstalled
            }
            return
        }
        detection = AntigravityCredentials.detect()
        guard detection == .signedIn else { return }
        loadIdentity()
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
              Date().timeIntervalSince(cached.updatedAt) <= Self.cacheMaxAge else { return }
        snapshot = cached.snapshot
        lastUpdated = cached.updatedAt
    }

    /// Tier chip for the Settings row / strip — compacted to sit beside
    /// PRO and MAX ("ANTIGRAVITY STARTER QUOTA" → "STARTER").
    var tierBadge: String? {
        AntigravityQuotaParser.compactTierBadge(
            label: snapshot?.tierLabel, tierID: snapshot?.tierID)
    }

    func kickRefresh() {
        guard !AppEnvironment.isDemo,
              detection == .signedIn,
              ProviderVisibilityStore.shared.antigravityPanelShown,
              !loading else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minAttemptGap { return }
        lastAttempt = Date()
        loading = true
        Task { [weak self] in
            let outcome = await AntigravityUsageFetcher.fetch()
            self?.apply(outcome)
        }
    }

    private func apply(_ outcome: AntigravityUsageFetcher.Outcome) {
        loading = false
        switch outcome {
        case .success(let fresh):
            snapshot = fresh
            statusCaption = nil
            lastUpdated = Date()
            loadIdentity()
            persist(fresh)
        case .notRunning:
            // Antigravity keeps its quota in-process; with it closed there is
            // nothing to read anywhere on this machine. Keep the last good
            // numbers — the row's sync age already dates them, and the
            // warning line this used to add both nagged and leaked a ghost
            // "no data" tile through secondaryMissing (owner report,
            // 2026-08-09). Only a truly empty state earns a caption.
            statusCaption = snapshot == nil
                ? L10n.tr("start Antigravity to read quota")
                : nil
        case .failed(let message):
            // Keep the last good numbers; the caption admits staleness.
            statusCaption = message
        case .notInstalled:
            snapshot = nil
            statusCaption = nil
        }
    }

    /// The IDE roots write oauth_creds.json; the CLI keeps its token in the
    /// keychain and writes no such file, so the email comes off the language
    /// server instead. Reading the keychain would work too, but only by
    /// asking for the secret itself — which raises the keychain dialog on
    /// every refresh, for a hover-card caption.
    private func loadIdentity() {
        if let creds = AntigravityCredentials.loadCreds(from: AntigravityCredentials.credsURL()) {
            accountEmail = creds.email
            return
        }
        Task { [weak self] in
            let email = await AntigravityUsageFetcher.accountEmail()
            guard let self, let email else { return }
            self.accountEmail = email
        }
    }

    private func persist(_ fresh: AntigravityQuotaSnapshot) {
        let cached = CachedSnapshot(snapshot: fresh, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
