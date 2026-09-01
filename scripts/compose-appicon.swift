import AppKit

// Composes Resources/AgentIsland.icns from the five-blade mark PNGs.
// Run from the repo root via scripts/make-icns.sh.
//
// Grid follows the macOS Big Sur icon template: 1024pt canvas, 824pt
// rounded-square plate (100pt margins), ~185pt corner radius. The plate is
// the app's post-debranding chrome voice — near-black glass with a hairline
// white edge, no accent color. The mark owns the plate (owner review,
// 2026-08-09: the 72% composition read as a black blob with a pin in it).
//
// Small slots (16/32px) swap in the small-optimized mark — bolder blades,
// lightened graphite — and let it take more of the plate, or the dark
// blades dissolve into the coat.

let fullMark = NSImage(contentsOfFile: "Resources/agentisland_logo.png")!
let smallMark = NSImage(contentsOfFile: "Resources/agentisland_logo_small.png")
    ?? fullMark
/// GPT-painted icon artwork (appicon-art.png, opaque full-bleed square) —
/// when present it IS the plate for the large slots; the compose path
/// below stays the fallback and still builds the tiny slots.
let iconArt = NSImage(contentsOfFile: "Resources/appicon-art.png")

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)

    // ≤64px Finder rows are where painted art turns to mud — those slots
    // are composed from the bolder small-variant mark on a matching plate.
    let tiny = pixels <= 64

    if !tiny, let iconArt {
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        iconArt.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
    } else {
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [
            NSColor(red: 0x1A/255.0, green: 0x1E/255.0, blue: 0x26/255.0, alpha: 1),
            NSColor(red: 0x0A/255.0, green: 0x0C/255.0, blue: 0x10/255.0, alpha: 1),
        ])!.draw(in: plate, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // GLYPH share: the normalized mark PNGs carry the glyph at ~96%
        // of their canvas, hence the divide.
        let mark = tiny ? smallMark : fullMark
        let share: CGFloat = (tiny ? 0.86 : 0.80) / 0.96
        let markSide = plate.width * share
        mark.draw(
            in: CGRect(x: plate.midX - markSide / 2, y: plate.midY - markSide / 2,
                       width: markSide, height: markSide),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
    }

    // Hairline edge — scales with the canvas, floors at one device pixel.
    path.lineWidth = max(1, 3 * s)
    NSColor(white: 1, alpha: 0.16).setStroke()
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments[1]
let slots: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in slots {
    let rep = drawIcon(pixels: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("iconset composed")
