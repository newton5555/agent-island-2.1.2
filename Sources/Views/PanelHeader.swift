import SwiftUI

/// Provider titles row — Claude on the left, Codex on the right, with a
/// notch-width spacer in the middle that hides the title content behind
/// the physical notch. Lives outside `PagedContent` so it stays fixed
/// while the data area swipes between usage/cost/overview screens.
///
/// Plan tags ("MAX" / "PLUS") are sourced from `UsageStore` since the
/// subscription tier is a property of the account, not the current page.
struct PanelHeader: View {
    let notch: NotchInfo
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared

    var body: some View {
        // Titles follow the slots — whichever two providers are selected
        // get named, not a hardcoded Claude/Codex pair.
        let slots = visibility.slotProviders
        let left: DisplayProvider? = slots.count == 2
            ? slots[0]
            : slots.first(where: { $0.soloLogoFlankIsLeading })
        let right: DisplayProvider? = slots.count == 2
            ? slots[1]
            : slots.first(where: { !$0.soloLogoFlankIsLeading })

        HStack(spacing: 0) {
            Group {
                if let left {
                    providerTitle(name: left.displayName, tag: planTag(left),
                                  color: left.brandColor, alignment: .leading)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: notch.width)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // Banked-reset count ("reset cards") — Codex-only, hidden at
                // zero (a "×0" chip read as a bug — owner report).
                if right == .codex || left == .codex,
                   let resetCards = usageStore.codex.resetCards, resetCards > 0 {
                    ResetCardChip(count: resetCards,
                                  cards: usageStore.codex.resetCardDetails ?? [])
                        .padding(.trailing, 10)
                }
                if let right {
                    providerTitle(name: right.displayName, tag: planTag(right),
                                  color: right.brandColor, alignment: .trailing)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.openMorph, value: slots)
        .frame(height: 22)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, min(14, max(0, notch.height - 22 - 4)))
    }

    private func planTag(_ provider: DisplayProvider) -> String? {
        switch provider {
        case .claude: return usageStore.claude.plan?.uppercased()
        case .codex:  return usageStore.codex.plan?.uppercased()
        case .antigravity: return AntigravityUsageStore.shared.tierBadge
        case .grok:   return GrokUsageStore.shared.authModeBadge
        case .cursor: return CursorUsageStore.shared.planBadge
        }
    }

    @ViewBuilder
    private func providerTitle(
        name: String,
        tag: String?,
        color: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        // Push past where the overlay logo lands: 9 leading + 20 logo + 8 gap.
        let logoOffset: CGFloat = 9 + 20 + 8

        let content = HStack(spacing: 8) {
            Text(name)
                .font(Typography.providerTitle)
                .foregroundStyle(.white)
            if let tag {
                Text(tag)
                    .font(Typography.chip)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
            }
        }

        if alignment == .leading {
            HStack {
                content.padding(.leading, logoOffset)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Spacer(minLength: 0)
                content.padding(.trailing, logoOffset)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
