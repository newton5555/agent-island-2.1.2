import SwiftUI

/// Agent Island's switch. Three layered behaviors make it feel machined
/// rather than stock:
///   1. PRESS-STRETCH — while the pointer is down the knob elongates
///      toward its destination (anchored to the side it's leaving), so the
///      control visibly stores energy before it commits.
///   2. GLIDE — release, and the knob travels on a high-damping spring;
///      the track's teal floods in slightly behind it, like light catching
///      up.
///   3. LANDING HALO — the instant an ON commits, a teal ring flares off
///      the knob and breathes out (Cadence C9): confirmation at the point
///      of change, no caption needed.
/// The haptic tick rides the press itself so the stretch and the tick
/// share one gesture.
struct SettingsToggle: View {
    let isOn: Bool
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false
    @State private var halo = 0

    private let trackWidth: CGFloat = 34
    private let trackHeight: CGFloat = 19
    private let knobSize: CGFloat = 15
    private let knobStretch: CGFloat = 4

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track: teal wash when on, faint well when off; hover lifts
            // the rim either way.
            Capsule()
                .fill(isOn ? IslandColor.chrome.opacity(0.34) : .white.opacity(0.07))
                .overlay {
                    Capsule().strokeBorder(
                        isOn
                            ? IslandColor.chrome.opacity(hovered ? 0.55 : 0.35)
                            : .white.opacity(hovered ? 0.22 : 0.13),
                        lineWidth: 1
                    )
                }
                .frame(width: trackWidth, height: trackHeight)

            // Knob: stretches under the pointer, glides on release, glows
            // teal only once it has arrived somewhere.
            Capsule()
                .fill(isOn ? Color.white : Color.white.opacity(0.55))
                .frame(width: pressed ? knobSize + knobStretch : knobSize,
                       height: knobSize)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .shadow(color: isOn ? IslandColor.chrome.opacity(0.32) : .clear, radius: 5)
                .overlay {
                    // Landing halo — flares once per ON commit.
                    Circle()
                        .strokeBorder(IslandColor.chrome, lineWidth: 1.2)
                        .modifier(HaloBreath(trigger: halo))
                }
                .padding(.horizontal, (trackHeight - knobSize) / 2)
        }
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        // A zero-minimum long-press exposes the held state a Button hides:
        // stretch on touch-down, commit + spring on release.
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 30, perform: {
            Haptics.tap()
            action()
            if !isOn { halo += 1 }  // committing toward ON
            withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                pressed = false
            }
        }, onPressingChanged: { down in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                pressed = down
            }
        })
        .animation(.spring(response: 0.30, dampingFraction: 0.72), value: isOn)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "1" : "0")
    }
}

/// One-shot expanding ring: scale 1 → 1.9, opacity 0.8 → 0, ~0.55s.
private struct HaloBreath: ViewModifier {
    var trigger: Int
    @State private var out = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(out ? 1.9 : 1)
            .opacity(trigger == 0 ? 0 : (out ? 0 : 0.8))
            .allowsHitTesting(false)
            .onChange(of: trigger) { _ in
                out = false
                withAnimation(.easeOut(duration: 0.55)) { out = true }
            }
    }
}
