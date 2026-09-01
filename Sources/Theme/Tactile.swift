import AppKit
import SwiftUI

/// The press-feel system (2026-07-18, studied from the owner's Cadence
/// app): every actionable control compresses under the pointer with a
/// quick spring and answers through the trackpad. One style + one haptics
/// helper applied app-wide, so 打击感 is a property of the system, not a
/// per-button accident.
enum Haptics {
    /// Light tick for presses and toggles.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// The copy/save/share "impact" — Cadence ships a dedicated
    /// ShareImpactHaptics engine for this moment; ours rides the trackpad's
    /// generic thump when the action actually lands.
    static func impact() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }
}

struct TactileButtonStyle: ButtonStyle {
    // Restraint is the Cadence lesson (frame study, 2026-07-18): the film
    // has NO visible press-scale anywhere — its 打击感 lives in the
    // trackpad and in content transitions. Keep the haptic, keep the
    // compression barely perceptible.
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.8), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// Cadence D12-4: a single soft dip-and-recover pulse on the whole card
/// when an action lands (their drop-commit gesture; our copy/save moment).
struct SettlePulse: ViewModifier {
    var trigger: Int

    @State private var dipped = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(dipped ? 0.975 : 1)
            .onChange(of: trigger) { _ in
                withAnimation(.spring(response: 0.16, dampingFraction: 0.9)) { dipped = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dipped = false }
                }
            }
    }
}

/// Cadence C9 — the landing focus ring: an accent-colored halo flares from
/// a control the moment its choice COMMITS, then breathes out over ~0.6s.
/// The confirmation lives at the point of change, not in a caption.
struct LandingRing: ViewModifier {
    var trigger: Int
    var color: Color = IslandColor.chrome
    var cornerRadius: CGFloat = 10

    @State private var flare = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(flare ? 0 : 0.85), lineWidth: 1.5)
                .shadow(color: color.opacity(flare ? 0 : 0.55), radius: 6)
                .scaleEffect(flare ? 1.06 : 1)
                .opacity(trigger == 0 ? 0 : 1)
                .allowsHitTesting(false)
        }
        .onChange(of: trigger) { _ in
            flare = false
            withAnimation(.easeOut(duration: 0.62)) { flare = true }
        }
    }
}

extension View {
    func landingRing(trigger: Int, color: Color = IslandColor.chrome,
                     cornerRadius: CGFloat = 10) -> some View {
        modifier(LandingRing(trigger: trigger, color: color, cornerRadius: cornerRadius))
    }
}
