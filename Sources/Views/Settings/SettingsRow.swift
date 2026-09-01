import SwiftUI

/// A settings row in Agent Island's own idiom: no card, no border. A
/// brand-tinted rule slides in on the leading edge as the pointer arrives
/// and a faint gradient washes left-to-right — the same vocabulary the
/// provider list uses, so the whole panel reads as one surface instead of
/// a stack of boxes.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let dot: Color?
    let chip: String?
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovered = false

    init(
        title: String,
        subtitle: String? = nil,
        dot: Color? = nil,
        chip: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dot = dot
        self.chip = chip
        self.trailing = trailing
    }

    /// Rows without a provider dot borrow the brand accent for their hover
    /// rule; provider rows keep their own color.
    private var accent: Color { dot ?? IslandColor.chrome }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 7, height: 7)
                            .shadow(color: dot.opacity(0.7), radius: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                    }
                    Text(L10n.tr(title))
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(.white.opacity(hovered ? 1 : 0.92))
                    if let chip {
                        Text(chip)
                            .font(Typography.chip)
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.white.opacity(0.07))
                            )
                            .accessibilityLabel(L10n.tr("Plan: %@", chip))
                    }
                }
                if let subtitle {
                    Text(L10n.tr(subtitle))
                        .font(SettingsType.data)
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 11)
        .background {
            LinearGradient(
                colors: [accent.opacity(hovered ? 0.055 : 0), .clear],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .overlay(alignment: .leading) {
            // The rule grows from nothing on hover rather than fading a
            // rectangle in — motion reads as arrival, not as a light bulb.
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(hovered ? 0.9 : 0))
                .frame(width: 2)
                .padding(.vertical, hovered ? 7 : 18)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: hovered)
    }
}
