import SwiftUI
import AppKit

/// The matchup a report period resolves to. v3's duel was Claude-vs-Codex; the
/// five-provider generalization stages the TOP-2 providers by token volume,
/// falls back to a solo treatment when only one ran, and to a neutral empty
/// state when nothing did. Provider identity (name, color, mark) is read from
/// `DisplayProvider` for BOTH sides — never hardcoded.
enum ReportMatchup: Equatable {
    /// Two providers ran; `left`/`right` are in canonical slot order so the
    /// card never flips between periods, `leftShare` is left's token share of
    /// the pair (0...1). The winner is simply the larger side.
    case duel(left: DisplayProvider, right: DisplayProvider, leftShare: Double)
    /// A single provider carried the whole period — no opponent to imply.
    case solo(DisplayProvider)
    /// No provider had token activity in the period.
    case none

    /// Resolve per-provider token totals into a matchup: the two largest face
    /// off (canonical order fixes left/right placement, so the beam doesn't
    /// swap ends when the lead changes), a lone provider gets the solo
    /// treatment, an empty period the neutral state.
    static func from(totals: [DisplayProvider: Int]) -> ReportMatchup {
        let ranked = totals
            .filter { $0.value > 0 }
            .sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key.slotOrder < b.key.slotOrder
            }
        switch ranked.count {
        case 0: return .none
        case 1: return .solo(ranked[0].key)
        default:
            let pair = ranked.prefix(2).map { $0.key }.sorted { $0.slotOrder < $1.slotOrder }
            let left = pair[0], right = pair[1]
            let l = Double(totals[left] ?? 0), r = Double(totals[right] ?? 0)
            return .duel(left: left, right: right, leftShare: (l + r) > 0 ? l / (l + r) : 0.5)
        }
    }
}

/// The report cards' faction duel — v3's signature block (locked 2026-07-17),
/// generalized to five providers. Official provider marks anchor the two ends
/// of a split beam; the clash spark sits exactly at the usage-share split. The
/// chibi duel artwork is a Claude/Codex asset, so it only appears when the
/// TOP-2 pair is exactly {Claude, Codex} — every other pairing (and the solo /
/// empty states) renders the generic beam, which is fully provider-driven.
struct ReportDuel: View {
    let matchup: ReportMatchup

