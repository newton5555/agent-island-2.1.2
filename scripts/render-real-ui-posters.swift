#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

struct PosterLayer {
    let source: URL
    let frameFromTop: CGRect
    let cropFromTop: CGRect?
    let cornerRadius: CGFloat
    let opacity: CGFloat

    init(
        _ source: URL,
        frame: CGRect,
        crop: CGRect? = nil,
        cornerRadius: CGFloat = 28,
        opacity: CGFloat = 1
    ) {
        self.source = source
        self.frameFromTop = frame
        self.cropFromTop = crop
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }
}

struct Poster {
    let size: CGSize
    let tealAnchor: CGPoint
    let amberAnchor: CGPoint
    let layers: [PosterLayer]
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repository = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let workspace = repository.deletingLastPathComponent().deletingLastPathComponent()
let screenshotRoot = workspace
    .appendingPathComponent("03_产品视频原始资产")
    .appendingPathComponent("08_界面截图_20260808_v2.1.1")
let taskRoot = workspace
    .appendingPathComponent("03_产品视频原始资产")
    .appendingPathComponent("06_生图任务_20260808_v2.1.1")
let resourceRoot = repository.appendingPathComponent("Resources")
let finishedRoot = taskRoot.appendingPathComponent("成品")

func source(_ relativePath: String) -> URL {
    screenshotRoot.appendingPathComponent(relativePath)
}

func requiredImage(_ url: URL) throws -> NSImage {
    guard fileManager.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
        throw NSError(
            domain: "RealUIPoster",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing source image: \(url.path)"]
        )
    }
    return image
}

func outputRect(_ topRect: CGRect, canvasHeight: CGFloat) -> CGRect {
    CGRect(
        x: topRect.minX,
        y: canvasHeight - topRect.maxY,
        width: topRect.width,
        height: topRect.height
    )
}

func sourceRect(_ normalizedTopRect: CGRect?, image: NSImage) -> CGRect {
    guard let normalizedTopRect else {
        return CGRect(origin: .zero, size: image.size)
    }
    return CGRect(
        x: normalizedTopRect.minX * image.size.width,
        y: (1 - normalizedTopRect.maxY) * image.size.height,
        width: normalizedTopRect.width * image.size.width,
        height: normalizedTopRect.height * image.size.height
    )
}

func aspectFillSourceRect(_ source: CGRect, destination: CGRect) -> CGRect {
    guard source.width > 0, source.height > 0,
          destination.width > 0, destination.height > 0 else {
        return source
    }

    let sourceRatio = source.width / source.height
    let destinationRatio = destination.width / destination.height
    if sourceRatio > destinationRatio {
        let width = source.height * destinationRatio
        return CGRect(
            x: source.midX - width / 2,
            y: source.minY,
            width: width,
            height: source.height
        )
    }

    let height = source.width / destinationRatio
    return CGRect(
        x: source.minX,
        y: source.midY - height / 2,
        width: source.width,
        height: height
    )
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha).cgColor
}

func drawGlow(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    tint: CGColor,
    alpha: CGFloat
) {
    let transparent = color(0, 0, 0, 0)
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [tint.copy(alpha: alpha) ?? tint, transparent] as CFArray,
        locations: [0, 1]
    ) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
}

func drawBackground(_ poster: Poster, in context: CGContext) {
    let size = poster.size
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.035, 0.043, 0.055), color(0.012, 0.014, 0.020)] as CFArray,
        locations: [0, 1]
    ) else { return }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size.height),
        end: CGPoint(x: size.width, y: 0),
        options: []
    )
    drawGlow(
        in: context,
        center: CGPoint(x: poster.tealAnchor.x, y: size.height - poster.tealAnchor.y),
        radius: min(size.width, size.height) * 0.78,
        tint: color(0.125, 0.753, 0.690),
        alpha: 0.20
    )
    drawGlow(
        in: context,
        center: CGPoint(x: poster.amberAnchor.x, y: size.height - poster.amberAnchor.y),
        radius: min(size.width, size.height) * 0.64,
        tint: color(0.918, 0.640, 0.286),
        alpha: 0.12
    )
    context.setStrokeColor(color(1, 1, 1, 0.028))
    context.setLineWidth(1)
    let step: CGFloat = 80
    stride(from: step, to: size.width, by: step).forEach { x in
        context.move(to: CGPoint(x: x, y: 0))
        context.addLine(to: CGPoint(x: x, y: size.height))
    }
    stride(from: step, to: size.height, by: step).forEach { y in
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: size.width, y: y))
    }
    context.strokePath()
}

