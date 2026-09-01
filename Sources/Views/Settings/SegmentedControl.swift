import SwiftUI

/// Segmented picker with a SLIDING thumb (Cadence C11): one bright capsule
/// that glides between choices on a high-damping spring, instead of
/// per-item fills popping in and out. The label under the thumb inverts to
/// dark, unselected labels hover-brighten, and the thumb answers arrival
/// with the shared haptic tick.
struct SegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selected: Value
    let label: (Value) -> String
    var accessibilityPrefix: String = ""

    @Namespace private var thumb
    @State private var hoveredItem: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let isOn = (item == selected)
                let itemLabel = L10n.tr(label(item))
                Button {
                    guard !isOn else { return }
                    Haptics.tap()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        selected = item
                    }
                } label: {
                    Text(itemLabel)
                        .font(SettingsType.data.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn
                            ? Color.black.opacity(0.85)
                            : .white.opacity(hoveredItem == item ? 0.85 : 0.55))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
                    }
                }
                .accessibilityLabel(accessibilityPrefix.isEmpty
                    ? itemLabel
                    : L10n.tr("%@, %@", L10n.tr(accessibilityPrefix), itemLabel))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background {
            Capsule().fill(.white.opacity(0.05))
                .overlay { Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 1) }
        }
    }
}

/// Small action pill. Hover lifts it a hair off the surface (brighter fill
/// + deeper shadow); loading swaps the label for three breathing dots
/// instead of just dimming — the control stays visibly ALIVE while it
/// waits.
struct PillButton: View {
    let label: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(L10n.tr(label))
                    .font(SettingsType.data.weight(.semibold))
                    .opacity(isLoading ? 0 : 1)
                if isLoading { BreathingDots() }
            }
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.white.opacity(hovered ? 0.15 : 0.10))
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(hovered ? 0.14 : 0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(hovered ? 0.35 : 0), radius: 5, y: 2)
            }
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(isLoading)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// Three dots breathing in sequence — the waiting state as a heartbeat.
private struct BreathingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .opacity(phase ? 0.25 : 0.9)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
        .accessibilityLabel(L10n.tr("Refreshing…"))
    }
}
