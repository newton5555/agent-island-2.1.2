import SwiftUI

/// Banked Codex resets, drawn as a tiny UPRIGHT card — portrait like a card
/// you hold, faced in the Codex logo blue, with the OpenAI mark
/// printed on it and "×N" beside it. No container box around the pair.
/// Clicking it opens the detail popover: each card + how long it stays
/// valid. Always visible, ×0 included (the face dims when empty).
struct ResetCardChip: View {
    let count: Int
    let cards: [ResetCard]

    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                cardFace
                Text("×\(count)")
                    .font(Typography.chip)
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(count > 0 ? 0.78 : 0.42))
            }
        }
        .buttonStyle(.plain)
        .help(L10n.tr("%d banked resets available", count))
        .accessibilityLabel(L10n.tr("%d banked resets available", count))
        .onReceive(NotificationCenter.default.publisher(for: .islandDemoCommand)) { note in
            // Recording rig: scripted popover open/close.
            guard let cmd = note.userInfo?["cmd"] as? String else { return }
            if cmd == "resetcards:open" { showingDetails = true }
            if cmd == "resetcards:close" { showingDetails = false }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            detailsPopover
        }
    }

    /// Portrait card face in the Codex blue: deep blue gradient, a diagonal
    /// sheen sweep, a top catchlight edge, and a drop shadow — reads as an
    /// object, not a badge.
    private var cardFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            IslandColor.codex.opacity(count > 0 ? 0.95 : 0.30),
                            IslandColor.codex.opacity(count > 0 ? 0.45 : 0.14),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            // Diagonal sheen — the "printed plastic" catch.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(count > 0 ? 0.34 : 0.12), location: 0.0),
                            .init(color: .white.opacity(0.0), location: 0.45),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), IslandColor.codex.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
            if let logo = ProviderLogos.openAI {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 9)
                    .foregroundStyle(Color(red: 0.03, green: 0.10, blue: 0.20).opacity(count > 0 ? 0.9 : 0.5))
            }
        }
        .frame(width: 13.5, height: 19)
        .shadow(color: .black.opacity(0.5), radius: 1.8, y: 1.1)
        .shadow(color: IslandColor.codex.opacity(count > 0 ? 0.35 : 0), radius: 5, y: 0)
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("%d banked resets available", count))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            if cards.isEmpty {
                Text(count > 0
                     ? L10n.tr("Details unavailable right now.")
                     : L10n.tr("Earned resets appear here with their expiry."))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(cards) { card in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(IslandColor.codex)
                            .frame(width: 5, height: 5)
                        Text(card.title)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer(minLength: 14)
                        Text(expiryText(card))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 210, alignment: .leading)
    }

    private func expiryText(_ card: ResetCard) -> String {
        guard let expires = card.expiresAt else { return "—" }
        let remaining = expires.timeIntervalSinceNow
        guard remaining > 0 else { return L10n.tr("expired") }
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("Md")
        return L10n.tr("valid %@ · %@", Duration.compact(remaining), df.string(from: expires))
    }
}
