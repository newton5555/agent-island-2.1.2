import SwiftUI
import AppKit

/// Usage data row. The chrome (provider titles, footer chip + page dots +
/// sync status) lives in `PanelHeader` / `PanelFooter` so it stays fixed
/// while this row swipes between usage and cost screens.
///
/// Branches on `(claudeOn, codexOn)` from `ProviderVisibilityStore`:
///   - both on:  two `ChartsBlock`s with a hairline divider (default).
///   - one on:   the live block on its native side, hairline, then the
///               provider badge filling the freed half.
///   - both off: a centered `BothHiddenPlaceholder`.
struct UsageView: View {
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var pref = StylePref.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared

    private var style: ChartStyle { pref.style }

    @ObservedObject private var antigravityStore = AntigravityUsageStore.shared
    @ObservedObject private var grokStore = GrokUsageStore.shared
    @ObservedObject private var cursorStore = CursorUsageStore.shared

    var body: some View {
        // Whoever holds a slot gets a REAL tile column — five providers,
        // one rendering path. The old design gave guests a skinny bottom
        // strip, which left the whole main area an empty void the moment a
        // guests-only pair was selected (owner screenshot, 2026-08-08).
        let slots = visibility.slotProviders

        HStack(spacing: 0) {
            if slots.count == 2 {
                providerBlock(slots[0], seed: 1)
                hairline
                providerBlock(slots[1], seed: 3)
            } else if slots.count == 1 {
                let solo = slots[0]
                if solo.soloLogoFlankIsLeading {
                    providerBlock(solo, seed: 1)
                    hairline
                    soloBadge(solo)
                } else {
                    soloBadge(solo)
                    hairline
                    providerBlock(solo, seed: 3)
                }
            } else {
                BothHiddenPlaceholder()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func providerBlock(_ provider: DisplayProvider, seed: Int) -> some View {
        switch provider {
        case .claude:
            ChartsBlock(color: IslandColor.claude, usage: store.claude,
                        showsClaudeReauth: true, style: style, seed: seed)
        case .codex:
            ChartsBlock(color: IslandColor.codex, usage: store.codex,
                        style: style, seed: seed)
        case .antigravity, .grok, .cursor:
            ChartsBlock(color: provider.brandColor, usage: guestUsage(provider),
                        style: style, seed: seed)
        }
    }

    @ViewBuilder
    private func soloBadge(_ provider: DisplayProvider) -> some View {
        Group {
            switch provider {
            case .claude: SoloProviderBadge(provider: .claude)
            case .codex: SoloProviderBadge(provider: .codex)
            case .antigravity, .grok, .cursor:
                VStack(spacing: 8) {
                    ProviderMark(provider: provider, size: 30, tint: provider.brandColor.opacity(0.85))
                    Text(provider.displayName)
                        .font(Typography.providerTitle)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .transition(breakdownTransition)
    }

    /// Guests ride the same tile machinery as Claude/Codex by synthesizing
    /// an AppUsage: their single pool is the primary window, and a "no
    /// data" secondary marks them single-window (same mechanism Codex's
    /// weekly-only world uses).
    private func guestUsage(_ provider: DisplayProvider) -> AppUsage {
        let missing = WindowUsage(usedPercent: 0, resetAt: nil, error: "no data", periodSeconds: nil)
        switch provider {
        case .antigravity:
            // Gemini pool only, one wide tile — the 3p (Claude/GPT) pool is
            // real but belongs to other providers' tiles (owner call,
            // 2026-08-09). Weekly window, not the 24h this once hardcoded.
            let pool = antigravityStore.snapshot?.primary
            return AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: pool?.usedPercent ?? 0,
                    resetAt: pool?.resetAt,
                    error: antigravityStore.statusCaption,
                    periodSeconds: pool?.periodSeconds ?? AntigravityQuotaBucket.weekSeconds
                ),
                weekly: missing,
                plan: antigravityStore.tierBadge?.lowercased()
            )
        case .grok:
            let snapshot = grokStore.snapshot
            return AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: snapshot?.weeklyUsedPercent ?? 0,
                    resetAt: snapshot?.weeklyPeriodEnd,
                    error: grokStore.errorCaption,
                    periodSeconds: 7 * 24 * 60 * 60
                ),
                weekly: missing,
                plan: grokStore.authModeBadge?.lowercased()
            )
        case .cursor:
            let snapshot = cursorStore.snapshot
            return AppUsage(
                fiveHour: WindowUsage(
                    usedPercent: snapshot?.usedPercent ?? 0,
                    resetAt: snapshot?.periodEnd,
                    error: cursorStore.errorCaption,
                    periodSeconds: 30 * 24 * 60 * 60
                ),
                weekly: missing,
                plan: cursorStore.planBadge?.lowercased()
            )
        case .claude, .codex:
            return .empty
        }
    }

    /// Slight scale + opacity gives the badge half a sense of "expanding
    /// into the freed space" rather than a hard crossfade. Same curve the
    /// chart-style swap uses; reads as a single morph paired with the
    /// `withAnimation(.openMorph)` on the Settings toggle.
    private var breakdownTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97))
    }

    private var hairline: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

