import AppKit
import SwiftUI

struct TurnAlarmProviderMark: View {
    let provider: AlertEngine.Provider
    let providerColor: Color

    @State private var glowPulse = false
    @State private var ringPulse = false
    @State private var haloSpin = false

    /// Antigravity's halo sweeps all four Google hues; every other provider
    /// gets the same shape in its single colour.
    private var isMulticolor: Bool { provider == .antigravity }

    var body: some View {
        ZStack {
            halo
                .frame(width: 138, height: 138)
                .blur(radius: glowPulse ? 28 : 18)
                .scaleEffect(glowPulse ? 1.12 : 0.92)

            Circle()
                .stroke(ringStyle(opacity: glowPulse ? 0.10 : 0.28), lineWidth: 1)
                .frame(width: 124, height: 124)
                .scaleEffect(glowPulse ? 1.16 : 0.82)
                .opacity(glowPulse ? 0.32 : 0.90)

            Circle()
                .stroke(ringStyle(opacity: glowPulse ? 0.30 : 0.14), lineWidth: 0.75)
                .frame(width: 92, height: 92)
                .scaleEffect(glowPulse ? 0.96 : 1.08)

            providerLogo
                .frame(width: 76, height: 76)
                .scaleEffect(ringPulse ? 1.025 : 0.985)
                .shadow(color: providerColor.opacity(glowPulse ? 0.86 : 0.48), radius: glowPulse ? 30 : 18)
        }
        .frame(width: 148, height: 126)
        .onAppear(perform: startAnimations)
    }

    /// The colour wheel is built once and turned with `rotationEffect`, a GPU
    /// transform. Animating the *stops* instead would re-rasterize the
    /// gradient every frame — the same mistake that once made the island's
    /// conic glow a per-frame CPU recolor (1.5.7 postmortem).
    @ViewBuilder
    private var halo: some View {
        if isMulticolor {
            Circle()
                .fill(
                    AngularGradient(
                        colors: IslandGradient.googleWheel.map {
                            $0.opacity(glowPulse ? 0.26 : 0.38)
                        },
                        center: .center
                    )
                )
                .rotationEffect(.degrees(haloSpin ? 360 : 0))
        } else {
            Circle().fill(providerColor.opacity(glowPulse ? 0.12 : 0.20))
        }
    }

    private func ringStyle(opacity: Double) -> AnyShapeStyle {
        isMulticolor
            ? AnyShapeStyle(AngularGradient(
                colors: IslandGradient.googleWheel.map { $0.opacity(opacity * 2.2) },
                center: .center
              ))
            : AnyShapeStyle(providerColor.opacity(opacity))
    }

    @ViewBuilder
    private var providerLogo: some View {
        if let image = logoImage {
            Image(nsImage: image)
                .renderingMode(provider.logoRendering)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(providerColor)
        } else {
            Image(systemName: provider == .claude ? "sparkle" : "circle.hexagongrid.fill")  // template fallback only
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(providerColor)
        }
    }

    private var logoImage: NSImage? {
        switch provider {
        case .claude: return ProviderLogos.claude
        case .codex: return ProviderLogos.openAI
        case .antigravity: return ProviderLogos.antigravity
        case .grok: return ProviderLogos.grok
        case .cursor: return ProviderLogos.cursor
        }
    }

    private static func loadLogo(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
    }

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
        withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
            ringPulse = true
        }
        guard isMulticolor else { return }
        // Slow enough to read as drifting light rather than a spinner.
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
            haloSpin = true
        }
    }
}

struct TurnAlarmMetadata: View {
    let providerName: String
    let threadName: String
    let projectName: String?
    let providerColor: Color
    /// The provider's full ramp — one stop repeated for single-colour
    /// brands, all four Google hues for Antigravity.
    let providerStops: [Color]

    var body: some View {
        HStack(spacing: 0) {
            metadataColumn(title: "Alarm provider", value: providerName, showsDot: true)
            Divider().frame(height: 40).overlay(.white.opacity(0.08))
            metadataColumn(title: "Alarm thread", value: threadName)
            Divider().frame(height: 40).overlay(.white.opacity(0.08))
            metadataColumn(title: "Alarm project", value: projectName ?? L10n.tr("Unknown"))
        }
        .frame(width: 396)
    }

    private func metadataColumn(title: String, value: String, showsDot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.36))
            HStack(spacing: 7) {
                if showsDot {
                    Circle()
                        .fill(IslandGradient.linear(providerStops))
                        // .shadow has no ShapeStyle overload anywhere in the
                        // SDK, so the halo stays a single representative hue.
                        .frame(width: 8, height: 8)
                        .shadow(color: providerColor.opacity(0.7), radius: 5)
                }
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
    }
}
