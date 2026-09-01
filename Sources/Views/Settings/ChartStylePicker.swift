import SwiftUI

/// Five-tile picker for the default chart style. Replaces the
/// undocumented ⌘-click cycle gesture (which still works in the panel).
/// Each tile renders a tiny preview using the brand terracotta — not
/// pixel-identical to the live chart, but the same vocabulary so the
/// picker reads as a real preview, not an icon set.
struct ChartStylePicker: View {
    @Binding var selected: ChartStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChartStyle.allCases, id: \.self) { style in
                StyleTile(
                    displayLabel: style.label,
                    isOn: style == selected,
                    action: {
                        selected = style
                        if !StylePref.shared.hasCycledStyle {
                            StylePref.shared.hasCycledStyle = true
                        }
                    }
                ) {
                    preview(for: style)
                }
            }
        }
    }

    @ViewBuilder
    private func preview(for style: ChartStyle) -> some View {
        // Previews speak ONE voice — brand teal — because the picker is
        // about SHAPE, not whose data (owner call, 2026-08-08).
        let claude = IslandColor.chrome
        switch style {
        case .ring:
            ZStack {
                Circle().fill(.white.opacity(0.08))
                PieSlice(fraction: 0.35)
                    .fill(claude)
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
            }
            .frame(width: 26, height: 26)
        case .bar:
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(claude)
                    .frame(width: 28 * 0.35)
            }
            .frame(width: 28, height: 6)
        case .stepped:
            HStack(spacing: 1.5) {
                ForEach(0..<8) { i in
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(i < 3 ? claude : .white.opacity(0.10))
                        .frame(width: 2, height: 12)
                }
            }
            .frame(width: 28, height: 14)
        case .numeric:
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("35")
                    .font(Typography.previewNumber)
                    .foregroundStyle(claude)
                Text("%")
                    .font(SettingsType.data)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