    private static func duelArt(claudeShare: Double) -> NSImage? {
        let name: String
        if claudeShare >= 0.52 { name = "duel-claude-wins" }
        else if claudeShare <= 0.48 { name = "duel-codex-wins" }
        else { name = "duel-draw" }
        return Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    private static let artHeight: CGFloat = 82
    private static let markSide: CGFloat = 18
    private static let markGap: CGFloat = 10
    private static let beamHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch matchup {
            case .duel(let left, let right, let leftShare):
                duelBody(left: left, right: right, leftShare: leftShare)
            case .solo(let provider):
                soloBody(provider)
            case .none:
                emptyBody
            }
        }
    }

    @ViewBuilder
    private func duelBody(left: DisplayProvider, right: DisplayProvider, leftShare: Double) -> some View {
        let leftColor = left.brandColor
        let rightColor = right.brandColor
        // The chibi artwork depicts Claude vs Codex specifically; only stage it
        // when the pair matches (canonical order guarantees claude=left).
        let showsChibi = left == .claude && right == .codex

        GeometryReader { geo in
            let beamX0 = Self.markSide + Self.markGap
            let beamW = max(1, geo.size.width - 2 * (Self.markSide + Self.markGap))
            let share = CGFloat(min(1, max(0, leftShare)))
            // The spark rides the TRUE split; only the artwork clamps inward so
            // a 90/10 blowout doesn't shove it off the card.
            let sparkX = beamX0 + beamW * min(0.97, max(0.03, share))
            let artX = beamX0 + beamW * min(0.74, max(0.26, share))
            let beamY = Self.artHeight + 10

            ZStack(alignment: .topLeading) {
                if showsChibi, let art = Self.duelArt(claudeShare: leftShare) {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: Self.artHeight)
                        .position(x: artX, y: Self.artHeight / 2 + 1)
                }

                ProviderMark(provider: left, size: Self.markSide, tint: leftColor)
                    .position(x: Self.markSide / 2, y: beamY)
                ProviderMark(provider: right, size: Self.markSide, tint: rightColor)
                    .position(x: geo.size.width - Self.markSide / 2, y: beamY)

                HStack(spacing: 1.5) {
                    Capsule()
                        .fill(Self.beamGradient(for: left, leading: true))
                        .frame(width: max(3, beamW * share))
                    Capsule()
                        .fill(Self.beamGradient(for: right, leading: false))
                }
                .frame(width: beamW, height: Self.beamHeight)
                .position(x: beamX0 + beamW / 2, y: beamY)

                clashSpark(left: leftColor, right: rightColor)
                    .position(x: sparkX, y: beamY)
            }
        }
        .frame(height: Self.artHeight + 20)

        HStack {
            legendTag(name: left.displayName, pct: leftShare, color: leftColor)
            Spacer()
            legendTag(name: right.displayName, pct: 1 - leftShare, color: rightColor)
        }
    }

    /// Solo layout: one champion mark centered above a full-width podium beam in
    /// the provider's color. No opponent mark, no clash spark — the period had a
    /// single provider and the card must not imply otherwise.
    @ViewBuilder
    private func soloBody(_ provider: DisplayProvider) -> some View {
        let color = provider.brandColor

        GeometryReader { geo in
            let beamX0 = Self.markSide + Self.markGap
            let beamW = max(1, geo.size.width - 2 * (Self.markSide + Self.markGap))
            let beamY = Self.artHeight + 10

            ZStack(alignment: .topLeading) {
                ProviderMark(provider: provider, size: 34, tint: color)
                    .position(x: geo.size.width / 2, y: Self.artHeight / 2 + 1)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: beamW, height: Self.beamHeight)
                    .position(x: beamX0 + beamW / 2, y: beamY)
            }
        }
        .frame(height: Self.artHeight + 20)

        HStack {
            legendTag(name: provider.displayName, pct: 1, color: color)
            Spacer()
        }
    }

    /// Neutral state for a period with no token activity — a dim beam and a
    /// caption, sized to match the duel/solo height so the card never reflows.
    @ViewBuilder
    private var emptyBody: some View {
        GeometryReader { geo in
            let beamX0 = Self.markSide + Self.markGap
            let beamW = max(1, geo.size.width - 2 * (Self.markSide + Self.markGap))
            let beamY = Self.artHeight + 10

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(0.06))
                    .frame(width: beamW, height: Self.beamHeight)
                    .position(x: beamX0 + beamW / 2, y: beamY)
                Text(L10n.tr("No activity this period"))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: geo.size.width / 2, y: Self.artHeight / 2 + 1)
            }
        }
        .frame(height: Self.artHeight + 20)

        // Invisible legend line keeps the block's height equal to the other
        // states, so paging between an empty and a busy period doesn't jump.
        legendTag(name: " ", pct: 0, color: .clear).opacity(0)
    }

    /// Beam fill for one side. Preserves the locked 2026-07-17 Claude/Codex
    /// gradient exactly; every other provider gets a subtle same-hue fade so the
    /// beam reads as brand-colored without a bespoke palette per provider.
    private static func beamGradient(for provider: DisplayProvider, leading: Bool) -> LinearGradient {
        let base = provider.brandColor
        let pair: [Color]
        switch provider {
        case .claude: pair = [Color(red: 0.88, green: 0.54, blue: 0.39), base]
        case .codex:  pair = [base, Color(red: 0.50, green: 0.74, blue: 0.96)]
        default:      pair = leading ? [base.opacity(0.7), base] : [base, base.opacity(0.7)]
        }
        return LinearGradient(colors: pair, startPoint: .leading, endPoint: .trailing)
    }

    /// White core + four-point star, warm glow to the leading side and cool to
    /// the trailing side — the "swords meet here" moment, colored by whichever
    /// two providers are dueling.
    private func clashSpark(left: Color, right: Color) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 1.6, height: 17)
                    .rotationEffect(.degrees(Double(i) * 90 + 14))
            }
            .shadow(color: .white.opacity(0.9), radius: 2.5)
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
                .shadow(color: .white.opacity(0.95), radius: 5)
                .shadow(color: left.opacity(0.8), radius: 7, x: -5)
                .shadow(color: right.opacity(0.8), radius: 7, x: 5)
        }
    }

    private func legendTag(name: String, pct: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text("\(Int((pct * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
