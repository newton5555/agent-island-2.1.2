import SwiftUI

/// Locked color tokens for AgentIsland.
enum IslandColor {
    /// #0047AB — loading sweep, glow halo.
    static let cobalt = Color(red: 0/255, green: 71/255, blue: 171/255)

    /// #CC785C — Anthropic terracotta. Claude logo + ring/bar fills.
    static let claude = Color(red: 204/255, green: 120/255, blue: 92/255)

    /// #5AA8F0 — OpenAI sky blue. Codex logo + ring/bar fills.
    static let codex = Color(red: 90/255, green: 168/255, blue: 240/255)

    /// Google's four brand hues, official values. Antigravity's mark is a
    /// sweep through all four, so unlike every other provider its identity
    /// is a gradient rather than a single swatch — see `IslandGradient`.
    static let googleBlue = Color(red: 66/255, green: 133/255, blue: 244/255)
    static let googleGreen = Color(red: 52/255, green: 168/255, blue: 83/255)
    static let googleYellow = Color(red: 251/255, green: 188/255, blue: 5/255)
    static let googleRed = Color(red: 234/255, green: 67/255, blue: 53/255)

    /// Antigravity's stand-in for the places a gradient cannot go — shadow
    /// colours, chart series, anything typed `Color`. Google's own blue
    /// rather than the pale periwinkle this used to be, which read as a
    /// washed-out tint of nothing (owner review, 2026-08-09).
    static let antigravity = googleBlue

    /// #D8DEE4 — xAI monochrome. Grok strip fill + settings dot; a cool
    /// near-white so it sits beside terracotta and sky blue without
    /// introducing a fourth data hue.
    static let grok = Color(red: 216/255, green: 222/255, blue: 228/255)
    /// Cursor's brand is monochrome; a warm near-white keeps it legible on
    /// the dark base while staying apart from Grok's cool silver.
    static let cursor = Color(red: 245/255, green: 243/255, blue: 238/255)

    /// #3DD68C — live status dot. Sits next to cobalt without clashing.
    static let liveTeal = Color(red: 61/255, green: 214/255, blue: 140/255)

    /// The app's own chrome voice after the 2026-08-09 de-branding: Agent
    /// Island carries NO accent color of its own anymore. Selection,
    /// emphasis, toggles, chips — all speak white-on-black material; color
    /// on screen belongs to the providers' own marks and effects. Call
    /// sites keep their own opacities.
    static let chrome = Color.white

    /// #20C0B0 — survives ONLY as the "Teal" glow option in
    /// GlowColorStore, a user-facing choice. Never chrome, never data.
    static let brandTeal = Color(red: 32/255, green: 192/255, blue: 176/255)

    /// #8A63FF — glow-color option "Violet". Ambient glow only, never data.
    static let glowViolet = Color(red: 138/255, green: 99/255, blue: 255/255)

    /// #C7D3DF — glow-color option "Silver". A cool near-white; reads as a
    /// moonlit rim on the black silhouette. Ambient glow only, never data.
    static let glowSilver = Color(red: 199/255, green: 211/255, blue: 223/255)

    /// #F5A524 — approaching-limit warning tint. Reads as "amber" against
    /// the black silhouette without competing with the cobalt halo. Used
    /// for the static glow + peek pill accent at warning severity.
    static let alertAmber = Color(red: 245/255, green: 165/255, blue: 36/255)

    /// #E5484D — approaching-limit critical tint. Saturated enough to read
    /// as "stop, you're cooked" without going full red-alert pure.
    static let alertRed = Color(red: 229/255, green: 72/255, blue: 77/255)
}

/// Provider identity as a colour *ramp* rather than a single swatch.
///
/// Four of the five providers own one colour, so their ramp is that colour
/// twice and every call site can use the same gradient API. Antigravity is
/// the exception: Google's mark sweeps blue → green → yellow → red, and
/// painting it in one flat tint threw the brand away (owner review,
/// 2026-08-09 — "它的那个弹窗不是淡蓝色，是那种也是彩色的").
enum IslandGradient {
    /// Blue → green → yellow → red, the order Antigravity's mark runs them.
    static let google: [Color] = [
        IslandColor.googleBlue,
        IslandColor.googleGreen,
        IslandColor.googleYellow,
        IslandColor.googleRed,
    ]

    /// Closed loop for angular sweeps — without the repeated first stop an
    /// AngularGradient hard-cuts from red back to blue at 0°.
    static let googleWheel: [Color] = google + [IslandColor.googleBlue]

    static func linear(_ stops: [Color],
                       opacity: Double = 1,
                       from start: UnitPoint = .topLeading,
                       to end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(
            colors: stops.map { $0.opacity(opacity) },
            startPoint: start,
            endPoint: end
        )
    }
}

/// Shared chrome for the floating card windows (report cards, turn alarms).
/// One radius, one base coat — they must read as one family; 26 vs 18 with
/// two different blacks was the "your two popups don't even match" review
/// finding.
enum CardWindow {
    /// Continuous-corner radius for every floating card window.
    static let cornerRadius: CGFloat = 26

    /// #0E0F13 — near-black with a breath of luminance. A flat #000 window
    /// reads as a hole next to the report cards' lifted base.
    static let base = Color(red: 14/255, green: 15/255, blue: 19/255)
}
