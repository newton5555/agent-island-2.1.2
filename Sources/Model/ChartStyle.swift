import SwiftUI

// Sparkline retired 2026-07-17 (owner call: 折线图太丑,直接删掉). A saved
// "spark" preference fails rawValue decoding and lands on the default.
// Declaration order IS the picker/cycle order — stepped leads (owner call);
// "ring" kept as the stored rawValue for the solid pie so prefs survive.
enum ChartStyle: String, CaseIterable {
    case stepped, bar, ring, numeric

    var label: String {
        switch self {
        case .stepped: L10n.tr("Stepped")
        case .bar: L10n.tr("Bar")
        case .ring: L10n.tr("Pie")
        case .numeric: L10n.tr("Numeric")
        }
    }
}

@MainActor
final class StylePref: StylePreferenceStore<ChartStyle> {
    static let shared = StylePref()

    private init() {
        super.init(
            styleKey: "AgentIsland.chartStyle",
            cycledKey: "AgentIsland.hasCycledStyle",
            // Stepped is the owner-picked default (1.7.2 planning).
            defaultStyle: .stepped
        )
    }
}
