import SwiftUI

/// One tile in the chart-style / cost-style picker grids. Feel:
///   - HOVER LIFT — the tile rises a hair (scale + shadow) so the grid
///     answers the pointer before anything is clicked (Cadence E16's one
///     permitted strong hover, spent here where choosing happens).
///   - LANDING RING — picking a tile flares a teal focus ring that
///     breathes out (C9); the selected state then holds as a quiet teal
///     wash + rim, brand language instead of the inherited cobalt.
///   - SETTLE — the preview dips once as the choice commits (D12-4).
struct StyleTile<Preview: View>: View {
    let displayLabel: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    @State private var hovered = false
    @State private var landed = 0

    var body: some View {
        Button {
            guard !isOn else { return }
            Haptics.tap()
            landed += 1
            action()
        } label: {
            VStack(spacing: 7) {
                preview()
                    .frame(height: 34)
                    .accessibilityHidden(true)
                Text(displayLabel)
                    .font(SettingsType.data.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(isOn
                        ? IslandColor.chrome.opacity(0.95)
                        : .white.opacity(hovered ? 0.8 : 0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn
                          ? IslandColor.chrome.opacity(0.12)
                          : .white.opacity(hovered ? 0.05 : 0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isOn
                                ? IslandColor.chrome.opacity(0.6)
                                : .white.opacity(hovered ? 0.10 : 0), lineWidth: 1)
                    }
            }
            .modifier(SettlePulse(trigger: landed))
            .landingRing(trigger: landed, color: IslandColor.chrome, cornerRadius: 9)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && !isOn ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.30 : 0), radius: 7, y: 3)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovered)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .accessibilityLabel(displayLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
