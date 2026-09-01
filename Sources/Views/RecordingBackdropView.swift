import SwiftUI
import AppKit

/// Fullscreen stage for recording rigs. V1 was a card-style gradient (read
/// as a "grey board" — rejected); V2 is a stock macOS wallpaper, so clips
/// look like a clean real desktop while guaranteeing no private windows,
/// desktop widgets, or note titles ever enter frame.
struct RecordingBackdropView: View {
    /// AGENTISLAND_BACKDROP=dark → dark gradient stage (the "深色桌面" set);
    /// any other value → stock wallpaper.
    private static let dark =
        ProcessInfo.processInfo.environment["AGENTISLAND_BACKDROP"] == "dark"

    private static let wallpaper: NSImage? = {
        let candidates = [
            "/System/Library/Desktop Pictures/Sonoma.heic",
            "/System/Library/Desktop Pictures/Radial Sky Blue.heic",
            "/System/Library/Desktop Pictures/Mac Blue.heic",
        ]
        for path in candidates {
            if let image = NSImage(contentsOfFile: path) { return image }
        }
        return nil
    }()

    var body: some View {
        Group {
            if Self.dark {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.09, green: 0.095, blue: 0.12),
                                 Color(red: 0.03, green: 0.032, blue: 0.045)],
                        startPoint: .top, endPoint: .bottom
                    )
                    RadialGradient(colors: [IslandColor.claude.opacity(0.06), .clear],
                                   center: .init(x: 0.2, y: 0.15), startRadius: 0, endRadius: 700)
                    RadialGradient(colors: [IslandColor.codex.opacity(0.06), .clear],
                                   center: .init(x: 0.85, y: 0.7), startRadius: 0, endRadius: 800)
                }
            } else if let wallpaper = Self.wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.06, blue: 0.075),
                             Color(red: 0.02, green: 0.022, blue: 0.03)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// Top slice of the same wallpaper, used to paint OVER the menu bar during
/// recordings (status items would photobomb peek-state clips otherwise).
/// Drawn with the identical fullscreen scaledToFill math, so it lines up
/// seamlessly with the backdrop below it.
struct RecordingTopStripView: View {
    let screenSize: CGSize
    let stripHeight: CGFloat

    var body: some View {
        RecordingBackdropView()
            .frame(width: screenSize.width, height: screenSize.height)
            .frame(width: screenSize.width, height: stripHeight, alignment: .top)
            .clipped()
    }
}
