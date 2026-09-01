import Foundation
import Combine
import Network
import AppKit

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    private init() {
        guard !AppEnvironment.isDemo,
              let snapshot = Self.loadCachedSnapshot() else { return }
        claude = snapshot.claude
        codex = snapshot.codex
        lastUpdated = snapshot.updatedAt
    }

    @Published var claude: AppUsage = .empty
    @Published var codex: AppUsage = .empty
    @Published var lastUpdated: Date?
    @Published var refreshWarning: String?
    @Published var loading = false
    /// When the current `loading` window started. A refresh normally clears
    /// `loading` within a couple seconds; if a fetch wedges (e.g. a half-open
    /// VPN tunnel that stays "connected" but never returns data), `loading`
    /// would otherwise stick true forever and every scheduled poll would no-op
    /// on the guard, freezing the panel at "synced N minutes ago". This lets
    /// `refresh()` treat a too-old loading window as wedged and restart it.
    private var loadingStartedAt: Date?
    /// Set while a `claude auth login` flow is in progress (spawned + still
    /// polling for the keychain to update). The UI hides the re-auth button
    /// during this window so users don't double-tap and spawn duplicate CLI
    /// processes; the click ends up no-ops anyway because the spawn check
    /// gates on this.
    @Published var claudeReauthInProgress = false
    /// Why the last in-app Claude login died, verbatim from the flow —
    /// cleared when a new attempt starts or one succeeds. Settings shows it
    /// under the Claude row so failures explain themselves.
    @Published var claudeReauthFailureCaption: String?
    @Published var codexReauthInProgress = false
    /// Label the auto-switcher rotated to most recently, shown on the Codex
    /// card until the next manual action. Real state, not explanation.
    @Published var codexAutoSwitched: String?
    /// The authorize URL of the Claude login round-trip currently in flight.
    /// Non-nil only while `claudeReauthInProgress` — the UI offers it as
    /// "Copy login link" for users whose Claude account lives in a different
    /// browser profile than the system default (the loopback callback
    /// accepts whichever browser opens the link).
    @Published var claudeLoginURL: URL?

    private var refreshTask: Task<Void, Never>?
    private var reauthPollTask: Task<Void, Never>?
    private var claudeReauthFollowupTask: Task<Void, Never>?
    private var codexReauthPollTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var boundaryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var intervalCancellable: AnyCancellable?
    private var netMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "UsageStore.network")
    private var lastNetStatus: NWPath.Status?
    private static let cacheKey = "UsageStore.lastSuccessfulUsage.v1"
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60

    /// Anthropic's /api/oauth/usage is aggressively rate-limited per token.
    /// `RefreshIntervalStore` enforces a 5-minute floor (300/900/1800).
    private var pollInterval: TimeInterval {
        TimeInterval(RefreshIntervalStore.shared.seconds)
    }

    /// Refresh on a "user is looking now" moment (opening the panel), but only
    /// when the data is already older than the poll interval. This is the whole
    /// trick to staying fresh without polling faster: it can never make a call
    /// the schedule wouldn't have made anyway, so opening the island ten times
    /// in a row still costs at most one fetch — no extra pressure on the
    /// rate-limited endpoint. Fresh data is fresh; stale data refreshes on open.
    func refreshIfStale() {
        guard let last = lastUpdated else { refresh(); return }
        if Date().timeIntervalSince(last) >= pollInterval { refresh() }
    }

    func refresh() {
        // Skip only if a refresh is genuinely in flight. A `loading` window
        // older than 90s is presumed wedged (a hung fetch that never returned),
        // so fall through and restart instead of no-op'ing forever — otherwise
        // the panel freezes at the last successful sync.
        if loading, let started = loadingStartedAt, Date().timeIntervalSince(started) < 90 { return }
        // Demo mode for screen recordings: skip the network entirely and
        // inject hand-tuned values that read as "real, healthy heavy-user
        // data". Reset times are recomputed each refresh so the countdowns
        // tick down naturally on camera. Off by default — only fires when
        // AGENTISLAND_DEMO=1 is set in the launching env.
        if AppEnvironment.isDemo {
            let now = Date()
            let claudeFiveHour = Self.demoDouble("AGENTISLAND_DEMO_CLAUDE_5H", fallback: 0.73)
            let claudeWeekly = Self.demoDouble("AGENTISLAND_DEMO_CLAUDE_WEEKLY", fallback: 0.81)
            let codexFiveHour = Self.demoDouble("AGENTISLAND_DEMO_CODEX_5H", fallback: 0.67)
            let codexWeekly = Self.demoDouble("AGENTISLAND_DEMO_CODEX_WEEKLY", fallback: 0.76)
            let claudeReset = Self.demoMinutes("AGENTISLAND_DEMO_CLAUDE_RESET_MINUTES", fallback: 107)
            let codexReset = Self.demoMinutes("AGENTISLAND_DEMO_CODEX_RESET_MINUTES", fallback: 143)
            let claudeError = ProcessInfo.processInfo.environment["AGENTISLAND_DEMO_CLAUDE_ERROR"]
            self.claude = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: claudeFiveHour,
                    resetAt: now.addingTimeInterval(TimeInterval(claudeReset * 60)),
                    error: claudeError
                ),
                weekly: WindowUsage(
                    usedPercent: claudeWeekly,
                    resetAt: now.addingTimeInterval(4 * 86400 + 11 * 3600),
                    error: claudeError
                ),
                plan: "max"
            )
            self.codex = AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: codexFiveHour,
                    resetAt: now.addingTimeInterval(TimeInterval(codexReset * 60)),
                    error: nil
                ),
                weekly: WindowUsage(
                    usedPercent: codexWeekly,
                    resetAt: now.addingTimeInterval(4 * 86400 + 18 * 3600),
                    error: nil
                ),
                plan: "pro"
            )
            self.lastUpdated = now
            self.refreshWarning = nil
            return
        }

        loading = true
        loadingStartedAt = Date()
        // Grok and Gemini ride this exact cadence (poll/wake/unlock/network/
        // manual) instead of owning timers; their stores no-op when
        // undetected or kicked again within their attempt floors.
        // Re-probe guest logins first: signing into a CLI after launch used
        // to leave the provider stuck at "not detected" until a relaunch.
        ProviderVisibilityStore.shared.redetectGuests()
        GrokUsageStore.shared.kickRefresh()
        AntigravityUsageStore.shared.kickRefresh()
        CursorUsageStore.shared.kickRefresh()
        refreshTask?.cancel()
        refreshTask = Task {
            async let codexResult = UsageFetcher.fetchCodex()
            async let claudeResult = UsageFetcher.fetchClaude()
            let c = await codexResult
            let cl = await claudeResult

            // Cancellation = network monitor saw the path come up while we
            // were mid-flight on a dead one. The fetched values are the
            // dead-path errors — drop them so the supersedes refresh
            // doesn't have a brief "cancelled" caption flash to overwrite.
            if Task.isCancelled {
                self.loading = false
                return
            }

            // Don't clobber existing good values when a fetch returns an
            // all-error result. A transient 429 shouldn't blank the panel
            // back to "0%" — that's worse than slightly stale data. Preserve
            // the last useful percentages, but carry the new error forward so
            // the UI admits the values are stale instead of showing a fake
            // fresh reset countdown. But if
            // the existing value is itself error-only (cold start sitting
            // on `.empty`, or a series of failures), let the new error
            // through — otherwise a single bad first fetch sticks "no data"
            // permanently even after the network recovers.
            let codexFailed = UsageStore.isErrorOnly(c)
            let claudeFailed = UsageStore.isErrorOnly(cl)

            let mergedCodex = UsageStore.mergedUsage(existing: self.codex, fetched: c)
            let mergedClaude = UsageStore.mergedUsage(existing: self.claude, fetched: cl)
            self.codex = mergedCodex
            self.claude = mergedClaude
            UsageStore.saveCachedSnapshot(claude: mergedClaude, codex: mergedCodex)
            self.refreshWarning = UsageStore.refreshWarning(codexFailed: codexFailed, claudeFailed: claudeFailed)
            self.lastUpdated = Date()
            self.loading = false
            self.scheduleBoundaryRefresh()
            self.maybeAutoSwitchCodex(mergedCodex)
        }
    }

    /// Accounts tried since the current exhaustion episode began; cleared
    /// the moment a reading comes back under 100%, so each episode walks
    /// the pool at most once and a fully-exhausted pool goes quiet instead
    /// of thrashing auth.json forever.
    private var codexAutoSwitchTried: Set<String> = []

    /// AUTO mode of `CodexAccountSwitcher` (owner call, 2026-08-08 — the
    /// codex-auto borrow). Runs on every fresh Codex reading: exhausted +
    /// enabled + a candidate exists → swap and immediately re-poll so the
    /// island shows the incoming account's numbers, not a stale 100%.
    private func maybeAutoSwitchCodex(_ usage: AppUsage) {
        guard CodexAccountSwitcher.autoSwitchEnabled else { return }
        let primary = usage.fiveHour.error == nil ? usage.fiveHour : usage.weekly
        guard primary.error == nil else { return }
        guard primary.usedPercent >= 0.999 else {
            codexAutoSwitchTried.removeAll()
            return
        }
        if let active = CodexAccountSwitcher.activeLabel() {
            codexAutoSwitchTried.insert(active)
        }
        guard let next = CodexAccountSwitcher.rotationCandidate(excluding: codexAutoSwitchTried),
              CodexAccountSwitcher.activate(next) else { return }
        codexAutoSwitchTried.insert(next.label)
        codexAutoSwitched = next.label
        refresh()
    }

    /// The 5-minute poll floor means a window can sit visibly expired — and,
    /// worse, an afterReset auto-resume never fires — for up to 5 minutes
    /// after it actually rolls over. Schedule one extra targeted fetch a few
    /// seconds past the soonest upcoming reset so the moment a window flips we
    /// pull fresh data: the countdown updates AND the changed resetAt drives
    /// the trigger engine. One-shot per reset, so it doesn't add to the poll
    /// rate the endpoint is sensitive to.
    private func scheduleBoundaryRefresh() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        let now = Date()
        let resets = [
            claude.fiveHour.resetAt, claude.weekly.resetAt,
            codex.fiveHour.resetAt, codex.weekly.resetAt,
        ].compactMap { $0 }.filter { $0 > now }
        guard let soonest = resets.min() else { return }
        // +8s cushion so the provider has flipped the window before we ask;
        // clamp the far end so a week-away weekly reset doesn't hold a timer
        // for days (the regular poll covers the long tail).
        let delay = min(soonest.timeIntervalSince(now) + 8, 6 * 3600)
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    private static func demoDouble(_ key: String, fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Double(raw) else { return fallback }
        return min(1, max(0, value))
    }

    private static func demoMinutes(_ key: String, fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Int(raw) else { return fallback }
        return max(1, value)
    }

    /// True when both windows have errors and zero values — nothing useful
    /// to show, so we keep whatever we had before.
    private static func isErrorOnly(_ u: AppUsage) -> Bool {
        u.fiveHour.error != nil && u.weekly.error != nil
            && u.fiveHour.usedPercent == 0 && u.weekly.usedPercent == 0
    }

    private static func mergedUsage(existing: AppUsage, fetched: AppUsage) -> AppUsage {
        guard isErrorOnly(fetched), !isErrorOnly(existing) else { return fetched }
        let error = fetched.fiveHour.error ?? fetched.weekly.error
        return AppUsage(
            fiveHour: WindowUsage(
                usedPercent: existing.fiveHour.usedPercent,
                resetAt: existing.fiveHour.resetAt,
                error: error,
                periodSeconds: existing.fiveHour.periodSeconds
            ),
            weekly: WindowUsage(
                usedPercent: existing.weekly.usedPercent,
                resetAt: existing.weekly.resetAt,
                error: error,
                periodSeconds: existing.weekly.periodSeconds
            ),
            plan: existing.plan,
            resetCards: existing.resetCards,
            resetCardDetails: existing.resetCardDetails
        )
    }

    private static func refreshWarning(codexFailed: Bool, claudeFailed: Bool) -> String? {
        // A provider the user removed from the slots cannot nag from the
        // footer — "Claude 数据过期" while only Grok+Cursor are selected
        // read as a bug, because it was one (owner report, 2026-08-08).
        let visibility = ProviderVisibilityStore.shared
        let claude = claudeFailed && visibility.claudeVisible
        let codex = codexFailed && visibility.codexVisible
        switch (claude, codex) {
        case (true, true): return L10n.tr("Usage refresh failed")
        case (true, false): return L10n.tr("Claude stale")
        case (false, true): return L10n.tr("Codex stale")
        case (false, false): return nil
        }
    }

    private static func loadCachedSnapshot() -> UsageCacheSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let snapshot = try? JSONDecoder().decode(UsageCacheSnapshot.self, from: data) else {
            return nil
        }
        return UsageCachePolicy.restoredSnapshot(snapshot, now: Date(), maxAge: cacheMaxAge)
    }

    private static func saveCachedSnapshot(claude: AppUsage,
                                           codex: AppUsage,
                                           fetchedClaude: Bool = true,
                                           fetchedCodex: Bool = true) {
        let existing = loadCachedSnapshot()
        guard let snapshot = UsageCachePolicy.snapshotForSave(
            claude: claude,
            codex: codex,
            existing: existing,
            now: Date(),
            fetchedClaude: fetchedClaude,
            fetchedCodex: fetchedCodex
        ), let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    /// Replace current usage values with hand-tuned percentages so the
    /// alert engine's pulse + tint behavior can be exercised without
    /// waiting for a real provider crossing. Auto-refresh continues — the
    /// next scheduled poll will overwrite these values with real data.
    /// Each call uses fresh `resetAt` timestamps so the alert engine
    /// treats it as a new reset window and re-evaluates crossings.
    func injectPreviewUsage(claudeFiveHour: Double, codexFiveHour: Double) {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 6 * 3600)
        self.claude = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: claudeFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.45,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: claude.plan ?? "max"
        )
        self.codex = AppUsage(
            fiveHour: WindowUsage(
                usedPercent: codexFiveHour,
                resetAt: fiveHourReset,
                error: nil
            ),
            weekly: WindowUsage(
                usedPercent: 0.30,
                resetAt: weeklyReset,
                error: nil
            ),
            plan: codex.plan ?? "pro"
        )
        self.lastUpdated = now
        self.refreshWarning = nil
    }

    /// Re-authenticate Claude via the in-app browser login.
    ///
    /// Preferred path (`ClaudeWebLogin`): opens the real Claude authorize page
    /// in the user's remembered browser target (`ClaudeLoginTargetStore` —
    /// default browser, a specific Chromium profile, an incognito window, or
    /// copy-the-link) so the sign-in lands where the claude.ai session
    /// actually lives, and catches the OAuth redirect on a local loopback
    /// listener, writing the fresh, fully-scoped token pair straight to the
    /// keychain. No Terminal, no manual code paste. Failures surface their
    /// reason under the Claude row and stop — no legacy CLI fallback.
    func reauthenticateClaude() {
        guard !claudeReauthInProgress else { return }
        claudeReauthInProgress = true
        claudeReauthFailureCaption = nil
        claudeReauthFollowupTask?.cancel()
        reauthPollTask?.cancel()
        // Always the system default browser. The profile/incognito picker
        // UI is gone (owner review, 2026-08-08 — the row must read like a
        // normal sign-in), and honoring a REMEMBERED incognito pick from
        // that era would keep opening ghost windows with no UI left that
        // explains why.
        let target = ClaudeLoginBrowserTarget.systemDefault
        reauthPollTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await ClaudeWebLogin.shared.start(target: target) { [weak self] url in
                Task { @MainActor in
                    self?.claudeLoginURL = url
                    // Copy-only: the link IS the flow — it goes straight to
                    // the pasteboard (which also stretches the timeout to
                    // manual-paste length).
                    if target == .copyOnly { self?.copyClaudeLoginLink() }
                }
            }
            await MainActor.run { self.claudeLoginURL = nil }
            switch outcome {
            case .success:
                await MainActor.run { self.claudeReauthFailureCaption = nil }
                await self.finishClaudeReauthWithSingleFetch()
            case .canceled:
                await MainActor.run { self.claudeReauthInProgress = false }
            case .failed(let reason):
                // Surface the reason and stop. The old path silently spawned
                // a Terminal running `claude auth login` — a retired CLI
                // command that errors on 2.x, which read as a mystery
                // "authentication failed" from nowhere (owner repro,
                // 2026-08-08).
                NSLog("AgentIsland: Claude web login failed — %@", reason)
                await MainActor.run {
                    self.claudeReauthInProgress = false
                    self.claudeReauthFailureCaption = reason
                }
            }
        }
    }

    /// Copies the in-flight authorize URL to the pasteboard for a manual
    /// paste into whichever browser/profile actually holds the user's
    /// claude.ai session, and stretches the login timeout to 10 minutes to
    /// cover the hop. Returns false when no login flow is running.
    @discardableResult
    func copyClaudeLoginLink() -> Bool {
        guard let url = claudeLoginURL else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        ClaudeWebLogin.shared.extendTimeoutForManualPaste()
        return true
    }

    /// Legacy fallback: spawn `claude auth login` in Terminal and poll the
    /// keychain metadata for a change, then hit the usage API once. Kept only
    /// as a safety net for setups where the loopback listener can't bind.
    private func runClaudeCLIReauthFallback() async {
        let initialStamp = ClaudeCredentials.keychainModificationStamp()
        guard ClaudeCredentials.spawnReauth() else {
            await MainActor.run { self.claudeReauthInProgress = false }
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            let currentStamp = ClaudeCredentials.keychainModificationStamp()
            guard currentStamp != nil, currentStamp != initialStamp else { continue }
            await finishClaudeReauthWithSingleFetch()
            return
        }
        await finishClaudeReauthWithSingleFetch()
    }

    func reauthenticateCodex() {
        guard !codexReauthInProgress else { return }
        let initialStamp = CodexCredentials.authModificationStamp()
        guard CodexCredentials.spawnReauth() else { return }
        codexReauthInProgress = true
        codexReauthPollTask?.cancel()
        codexReauthPollTask = Task { [weak self, initialStamp] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let currentStamp = CodexCredentials.authModificationStamp()
                guard currentStamp != nil, currentStamp != initialStamp else {
                    continue
                }
                await self?.finishCodexReauthWithSingleFetch()
                return
            }
            await self?.finishCodexReauthWithSingleFetch()
        }
    }

    private func finishCodexReauthWithSingleFetch() async {
        let c = await UsageFetcher.fetchCodex()
        await MainActor.run {
            let mergedCodex = UsageStore.mergedUsage(existing: self.codex, fetched: c)
            self.codex = mergedCodex
            UsageStore.saveCachedSnapshot(
                claude: self.claude,
                codex: mergedCodex,
                fetchedClaude: false,
                fetchedCodex: true
            )
            self.refreshWarning = (UsageStore.isErrorOnly(c) && ProviderVisibilityStore.shared.codexVisible) ? L10n.tr("Codex stale") : nil
            if !UsageStore.isErrorOnly(c) {
                self.lastUpdated = Date()
            }
            self.codexReauthInProgress = false
        }
    }

    private func finishClaudeReauthWithSingleFetch() async {
        let cl = await UsageFetcher.fetchClaude()
        await MainActor.run {
            let mergedClaude = UsageStore.mergedUsage(existing: self.claude, fetched: cl)
            self.claude = mergedClaude
            UsageStore.saveCachedSnapshot(
                claude: mergedClaude,
                codex: self.codex,
                fetchedClaude: true,
                fetchedCodex: false
            )
            self.refreshWarning = UsageStore.isErrorOnly(cl) ? L10n.tr("Claude stale") : nil
            if !UsageStore.isErrorOnly(cl) {
                self.lastUpdated = Date()
            }
            self.claudeReauthInProgress = false
            // #31: a failed single fetch right after re-auth used to strand
            // the error caption until the next 5–30 min poll corrected it.
            if UsageStore.isErrorOnly(cl) {
                self.scheduleClaudeReauthFollowups()
            }
        }
    }

    /// Two quick Claude-only follow-up pulls (15s after the reauth flow
    /// ends, then again at 60s) so a transiently failing post-login fetch
    /// self-heals while the fresh token settles, instead of waiting out a
    /// full poll interval. Stops at the first success; a new reauth cancels
    /// any pending follow-ups.
    private func scheduleClaudeReauthFollowups() {
        claudeReauthFollowupTask?.cancel()
        claudeReauthFollowupTask = Task { [weak self] in
            for delaySeconds in [15, 45] {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                let cl = await UsageFetcher.fetchClaude()
                if Task.isCancelled { return }
                let healed = await MainActor.run { () -> Bool in
                    let mergedClaude = UsageStore.mergedUsage(existing: self.claude, fetched: cl)
                    self.claude = mergedClaude
                    UsageStore.saveCachedSnapshot(
                        claude: mergedClaude,
                        codex: self.codex,
                        fetchedClaude: true,
                        fetchedCodex: false
                    )
                    if UsageStore.isErrorOnly(cl) { return false }
                    self.refreshWarning = nil
                    self.lastUpdated = Date()
                    return true
                }
                if healed { return }
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        armTimer()
        // Re-arm whenever the user changes the refresh interval. We
        // dropFirst() the initial @Published replay so we don't re-fire
        // refresh() on subscription.
        intervalCancellable = RefreshIntervalStore.shared.$seconds
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.armTimer() }
            }
        startNetworkMonitor()
        startWakeMonitor()
    }

    /// Macs sleep overnight — exactly when a quota window resets and an
    /// overnight run wants to auto-continue. A sleeping Mac's timers don't
    /// fire, so on wake the panel would sit on pre-sleep data (an expired
    /// countdown, the stale exhausted state) until the next poll, and the
    /// afterReset trigger would miss its window. Refresh immediately on wake
    /// so both recover the instant the machine is back.
    private func startWakeMonitor() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        // Locked but not slept: even with App Nap disabled the scheduled poll
        // may be up to `pollInterval` away when the screen unlocks. Refresh the
        // instant it unlocks so a reset that landed during the lock is picked
        // up (and its afterReset trigger caught up) without waiting.
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
        intervalCancellable?.cancel()
        intervalCancellable = nil
        netMonitor?.cancel()
        netMonitor = nil
        lastNetStatus = nil
    }

    private func armTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    /// Trigger an immediate refresh whenever the network transitions from
    /// unsatisfied to satisfied — closes the launch-at-login race where
    /// Wi-Fi is still associating when our first refresh fires. Without
    /// this, the panel sits at the empty cold-start state until the next
    /// scheduled poll (5–30 minutes away). The initial path callback fires
    /// with the current state and is deliberately ignored (lastNetStatus
    /// starts nil) — startAutoRefresh's own refresh() already covers
    /// cold-start, and acting on the initial callback would double-fire.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let prior = was, prior != .satisfied else { return }
                // Cancel any in-flight refresh — its URLSession call was
                // started on the dead path and is going to return an
                // error. Wait for it to finalize so its loading=false
                // lands before we start the replacement, otherwise our
                // refresh() hits the `if loading { return }` guard.
                self.refreshTask?.cancel()
                await self.refreshTask?.value
                self.refresh()
            }
        }
        monitor.start(queue: netQueue)
        netMonitor = monitor
    }
}