func draw(_ layer: PosterLayer, canvasHeight: CGFloat, in context: CGContext) throws {
    let image = try requiredImage(layer.source)
    let destination = outputRect(layer.frameFromTop, canvasHeight: canvasHeight)
    let croppedSource = sourceRect(layer.cropFromTop, image: image)
    let lockedSource = aspectFillSourceRect(croppedSource, destination: destination)
    let path = CGPath(
        roundedRect: destination,
        cornerWidth: layer.cornerRadius,
        cornerHeight: layer.cornerRadius,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -22),
        blur: 44,
        color: color(0, 0, 0, 0.72)
    )
    context.addPath(path)
    context.setFillColor(color(0.008, 0.009, 0.013, 0.98))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    image.draw(
        in: destination,
        from: lockedSource,
        operation: .sourceOver,
        fraction: layer.opacity,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(color(1, 1, 1, 0.15))
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()
}

func render(_ poster: Poster) throws -> Data {
    let width = Int(poster.size.width)
    let height = Int(poster.size.height)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
            domain: "RealUIPoster",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unable to create poster bitmap"]
        )
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    drawBackground(poster, in: context)
    for layer in poster.layers {
        try draw(layer, canvasHeight: poster.size.height, in: context)
    }
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "RealUIPoster",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Unable to encode poster PNG"]
        )
    }
    return data
}

func write(_ poster: Poster, named name: String, includeFinishedCopy: Bool = true) throws {
    let data = try render(poster)
    try fileManager.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
    try data.write(to: resourceRoot.appendingPathComponent(name), options: .atomic)
    if includeFinishedCopy {
        try fileManager.createDirectory(at: finishedRoot, withIntermediateDirectories: true)
        try data.write(to: finishedRoot.appendingPathComponent(name), options: .atomic)
    }
    print(name)
}

let settingsCrop = CGRect(x: 0, y: 0.055, width: 1, height: 0.69)
let cursorRowCrop = CGRect(x: 0.27, y: 0.61, width: 0.65, height: 0.105)
let codexRowCrop = CGRect(x: 0.27, y: 0.33, width: 0.65, height: 0.105)
let standardSize = CGSize(width: 1600, height: 900)

func fullSettingsPoster(_ image: URL, teal: CGPoint, amber: CGPoint) -> Poster {
    Poster(
        size: standardSize,
        tealAnchor: teal,
        amberAnchor: amber,
        layers: [
            PosterLayer(
                image,
                frame: CGRect(x: 80, y: 40, width: 1440, height: 818),
                crop: settingsCrop,
                cornerRadius: 30
            ),
        ]
    )
}

func reportPoster(_ language: String) -> Poster {
    Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 260, y: 120),
        amberAnchor: CGPoint(x: 1380, y: 780),
        layers: [
            PosterLayer(
                source("reports/monthly-\(language).png"),
                frame: CGRect(x: 180, y: 76, width: 560, height: 747),
                cornerRadius: 28,
                opacity: 0.88
            ),
            PosterLayer(
                source("reports/weekly-\(language).png"),
                frame: CGRect(x: 805, y: 42, width: 600, height: 800),
                cornerRadius: 30
            ),
        ]
    )
}

func islandPoster(_ language: String) -> Poster {
    let providers = source("\(language)/settings-providers.png")
    return Poster(
        size: CGSize(width: 1800, height: 600),
        tealAnchor: CGPoint(x: 250, y: 120),
        amberAnchor: CGPoint(x: 1600, y: 520),
        layers: [
            PosterLayer(
                source("island/island-claude-codex.png"),
                frame: CGRect(x: 120, y: 72, width: 1560, height: 205),
                cornerRadius: 46
            ),
            PosterLayer(
                source("island/island-gemini-grok.png"),
                frame: CGRect(x: 260, y: 304, width: 1280, height: 168),
                cornerRadius: 40
            ),
            PosterLayer(
                providers,
                frame: CGRect(x: 470, y: 466, width: 860, height: 114),
                crop: cursorRowCrop,
                cornerRadius: 24
            ),
        ]
    )
}

func statusPoster() -> Poster {
    Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 180, y: 140),
        amberAnchor: CGPoint(x: 1420, y: 760),
        layers: [
            PosterLayer(
                source("island/island-claude-codex.png"),
                frame: CGRect(x: 100, y: 150, width: 1400, height: 184),
                cornerRadius: 42
            ),
            PosterLayer(
                source("island/island-gemini-grok.png"),
                frame: CGRect(x: 100, y: 510, width: 1400, height: 184),
                cornerRadius: 42
            ),
        ]
    )
}

