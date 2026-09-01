import SwiftUI

/// Solid pie (owner call, 1.7.2: 环形改实心饼图,不要中间空的). The name
/// stays RingChart to keep the style's stored rawValue ("ring") stable.
struct RingChart: View {
    let value: Double      // 0-100
    let color: Color
    let label: String
    let sub: String
    /// A single-window provider's tile spans the full row (Codex has been
    /// weekly-only since July 2026); a left-hugging pie leaves a void on
    /// the right, so the wide tile centers instead.
    var centered: Bool = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.055))
                    PieSlice(fraction: max(0.004, value / 100))
                        .fill(RadialGradient(
                            colors: [color.opacity(0.96), color.opacity(0.74)],
                            center: .center, startRadius: 2, endRadius: 30
                        ))
                        // No animate-from-zero on charts. The only animation
                        // here fires when polling delivers a new value
                        // (old → new), which keeps the slice feeling alive
                        // without ever flashing 0%.
                        .animation(.strongEaseOut, value: value)
                    Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(Typography.label)
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.lowercase)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(value))")
                            .font(Typography.chartValue)
                            .foregroundStyle(UrgencyColor.value(value))
                            .numericTransition(value: value)
                            .animation(.strongEaseOut, value: value)
                        Text("%")
                            .font(Typography.label)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                if !centered { Spacer() }
            }
            Text(sub)
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Filled sector from 12 o'clock, clockwise — animatable on its fraction.
struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0 else { return p }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: center)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * min(1, fraction)),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
