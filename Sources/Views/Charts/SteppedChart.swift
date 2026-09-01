import SwiftUI

struct SteppedChart: View {
    let value: Double      // 0-100
    let color: Color
    let label: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChartHead(value: value, label: label)
            // Fixed tick pitch, variable tick COUNT: a wide tile (a provider
            // with a single window spans the full row since Codex went
            // weekly-only) draws more thin ticks at the same density,
            // instead of stretching 30 ticks into fat battery blocks.
            GeometryReader { geo in
                let gap: CGFloat = 2
                let pitch: CGFloat = 5.2 // ≈ the two-tile layout's tick pitch
                let segments = max(12, Int((geo.size.width + gap) / pitch))
                let filled = (value / 100) * Double(segments)
                HStack(spacing: gap) {
                    ForEach(0..<segments, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Double(i) < floor(filled) ? color : .white.opacity(0.10))
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                            // Stagger scaled to the count so the sweep stays
                            // ~210ms no matter how many ticks the width holds.
                            .animation(.strongEaseOut.delay(Double(i) * 0.21 / Double(segments)), value: value)
                    }
                }
            }
            .frame(height: 16)
            ChartFoot(caption: sub)
        }
    }
}
