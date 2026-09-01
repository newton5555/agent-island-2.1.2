import AppKit

let claudeOrange = NSColor(red: 0xCC/255.0, green: 0x78/255.0, blue: 0x5C/255.0, alpha: 1)
let codexBlue = NSColor(red: 0x5A/255.0, green: 0xA8/255.0, blue: 0xF0/255.0, alpha: 1)

func savePNG(_ image: NSImage, to path: String, pixelsWide: Int, pixelsHigh: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// ---------- DMG background (660×420 @1x/@2x) ----------
//
// The composition IS the product story: the island silhouette hangs from the
// top edge exactly like the app hangs from the notch, with its two provider
// dots and a whisper of the brand-teal glow. Below, two quiet wells anchor
// the drag: app on the left, Applications on the right.
func drawBackground(scale: CGFloat) -> NSImage {
    let w: CGFloat = 660, h: CGFloat = 420
    let img = NSImage(size: CGSize(width: w, height: h))
    img.lockFocus()

    // Base coat — near-black, one soft vertical step (no showy gradient).
    NSGradient(colors: [
        NSColor(red: 0x10/255.0, green: 0x13/255.0, blue: 0x18/255.0, alpha: 1),
        NSColor(red: 0x0A/255.0, green: 0x0C/255.0, blue: 0x10/255.0, alpha: 1),
    ])!.draw(in: CGRect(x: 0, y: 0, width: w, height: h), angle: -90)

    // Island silhouette on the top edge (flat bottom corners, like the
    // hardware notch), brand-teal rim light beneath it.
    let islandW: CGFloat = 196, islandH: CGFloat = 24, r: CGFloat = 12
    let ix = w / 2 - islandW / 2, iy = h - islandH
    let island = NSBezierPath()
    island.move(to: CGPoint(x: ix, y: h))
    island.line(to: CGPoint(x: ix, y: iy + r))
    island.appendArc(withCenter: CGPoint(x: ix + r, y: iy + r), radius: r,
                     startAngle: 180, endAngle: 270, clockwise: false)
    island.line(to: CGPoint(x: ix + islandW - r, y: iy))
    island.appendArc(withCenter: CGPoint(x: ix + islandW - r, y: iy + r), radius: r,
                     startAngle: 270, endAngle: 360, clockwise: false)
    island.line(to: CGPoint(x: ix + islandW, y: h))
    island.close()
    // Soft rim light under the silhouette — white since the 2026-08-09
    // de-branding: the app carries no accent of its own.
    for (inset, alpha) in [(CGFloat(0), 0.22), (1.5, 0.11), (3.0, 0.055), (5.0, 0.03)] {
        let glow = island.copy() as! NSBezierPath
        glow.lineWidth = 1 + inset
        NSColor(white: 1, alpha: alpha).setStroke()
        glow.stroke()
    }
    NSColor.black.setFill()
    island.fill()
    // The two provider marks, reduced to their essence: one dot each.
    claudeOrange.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: w / 2 - 66, y: iy + islandH / 2 - 2.5, width: 5, height: 5)).fill()
    codexBlue.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: w / 2 + 61, y: iy + islandH / 2 - 2.5, width: 5, height: 5)).fill()

    // Wordmark row — real logo asset + name, centered as ONE group.
    let title = NSAttributedString(string: "Agent Island", attributes: [
        .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.92),
    ])
    let logoSide: CGFloat = 34, gap: CGFloat = 11
    let titleSize = title.size()
    let groupW = logoSide + gap + titleSize.width
    let groupX = w / 2 - groupW / 2
    let rowCenterY = h - 78
    // The five-blade mark (2026-08-09 brand). The old Assets/ path had
    // gone stale, which shipped a background with no mark at all. The
    // small-optimized variant — at 34pt the main mark's graphite blade
    // sinks into the coat.
    if let logo = NSImage(contentsOfFile: "Resources/agentisland_logo_small.png")
        ?? NSImage(contentsOfFile: "Resources/agentisland_logo.png") {
        logo.draw(in: CGRect(x: groupX, y: rowCenterY - logoSide / 2, width: logoSide, height: logoSide),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    title.draw(at: CGPoint(x: groupX + logoSide + gap, y: rowCenterY - titleSize.height / 2))

    // Drop wells under both icon slots (settings.py: centers x=165 / x=500,
    // y=210 from top → bottom-origin y=210). A faint plate, not a button.
    for cx in [CGFloat(165), 500] {
        let well = NSBezierPath(roundedRect: CGRect(x: cx - 76, y: 210 - 76, width: 152, height: 152),
                                xRadius: 32, yRadius: 32)
        NSColor(white: 1, alpha: 0.025).setFill()
        well.fill()
        well.lineWidth = 1
        NSColor(white: 1, alpha: 0.07).setStroke()
        well.stroke()
    }

    // Arrow between the wells — thin, rounded, quiet.
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: CGPoint(x: 262, y: 210))
    arrow.line(to: CGPoint(x: 398, y: 210))
    arrow.move(to: CGPoint(x: 376, y: 232))
    arrow.line(to: CGPoint(x: 398, y: 210))
    arrow.line(to: CGPoint(x: 376, y: 188))
    NSColor(white: 1, alpha: 0.34).setStroke()
    arrow.stroke()

    img.unlockFocus()
    return img
}

let bgDir = CommandLine.arguments[1]
savePNG(drawBackground(scale: 1), to: "\(bgDir)/background.png", pixelsWide: 660, pixelsHigh: 420)
savePNG(drawBackground(scale: 2), to: "\(bgDir)/background@2x.png", pixelsWide: 1320, pixelsHigh: 840)
print("assets generated")
