import SwiftUI

/// Cost data row. Mirrors `UsageView`'s data-row shape so swipe transitions
/// between them don't reflow the panel. Chrome (provider titles, footer
/// chip + page dots + sync status) lives in `PanelHeader` / `PanelFooter`.
///
/// Renders the four-choose-two slot selection (owner call, 2026-08-08:
/// 计费/用量/一切都只是四选二), one rendering path for all five providers:
///   - two slots: two cost columns with a hairline divider (default).
///   - one slot:  the live column on its native flank (centered tiles),
///                hairline, then the provider badge filling the freed half.
///   - none:      a centered `BothHiddenPlaceholder`.
/// A slot with a local ledger shows real tiles; a slot with none (Gemini
/// today) shows the cold "no local cost data" state — never a fabricated $0.
struct CostView: View {
    @ObservedObject private var store = CostStore.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared

    var body: some View {
        let slots = visibility.slotProviders

        HStack(spacing: 0) {
            if slots.count == 2 {
                costColumn(slots[0], centered: false)
                hairline
                costColumn(slots[1], centered: false)
            } else if slots.count == 1 {
                let solo = slots[0]
                if solo.soloLogoFlankIsLeading {
                    costColumn(solo, centered: true)
                    hairline
                    soloBadge(solo)
                } else {
                    soloBadge(solo)
                    hairline
                    costColumn(solo, centered: true)
                }
            } else {
                BothHiddenPlaceholder()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// A provider's cost column: real tiles when it has a local ledger,
    /// otherwise the cold "no local cost data" state. Cursor keeps tiles as
    /// long as it moved any tokens — CostTile renders its dollar figure as
    /// "—" (no model → no price) rather than 0 — while a Cursor install that
    /// never logged a priced bubble degrades to cold, same as Gemini which
    /// has no local ledger at all.
    @ViewBuilder
    private func costColumn(_ provider: DisplayProvider, centered: Bool) -> some View {
        let cost = store.cost(for: provider)
        if hasLedger(cost) {
            CostBlock(color: provider.brandColor, cost: cost,
                      loading: store.isLoading(provider),
                      provider: tokenProvider(provider),
                      centerWhenSingle: centered)
        } else {
            ColdCostColumn(provider: provider)
                .transition(breakdownTransition)
        }
    }

    /// Fills the freed half in the solo layout with the provider's identity.
    /// `SoloProviderBadge` already covers all five marks/accents, so the
    /// guest split UsageView still carries isn't needed here.
    private func soloBadge(_ provider: DisplayProvider) -> some View {
        SoloProviderBadge(provider: provider.alertProvider)
            .padding(.horizontal, 12)
            .transition(breakdownTransition)
    }

    /// A provider carries a local ledger when any token or dollar figure
    /// crossed the wire. Kept token-inclusive so Cursor (tokens, no price)
    /// still gets tiles, while a provider with nothing at all falls to the
    /// cold state instead of a fabricated $0.
    private func hasLedger(_ cost: ProviderCost) -> Bool {
        cost.today.tokens > 0 || cost.month.tokens > 0
            || cost.today.dollars > 0 || cost.month.dollars > 0
            || cost.dailyTokens.contains { $0.tokens > 0 }
    }

    /// Bridge DisplayProvider → the cost pipeline's own provider enum. That
    /// enum has no raw value (it predates the shared DisplayProvider), so the
    /// hop is an explicit mirror rather than a rawValue init.
    private func tokenProvider(_ provider: DisplayProvider) -> TokenEvent.Provider {
        switch provider {
        case .claude: return .claude
        case .codex:  return .codex
        case .antigravity: return .antigravity
        case .grok:   return .grok
        case .cursor: return .cursor
        }
    }

    /// Mirror of `UsageView.breakdownTransition` — kept inline (not extracted
    /// to a shared helper) because it's two views and the transition's
    /// emotional purpose is "this half has been repurposed for the badge",
    /// which is a per-page editorial choice.
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

/// Shown for a slot provider with no local cost ledger — Gemini (no token
/// file exists on disk) or a Cursor install that never logged a priced
/// bubble. Names the provider and says why, never a fabricated $0: cost the
/// app cannot compute reads as absent, not zero (repo honesty rule).
private struct ColdCostColumn: View {
    let provider: DisplayProvider

    var body: some View {
        VStack(spacing: 8) {
            ProviderMark(provider: provider, size: 26,
                         tint: provider.brandColor.opacity(0.8))
            Text(provider.displayName)
                .font(Typography.providerTitle)
                .foregroundStyle(.white.opacity(0.55))
            Text(L10n.tr("No local cost data"))
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("%@: no local cost data", provider.displayName))
    }
}
