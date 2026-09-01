import SwiftUI

/// Locked type scale for AgentIsland. Eight tokens across six visual tiers,
/// no half-points. Hero numerics use SF Mono so the display digits — which
/// are the product's brand — have a developer-tool character that SF Pro
/// with `monospacedDigit()` can't deliver.
///
/// Tiers (largest to smallest):
///   38pt SF Mono semibold  — hero numerics (count-up dollar, big tokens)
///   18pt SF Mono semibold  — sub-hero (chart values)
///   15pt SF Mono semibold  — picker preview numerics
///   15pt SF Pro medium     — unit suffixes adjacent to hero ($, k, M, B)
///   14pt SF Pro semibold   — Settings brand wordmark
///   13pt SF Pro semibold   — provider titles ("Claude", "Codex")
///   13pt SF Pro medium     — Settings row titles
///   12pt SF Pro medium     — tab labels (a hair larger so they feel clickable)
///   11pt — body row
///       SF Mono semibold for inline numerics (bar dollars, sparkline overlay)
///       SF Pro medium for window labels ("Today", "Apr")
///       SF Pro semibold for buttons ("Refresh", "Check")
///   10pt — micro row
///       SF Mono regular for caption (reset glyph "↻ 5h", "synced 2m ago")
///       SF Pro medium for sub-bar labels and picker tile labels
///       SF Pro semibold for tracked-uppercase section labels
///   9pt SF Mono bold tracked — chips (MAX / PRO / PLUS)
///
/// White-text opacity ladder (combine freely with any tier):
///   1.00  primary value
///   0.78  chip text
///   0.55  labels
///   0.40  secondary captions
///   0.32  tertiary
///   0.18  hints
///   0.06  hairlines
enum Typography {
    // MARK: - Numerics (SF Rounded, tabular digits)
    // 2026-07-18 owner decision: SF Mono is retired from the ENTIRE scale —
    // every numeral included — the terminal face read as vibe coding, not
    // product. One voice now: SF Rounded (the face the report cards already
    // made the brand), with monospacedDigit() keeping live numbers steady.

    static let bigNumber     = Font.system(size: 38, weight: .bold, design: .rounded).monospacedDigit()
    static let chartValue    = Font.system(size: 18, weight: .bold, design: .rounded).monospacedDigit()
    static let previewNumber = Font.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()
    static let bodyNumber    = Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()

    // MARK: - Display text (SF Rounded)

    static let brand         = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let unit          = Font.system(size: 15, weight: .medium, design: .rounded)
    static let providerTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let rowTitle      = Font.system(size: 13, weight: .medium, design: .rounded)
    static let tabLabel      = Font.system(size: 12, weight: .medium, design: .rounded)
    static let label         = Font.system(size: 11, weight: .medium, design: .rounded)
    static let button        = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let micro         = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let sectionLabel  = Font.system(size: 10.5, weight: .semibold, design: .rounded)

    // MARK: - Specialty

    static let caption = Font.system(size: 10, weight: .medium, design: .rounded)
    static let chip    = Font.system(size: 9, weight: .bold, design: .rounded).monospacedDigit()
}


/// Settings-surface voice: plain SF Pro, tighter and brighter than the
/// island's rounded brand face — the panel reads as a tool, the island
/// and report cards keep the rounded identity the owner locked 2026-07-18.
enum SettingsType {
    static let pageTitle = Font.system(size: 22, weight: .bold)
    static let rowTitle  = Font.system(size: 13, weight: .medium)
    static let data      = Font.system(size: 11.5, weight: .regular).monospacedDigit()
    static let tabLabel  = Font.system(size: 12, weight: .medium)
    static let section   = Font.system(size: 10.5, weight: .semibold)
}
