import SwiftUI
import AppKit

/// Fills the half of the panel freed when only one provider is subscribed:
/// the provider's mark and name — one quiet identity moment, numbers on the
/// other side (owner's solo-layout call, 2026-07-16). Replaces the inherited
/// per-model breakdown table, whose "5h" legend read as a quota window Codex
/// no longer has.
struct SoloProviderBadge: View {
    let provider: AlertEngine.Provider

    private static let claudeImage = Bundle.main.url(forResource: "claude_logo", withExtension: "pdf")
        .flatMap { NSImage(contentsOf: $0) }
    private static let codexImage = Bundle.main.url(forResource: "openai_logo", withExtension: "pdf")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        // Bare mark, no chip behind it (owner's call, 2026-07-16: the ring
        // and fill read as clutter). Biased above center so the block sits
        // on the same visual line as the tiles across the hairline.
        VStack(spacing: 12) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(provider.logoRendering)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(color.opacity(0.95))
                    .frame(width: 30, height: 30)
                    .shadow(color: color.opacity(0.30), radius: 10)
            }
            Text(name)
                .font(Typography.providerTitle)
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }

    private var color: Color {
        provider.accent
    }

    private var name: String {
        provider.displayName
    }

    private var image: NSImage? {
        switch provider {
        case .claude: return Self.claudeImage
        case .codex: return Self.codexImage
        case .antigravity: return ProviderLogos.antigravity
        case .grok: return ProviderLogos.grok
        case .cursor: return ProviderLogos.cursor
        }
    }
}

/// Shown on usage and cost pages when the user has toggled both providers
/// off in Settings. Reads as "intentionally quiet" rather than "broken
/// page", and points the user back at the affordance that got them here.
struct BothHiddenPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(L10n.tr("Both providers hidden"))
                .font(Typography.providerTitle)
                .foregroundStyle(.white.opacity(0.45))
            Text(L10n.tr("Re-enable in Settings → Providers"))
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.32))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
