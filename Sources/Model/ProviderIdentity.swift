import SwiftUI

/// One authority for "what does this provider look like" at the alarm/status
/// layer. Grew out of 2.1.1's five-wide session monitoring: a dozen
/// `provider == .claude ? A : B` ternaries each silently rendered Grok and
/// Gemini as Codex (wrong name in the alarm, wrong logo, wrong accent).
/// Every consumer now reads the same switch, so a sixth provider is one
/// case away and the compiler walks the call sites.
extension DisplayProvider {
    /// Bridge into the alarm/status domain. Both enums carry the same five
    /// members; the raw-value hop keeps them decoupled without a 5-arm
    /// switch to maintain twice.
    var alertProvider: AlertEngine.Provider {
        AlertEngine.Provider(rawValue: rawValue) ?? .claude
    }
}

extension TriggerTool {
    /// Trigger rows carry the same five identities; hop via raw value like
    /// the DisplayProvider bridge above.
    var accentColor: Color {
        (AlertEngine.Provider(rawValue: rawValue) ?? .claude).accent
    }
}

extension AlertEngine.Provider {
    /// Antigravity ships Google's four-colour gradient mark; every other
    /// provider ships a silhouette that only shows up once tinted. Passing
    /// `.original` also makes any `foregroundStyle` on that image a no-op,
    /// which is the point — three separate views were repainting Google's
    /// mark in one flat tint and erasing the brand (owner review,
    /// 2026-08-09).
    var logoRendering: Image.TemplateRenderingMode {
        self == .antigravity ? .original : .template
    }

    /// The provider's colour ramp. Single-colour brands repeat their one
    /// swatch so every consumer can render a gradient unconditionally
    /// instead of branching on "is this the multicolour one".
    var accentStops: [Color] {
        self == .antigravity ? IslandGradient.google : [accent, accent]
    }

    /// Near-white accents (Grok steel, Cursor bone) need a DARK label on
    /// accent-filled controls — white-on-bone made the alarm CTA unreadable.
    var accentIsLight: Bool {
        self == .grok || self == .cursor
    }

    func accentGradient(opacity: Double = 1,
                        from start: UnitPoint = .topLeading,
                        to end: UnitPoint = .bottomTrailing) -> LinearGradient {
        IslandGradient.linear(accentStops, opacity: opacity, from: start, to: end)
    }
}

extension DisplayProvider {
    var brandStops: [Color] { alertProvider.accentStops }

    func brandGradient(opacity: Double = 1,
                       from start: UnitPoint = .topLeading,
                       to end: UnitPoint = .bottomTrailing) -> LinearGradient {
        IslandGradient.linear(brandStops, opacity: opacity, from: start, to: end)
    }
}

extension AlertEngine.Provider {
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        }
    }

    var accent: Color {
        switch self {
        case .claude: return IslandColor.claude
        case .codex: return IslandColor.codex
        case .antigravity: return IslandColor.antigravity
        case .grok: return IslandColor.grok
        case .cursor: return IslandColor.cursor
        }
    }

    /// CLI executable name, nil where the product is app-only.
    var cliName: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        case .grok: return "grok"
        case .cursor: return nil
        }
    }
}
