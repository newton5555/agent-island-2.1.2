import Combine
import Foundation

/// Fires a distinct full-screen alarm (and a system notification) the moment a
/// provider's 5-hour or weekly window hits 100% — the "you're out of quota
/// until <time>" popup, separate from the thread-finished "it's your turn"
/// alarm. Lets the alarm mean something actionable instead of conflating a
/// finished turn with a hard rate-limit block.
///
/// Mirrors `AlertEngine`'s crossing pattern: it warms up on the first real
/// usage sample (so launching into an already-exhausted window doesn't alarm)
/// and fires once per reset cycle per (provider, window).
///
/// Re-arming is keyed on the reset boundary *advancing to a new cycle*, not on
/// its exact value. Anthropic's rolling 5-hour `reset_at` drifts by seconds to
/// minutes on every poll while a window sits exhausted, so an exact-timestamp
/// dedup (what 1.5.6 shipped) churned its key every 5-minute refresh and
/// re-fired the same "out of quota" alarm over and over. We now track the
/// latest boundary we've accounted for and only re-alarm when the boundary
/// jumps past it by more than `reArmMargin` — real resets leap hours (5-hour)
/// or days (weekly); jitter never does.
@MainActor
final class UsageExhaustionAlarm {
    static let shared = UsageExhaustionAlarm()

    /// windowId ("provider-window") → the most recent reset boundary we've
    /// accounted for. Presence means "already alarmed for this cycle".
    private var alarmedResetAt: [String: Date] = [:]
    /// A boundary must advance by more than this to count as a new cycle.
    /// Comfortably larger than any observed reset_at jitter, comfortably
    /// smaller than the smallest real reset span (the 5-hour window).
    private static let reArmMargin: TimeInterval = 30 * 60
    private var warmedUp = false
    private var subs: Set<AnyCancellable> = []

    private init() {}

    func start() {
        let triggers: [AnyPublisher<Void, Never>] = [
            UsageStore.shared.$claude.map { _ in () }.eraseToAnyPublisher(),
            UsageStore.shared.$codex.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in Task { @MainActor in self?.recompute() } }
            .store(in: &subs)
        recompute()
    }

    private struct WindowRef {
        let provider: AlertEngine.Provider
        let window: QuotaWindowKind
        let usage: WindowUsage
    }

    private func currentWindows() -> [WindowRef] {
        let usage = UsageStore.shared
        // Codex dropped its 5-hour window for a single weekly quota (July
        // 2026), and a full-screen "you're out for the week" panel is noise,
        // not an actionable interruption — so Codex no longer raises the
        // quota alarm at all (product call, 2026-07-13; macOS only for now).
        // Codex quota still shows in the tiles and still drives the pace/
        // threshold warnings; Claude keeps the alarm (its 5h window lives).
        let all = [
            WindowRef(provider: .claude, window: .fiveHour, usage: usage.claude.fiveHour),
            WindowRef(provider: .claude, window: .weekly, usage: usage.claude.weekly),
        ]
        // Providers switched off in Settings never alarm — same contract as
        // the island's red attention glow.
        return all.filter { ProviderVisibilityStore.shared.effectiveVisible(provider: $0.provider) }
    }

    private func windowId(_ provider: AlertEngine.Provider, _ window: QuotaWindowKind) -> String {
        "\(provider.rawValue)-\(window.rawValue)"
    }

    /// A window is fire-worthy when we've never alarmed it, or its reset
    /// boundary has jumped to a new cycle (past the last one by > margin).
    private func isNewCycle(_ provider: AlertEngine.Provider, _ window: QuotaWindowKind, _ resetAt: Date) -> Bool {
        guard let prev = alarmedResetAt[windowId(provider, window)] else { return true }
        return resetAt > prev + Self.reArmMargin
    }

    /// Record the boundary we've now accounted for, monotonically — so a
    /// reset_at that drifts earlier can't lower the bar and let jitter re-fire.
    private func accountFor(_ provider: AlertEngine.Provider, _ window: QuotaWindowKind, _ resetAt: Date) {
        let id = windowId(provider, window)
        alarmedResetAt[id] = max(alarmedResetAt[id] ?? resetAt, resetAt)
    }

    private func isExhausted(_ ref: WindowRef) -> Bool {
        ref.usage.error == nil && ref.usage.usedPercent >= 0.999
    }

    private func recompute() {
        // Never act in demo/preview — synthetic usage jumps around every tick.
        guard AppEnvironment.current == .normal else { return }
        // Only once real data has flowed (matches AlertEngine's gate), so a
        // cached/zeroed launch snapshot can't fire anything.
        guard UsageStore.shared.lastUpdated != nil else { return }

        let windows = currentWindows()

        // Warmup: on the first real sample, mark anything already exhausted as
        // already-alarmed so we don't pop for a state that predates launch.
        if !warmedUp {
            for ref in windows where isExhausted(ref) {
                if let reset = ref.usage.resetAt { accountFor(ref.provider, ref.window, reset) }
            }
            warmedUp = true
            return
        }

        // Respect the master alarm switch — if the user turned off turn alarms,
        // don't surprise them with a quota alarm either.
        guard AgentReminderStore.shared.enabled else { return }
        // Dedicated opt-out: some people only want auto-resume.
        guard QuotaAlarmStore.shared.enabled else { return }

        // One alarm per provider per pass. Claude exposes both a 5-hour and a
        // weekly window; when both cross 100% in the same refresh they used to
        // fire two separate full-screen panels (they queue back-to-back, so it
        // reads as "it keeps popping"). Collapse to a single alarm for the
        // binding window — the one with the latest reset, i.e. the time you're
        // actually blocked until.
        let exhausted = windows.filter { isExhausted($0) && $0.usage.resetAt != nil }
        for provider in Set(exhausted.map(\.provider)) {
            let group = exhausted.filter { $0.provider == provider }
            // Fire only if some window in this provider's group has entered a
            // new reset cycle. Check BEFORE recording, then record every group
            // boundary so a jittering reset_at (or a window flapping just
            // under/over 100% within one cycle) can never re-fire.
            let hasNewCycle = group.contains { isNewCycle($0.provider, $0.window, $0.usage.resetAt!) }
            for ref in group { accountFor(ref.provider, ref.window, ref.usage.resetAt!) }
            guard hasNewCycle else { continue }
            if let binding = group.max(by: { ($0.usage.resetAt ?? .distantPast) < ($1.usage.resetAt ?? .distantPast) }),
               let reset = binding.usage.resetAt {
                fire(binding, resetAt: reset)
            }
        }
    }

    private func fire(_ ref: WindowRef, resetAt: Date) {
        // The full-screen panel IS the notification — it's screen-saver level
        // and joins all Spaces, so it surfaces over fullscreen work on any
        // display. Posting a Notification Center banner alongside it just
        // showed the same thing twice (half of the "2-3 popups" report).
        //
        // Name the window by its REAL period, not its slot: Codex's primary
        // slot has held a weekly window since July 2026, and an alarm that
        // says "5-hour limit reached" for a week-long block would be a lie.
        let window: QuotaWindowKind = ref.usage.isLongPeriod ? .weekly : ref.window
        TurnAlarmWindowController.shared.show(
            provider: ref.provider,
            thread: nil,
            kind: .quotaExhausted(window: window, resetAt: resetAt)
        )
    }

}