struct ChartsBlock: View {
    let color: Color
    let usage: AppUsage
    var showsClaudeReauth = false
    let style: ChartStyle
    let seed: Int

    /// Keep a manual Claude auth escape hatch available whenever the Claude
    /// usage fetch is unhealthy. `rate limited` is not fixed by re-login, but
    /// users still need a visible path for repairing stale/invalid OAuth state
    /// instead of being stranded with a caption.
    private var shouldOfferClaudeReauth: Bool {
        guard showsClaudeReauth, ClaudeCredentials.canPromptReauth() else { return false }
        return usage.fiveHour.error != nil || usage.weekly.error != nil
    }

    /// Speak the window the provider actually meters: 5h, weekly, a daily
    /// bucket (Gemini), or a billing cycle (Cursor).
    static func windowLabelKey(_ window: WindowUsage) -> String {
        guard window.isLongPeriod else { return "5h" }
        guard let period = window.periodSeconds else { return "week" }
        if period >= 20 * 86400 { return "30d" }
        if period <= 2 * 86400 { return "24h" }
        return "week"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                // Label the primary tile by the window length the provider
                // actually reports — Codex's primary became a weekly window
                // in July 2026, so it reads "week", not a hardcoded "5h".
                // A single-window provider's tile is `wide` and centers its
                // own content (see ChartTile's frame alignment).
                ChartTile(style: style, color: color,
                          labelKey: Self.windowLabelKey(usage.fiveHour),
                          window: usage.fiveHour, seed: seed,
                          wide: usage.secondaryMissing)
                // A provider that reports only one window gets one tile — no
                // permanent "no data" ghost for a window gone upstream.
                if !usage.secondaryMissing {
                    ChartTile(style: style, color: color, labelKey: "week",
                              window: usage.weekly, seed: seed + 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
        // The reauth escape hatch OVERLAYS the tile block instead of adding
        // a row — an appended row overflowed the fixed panel height and the
        // button clipped to "重新认…" (community report + owner report).
        .overlay(alignment: .bottom) {
            if shouldOfferClaudeReauth {
                ReauthButton().padding(.bottom, 2)
            }
        }
    }
}

/// Inline action shown below the Claude tiles when the keychain token is
/// missing the scope the usage endpoint now requires. Runs the in-app web
/// login (browser round-trip + loopback callback) — the chip recovers on
/// its own when the fresh token lands. While the flow is in flight a
/// companion link button copies the authorize URL for users whose Claude
/// session lives in a different browser profile than the system default;
/// the panel is too tight for the full sentence, so the guidance rides the
/// tooltips (Settings carries the visible caption).
struct ReauthButton: View {
    @ObservedObject private var store = UsageStore.shared
    @State private var hovered = false
    @State private var linkHovered = false
    @State private var linkCopied = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                store.reauthenticateClaude()
            } label: {
                Text(store.claudeReauthInProgress ? L10n.tr("waiting for login…") : L10n.tr("Re-authenticate"))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(hovered && !store.claudeReauthInProgress ? 0.95 : 0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(hovered && !store.claudeReauthInProgress ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(store.claudeReauthInProgress)
            .onHover { hovered = $0 }
            .help(L10n.tr("Opens the Claude sign-in page with your saved browser choice — change it in Settings → Providers"))

            if store.claudeReauthInProgress, store.claudeLoginURL != nil {
                Button {
                    guard store.copyClaudeLoginLink() else { return }
                    linkCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        linkCopied = false
                    }
                } label: {
                    Image(systemName: linkCopied ? "checkmark" : "link")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(linkHovered || linkCopied ? 0.95 : 0.72))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(linkHovered ? 0.08 : 0.04))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { linkHovered = $0 }
                .help(L10n.tr("Copy login link"))
                .accessibilityLabel(L10n.tr("Copy login link"))
            }
        }
    }
}

