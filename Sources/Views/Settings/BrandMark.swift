import AppKit
import SwiftUI

/// The bare five-blade mark — transparent, no plate, no border, no motion
/// (the hover spin died 2026-08-09: 我一碰它它就转,很莫名其妙). The framed
/// tile treatment is equally dead; with the small-optimized variant the
/// bare glyph stays legible at chrome sizes on its own.
struct BrandMark: View {
    var side: CGFloat = 24

    /// The small-size-optimized variant (bolder blades, lightened
    /// graphite) — the full mark stays the fallback so a missing resource
    /// degrades to the real logo.
    private static let mark: NSImage? =
        (Bundle.main.url(forResource: "agentisland_logo_small", withExtension: "png")
            ?? Bundle.main.url(forResource: "agentisland_logo", withExtension: "png"))
            .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let mark = Self.mark {
                Image(nsImage: mark)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
