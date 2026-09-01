import Foundation

/// Display-layer provider identity for the island's two silhouette slots.
/// Strictly a presentation concept: the alert/transcript domain keeps its
/// two-provider `AlertEngine.Provider` — only claude/codex map back into it
/// and get full monitoring (usage windows, turn alarms, attention states).
/// Gemini/Grok slots are usage badges: logo + quota pill, nothing deeper.
enum DisplayProvider: String, CaseIterable, Codable {
    case claude
    case codex
    case antigravity
    case grok
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .antigravity: return "Antigravity"
        case .grok:   return "Grok"
        case .cursor: return "Cursor"
        }
    }

    /// Full monitoring = official usage windows + transcript activity +
    /// approaching-limit alerts. Badge-only providers report quota and stop.
    var hasFullMonitoring: Bool {
        switch self {
        case .claude, .codex: return true
        case .antigravity, .grok, .cursor: return false
        }
    }

    /// Which flank the logo holds in the solo layout (the pill crosses to
    /// the opposite side — owner's solo-layout call, 2026-07-16). Claude's
    /// historical home is the left tab, Codex's the right; the guests get
    /// stable assignments so the layout never flips between launches.
    var soloLogoFlankIsLeading: Bool {
        switch self {
        case .claude, .antigravity, .cursor: return true
        case .codex, .grok:             return false
        }
    }

    /// Canonical slot order: Claude before Codex before the guests, matching
    /// the pre-1.8.1 fixed layout so migrated users see zero movement.
    var slotOrder: Int {
        Self.allCases.firstIndex(of: self) ?? .max
    }
}

/// Pure selection rules for the island's two slots — no singletons, no
/// UserDefaults, so the max-2 constraint, the legacy migration, and the
/// persistence round-trip stay unit-testable (same split as AlertDecision).
enum ProviderSelection {
    static let maxEnabled = 2

    /// Decode a persisted raw list: unknown values drop, duplicates drop,
    /// canonical order is restored, anything past the cap is discarded.
    static func sanitize(_ raw: [String]) -> [DisplayProvider] {
        var seen: Set<DisplayProvider> = []
        var out: [DisplayProvider] = []
        for value in raw {
            // Google shut Gemini Code Assist for individuals on 2026-06-18 and
            // pointed those users at Antigravity, so the slot moved with them.
            // Without this hop a stored "gemini" would fail to decode and the
            // user would silently lose the choice they made.
            let name = value == "gemini" ? DisplayProvider.antigravity.rawValue : value
            guard let provider = DisplayProvider(rawValue: name),
                  !seen.contains(provider) else { continue }
            seen.insert(provider)
            out.append(provider)
        }
        return Array(out.sorted { $0.slotOrder < $1.slotOrder }.prefix(maxEnabled))
    }

    enum ToggleOutcome: Equatable {
        case updated([DisplayProvider])
        /// Turning on a third provider — refuse and explain, never evict.
        case refusedLimit
    }

    static func toggling(
        _ current: [DisplayProvider],
        _ provider: DisplayProvider
    ) -> ToggleOutcome {
        if current.contains(provider) {
            return .updated(current.filter { $0 != provider })
        }
        guard current.count < maxEnabled else { return .refusedLimit }
        return .updated((current + [provider]).sorted { $0.slotOrder < $1.slotOrder })
    }

    /// First-run migration from the pre-1.8.1 per-provider toggles. Grok's old
    /// toggle governed the panel guest strip, never an island slot, so only
    /// the claude/codex pair carries over — existing users keep exactly the
    /// island they had.
    static func migrated(claudeVisible: Bool, codexVisible: Bool) -> [DisplayProvider] {
        var out: [DisplayProvider] = []
        if claudeVisible { out.append(.claude) }
        if codexVisible { out.append(.codex) }
        return out
    }
}