struct ChartTile: View {
    let style: ChartStyle
    let color: Color
    let labelKey: String
    let window: WindowUsage
    let seed: Int
    /// True when this tile spans the full row (single-window provider).
    var wide: Bool = false

    @ObservedObject private var quotaMode = QuotaDisplayModeStore.shared

    /// Locked tile height across all 5 styles so the panel size is
    /// identical regardless of what the user picks.
    private static let tileHeight: CGFloat = 96

    var body: some View {
        // 0-100; flips to "percent left" when the user prefers remaining.
        let value = quotaMode.displayValue(usedPercent: window.usedPercent)
        let sub = subCaption()
        let label = L10n.tr(labelKey)

        Group {
            switch style {
            case .ring:    RingChart(value: value, color: color, label: label, sub: sub, centered: wide)
            case .bar:     BarChart(value: value, color: color, label: label, sub: sub)
            case .stepped: SteppedChart(value: value, color: color, label: label, sub: sub)
            case .numeric: NumericChart(value: value, color: color, label: label, sub: compactSubCaption())
            }
        }
        .id(style)
        // Blur + scale + opacity, all on the same strong ease-out at 220ms.
        // The blur masks the geometric mismatch between Ring and Bar so the
        // crossfade reads as one morph instead of two stacked objects.
        .transition(.chartSwap.animation(.chartSwap))
        // A wide (single-window) tile centers its content in the freed
        // half — the tile expands to full width, so outer Spacers can't do
        // it; the alignment here is the only thing that can (owner report
        // ×2, 1.7.2: the lone Codex pie hugged the left of the red-boxed
        // half).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .top : .topLeading)
        .frame(height: Self.tileHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("%@, %d%%", label, Int(value)))
        .accessibilityValue(subCaption())
    }

    private func subCaption() -> String {
        // "no data" is our internal sentinel for "API returned null for this
        // window" — most commonly a brand-new 5h period before the first
        // OAuth call lands. Hide it so the tile reads as a passive
        // window-context cue (the "5h"/"week" header label communicates the
        // window type) instead of looking broken. Real errors surface before
        // reset countdowns because preserved stale values may carry an old
        // resetAt that would otherwise render as "0s".
        if let err = window.error, err != "no data" {
            // Suppress the scope-insufficient text when the inline re-auth
            // button is going to appear below the tiles — otherwise the same
            // remediation hint reads twice (caption + button label). Users
            // without a discoverable `claude` binary still get the raw text
            // so they know the manual fix.
            if ClaudeCredentials.isAuthRecoverableError(err),
               ClaudeCredentials.canPromptReauth() {
                return ""
            }
            // Known error sentinels have Localizable entries; unknown
            // strings fall through L10n.tr unchanged.
            return L10n.tr(err)
        }
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            return L10n.tr("resets in %@", Duration.compact(delta))
        }
        return ""
    }

    private func compactSubCaption() -> String {
        if let err = window.error, err != "no data" {
            if ClaudeCredentials.isAuthRecoverableError(err),
               ClaudeCredentials.canPromptReauth() {
                return ""
            }
            return L10n.tr(err)
        }
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            // Words, not glyphs (owner call, 1.7.2): "↻ 12m" read as
            // terminal shorthand; "12m 后重置" reads as product copy.
            return String(format: L10n.tr("resets in %@"), Duration.compact(delta))
        }
        return ""
    }
}
