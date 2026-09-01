import Foundation

/// User preference for keeping the peek-state percentage pills visible at
/// rest, without requiring a hover.
///
/// Default off: the pills only appear during hover/peek, then collapse with
/// the silhouette back to compact. With this on, the island launches into
/// `.peek` and stays there — hover-out keeps the pill visible, expanded-out
/// returns to peek instead of compact.
@MainActor
final class AlwaysShowUsageStore: ObservableObject {
    static let shared = AlwaysShowUsageStore()

    private static let key = "AgentIsland.alwaysShowUsage"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        // Default ON (owner call, 1.7.2 planning: 用量显示必须默认打开).
        // Users who explicitly turned it off keep their choice.
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            self.enabled = true
        } else {
            self.enabled = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
