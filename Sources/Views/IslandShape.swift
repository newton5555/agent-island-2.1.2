import SwiftUI

/// The notch silhouette: flat top with small OUTWARD fillets at both top
/// corners — the sides flare into the screen edge the way the hardware
/// housing does — and rounded bottom corners that mirror the physical
/// notch's inner curves. Without the flares, the wings meet the menu bar
/// as bare 90° corners, which reads as "obviously drawn" next to the real
/// notch (first external design review: "上面没有圆角").
///
/// The flare occupies `topCurl` points on each side of the frame, OUTSIDE
/// the visual body — IslandModel grows every state's width by
/// `topCurl * 2` so the body keeps its width, and edge-anchored overlays
/// inset themselves by `topCurl`.
///
/// All corners are quad curves: tangent-continuous at both ends, so
/// curvature ramps in instead of jumping the way plain circular arcs do
/// (which show a visible kink at this scale).
struct IslandShape: InsettableShape {
    var inset: CGFloat = 0

    /// Outward top-fillet radius; also the per-side frame padding the
    /// silhouette body cedes to the flare.
    static let topCurl: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let curl = min(Self.topCurl, r.width / 4, r.height / 2)
        let radius = min(14, r.width / 2 - curl, r.height - curl)

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        // Right flare: the top edge eases down into the body's outer edge.
        p.addQuadCurve(
            to: CGPoint(x: r.maxX - curl, y: r.minY + curl),
            control: CGPoint(x: r.maxX - curl, y: r.minY)
        )
        p.addLine(to: CGPoint(x: r.maxX - curl, y: r.maxY - radius))
        p.addQuadCurve(
            to: CGPoint(x: r.maxX - curl - radius, y: r.maxY),
            control: CGPoint(x: r.maxX - curl, y: r.maxY)
        )
        p.addLine(to: CGPoint(x: r.minX + curl + radius, y: r.maxY))
        p.addQuadCurve(
            to: CGPoint(x: r.minX + curl, y: r.maxY - radius),
            control: CGPoint(x: r.minX + curl, y: r.maxY)
        )
        p.addLine(to: CGPoint(x: r.minX + curl, y: r.minY + curl))
        // Left flare.
        p.addQuadCurve(
            to: CGPoint(x: r.minX, y: r.minY),
            control: CGPoint(x: r.minX + curl, y: r.minY)
        )
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var s = self
        s.inset += amount
        return s
    }
}
