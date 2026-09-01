import SwiftUI
import AppKit

/// A small, self-animating provider logo for the Settings status guide — it
/// shows the real behavior of each live state instead of a stand-in icon.
/// Demo only: a fixed state, not wired to the live monitor.
///
/// Demos default to the Codex mark: it is rotationally symmetric, so the
/// working spin reads as motion instead of wobble (owner's call, 2026-07-16
/// — the asymmetric Claude mark looks off mid-rotation).
struct StatePreviewLogo: View {
    let state: ActivityMonitor.State
    var provider: AlertEngine.Provider = .codex

    @State private var pulse = false
    @State private var spin: Double = 0

    private static let claudeImage = Bundle.main.url(forResource: "claude_logo", withExtension: "pdf").flatMap { NSImage(contentsOf: $0) }
    private static let codexImage = Bundle.main.url(forResource: "openai_logo", withExtension: "pdf").flatMap { NSImage(contentsOf: $0) }
    private static let alarmRed = Color(red: 0.96, green: 0.34, blue: 0.29)

    private var image: NSImage? {
        switch provider {
        case .claude: return Self.claudeImage
        case .codex: return Self.codexImage
        case .antigravity: return ProviderLogos.antigravity
        case .grok: return ProviderLogos.grok
        case .cursor: return ProviderLogos.cursor
        }
    }
    private var tint: Color {
        switch state {
        case .stalled, .rateLimited, .authRequired: return Self.alarmRed
        case .idle, .working, .needsYou:
            return provider.accent
        }
    }

    var body: some View {
        Group {
            if state == .needsYou {
                // Same glyph language as the other rows — the logo, steady,
                // with a small bell badge — instead of a bell-in-a-box that
                // read as a different icon family (design review, 2026-07-16).
                ZStack(alignment: .bottomTrailing) {
                    if let image {
                        Image(nsImage: image)
                            .renderingMode(provider.logoRendering)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(tint)
                            .frame(width: 20, height: 20)
                    }
                    ZStack {
                        Circle().fill(Color(red: 0.075, green: 0.086, blue: 0.11))
                        Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundStyle(IslandColor.chrome)
                    }
                    .frame(width: 11, height: 11)
                    .offset(x: 3, y: 2)
                }
                .frame(width: 24, height: 22)
            } else if let image {
                Image(nsImage: image)
                    .renderingMode(provider.logoRendering)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(spin))
                    .shadow(color: tint.opacity(pulse ? 0.8 : 0.2), radius: glow)
            } else {
                Circle().fill(tint).frame(width: 12, height: 12)
            }
        }
        .frame(width: 26, height: 26)
        .onAppear(perform: animate)
    }

    private var scale: CGFloat {
        switch state {
        case .working:  return pulse ? 1.06 : 0.97
        case .needsYou: return 1.0
        case .stalled, .authRequired, .rateLimited:  return pulse ? 1.14 : 0.97
        case .idle:     return 1.0
        }
    }

    private var glow: CGFloat {
        switch state {
        case .working:  return pulse ? 5 : 2
        case .needsYou: return 0
        case .stalled, .authRequired, .rateLimited:  return pulse ? 10 : 3
        case .idle:     return 0
        }
    }

    private func animate() {
        let blocked = state == .stalled || state == .authRequired || state == .rateLimited
        if state == .working || blocked {
            let dur: Double = blocked ? 0.42 : 1.7
            withAnimation(.easeInOut(duration: dur).repeatForever(autoreverses: true)) { pulse = true }
        }
        if state == .working {
            let duration = 3.8
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                spin = (provider == .claude || provider == .antigravity || provider == .cursor ? 1 : -1) * 360
            }
        }
    }
}
