import SwiftUI

/// The island's ambient glow color — brand teal by default, with a small
/// curated set (owner's call, 2026-07-16: user-choosable, teal default).
/// This styles only the calm/ambient glow and the loading sweep; alert
/// amber/red and the attention pulse always override it.
@MainActor
final class GlowColorStore: ObservableObject {
    static let shared = GlowColorStore()

    enum Choice: String, CaseIterable {
        case teal, cobalt, violet, silver

        var color: Color {
            switch self {
            case .teal:   return IslandColor.brandTeal
            case .cobalt: return IslandColor.cobalt
            case .violet: return IslandColor.glowViolet
            case .silver: return IslandColor.glowSilver
            }
        }

        var label: String {
            switch self {
            case .teal:   return "Teal"
            case .cobalt: return "Cobalt"
            case .violet: return "Violet"
            case .silver: return "Silver"
            }
        }
    }

    private static let key = "AgentIsland.glowColor"

    @Published var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    var color: Color { choice.color }

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.key)
            .flatMap(Choice.init(rawValue:)) ?? .teal
    }
}