func panelPoster(_ language: String, kind: String) -> Poster {
    Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 240, y: 140),
        amberAnchor: CGPoint(x: 1360, y: 760),
        layers: [
            PosterLayer(
                source("island/panel-\(kind)-\(language).png"),
                frame: CGRect(x: 80, y: 210, width: 1440, height: 469),
                cornerRadius: 36
            ),
        ]
    )
}

for language in ["zh", "en"] {
    let suffix = language == "en" ? "-en" : ""
    let providers = source("\(language)/settings-providers.png")
    let display = source("\(language)/settings-display.png")
    let statusGuide = source("\(language)/settings-statusGuide.png")
    let authError = source("\(language)/settings-providers-auth-error.png")

    try write(islandPoster(language), named: "whatsnew-211-overview\(suffix).png")

    let cursorPoster = Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 250, y: 120),
        amberAnchor: CGPoint(x: 1380, y: 760),
        layers: [
            PosterLayer(
                providers,
                frame: CGRect(x: 130, y: 55, width: 1340, height: 761),
                crop: settingsCrop,
                cornerRadius: 30,
                opacity: 0.58
            ),
            PosterLayer(
                providers,
                frame: CGRect(x: 245, y: 590, width: 1110, height: 148),
                crop: cursorRowCrop,
                cornerRadius: 24
            ),
        ]
    )
    try write(cursorPoster, named: "whatsnew-211-cursor\(suffix).png")

    try write(
        fullSettingsPoster(
            providers,
            teal: CGPoint(x: 210, y: 120),
            amber: CGPoint(x: 1410, y: 780)
        ),
        named: "whatsnew-211-picker\(suffix).png"
    )

    try write(statusPoster(), named: "whatsnew-211-session-status\(suffix).png")

    let accountsPoster = Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 1340, y: 140),
        amberAnchor: CGPoint(x: 240, y: 780),
        layers: [
            PosterLayer(
                providers,
                frame: CGRect(x: 130, y: 55, width: 1340, height: 761),
                crop: settingsCrop,
                cornerRadius: 30,
                opacity: 0.58
            ),
            PosterLayer(
                providers,
                frame: CGRect(x: 245, y: 385, width: 1110, height: 148),
                crop: codexRowCrop,
                cornerRadius: 24
            ),
        ]
    )
    try write(accountsPoster, named: "whatsnew-211-accounts\(suffix).png")

    try write(
        fullSettingsPoster(
            display,
            teal: CGPoint(x: 1320, y: 130),
            amber: CGPoint(x: 260, y: 760)
        ),
        named: "whatsnew-211-settings\(suffix).png"
    )

    try write(reportPoster(language), named: "whatsnew-211-reports\(suffix).png")

    try write(
        fullSettingsPoster(
            authError,
            teal: CGPoint(x: 230, y: 120),
            amber: CGPoint(x: 1380, y: 780)
        ),
        named: "whatsnew-211-signin\(suffix).png"
    )

    try write(panelPoster(language, kind: "usage"), named: "whatsnew-211-start\(suffix).png")

    let guideStatus = Poster(
        size: standardSize,
        tealAnchor: CGPoint(x: 210, y: 120),
        amberAnchor: CGPoint(x: 1400, y: 780),
        layers: [
            PosterLayer(
                statusGuide,
                frame: CGRect(x: 80, y: 40, width: 1440, height: 818),
                crop: settingsCrop,
                cornerRadius: 30
            ),
        ]
    )
    try write(guideStatus, named: "guide-status\(suffix).png")
    try write(panelPoster(language, kind: "usage"), named: "guide-usage\(suffix).png")
    try write(panelPoster(language, kind: "cost"), named: "guide-cost\(suffix).png")
    try write(reportPoster(language), named: "guide-cards\(suffix).png")
    try write(
        fullSettingsPoster(
            display,
            teal: CGPoint(x: 1320, y: 130),
            amber: CGPoint(x: 260, y: 760)
        ),
        named: "guide-personalize\(suffix).png"
    )
}

let brandPoster = Poster(
    size: standardSize,
    tealAnchor: CGPoint(x: 800, y: 160),
    amberAnchor: CGPoint(x: 800, y: 800),
    layers: [
        PosterLayer(
            source("island/island-claude-codex.png"),
            frame: CGRect(x: 110, y: 190, width: 1380, height: 181),
            cornerRadius: 42
        ),
        PosterLayer(
            source("island/island-gemini-grok.png"),
            frame: CGRect(x: 230, y: 520, width: 1140, height: 150),
            cornerRadius: 36
        ),
    ]
)
try write(brandPoster, named: "guide-brand.png")
