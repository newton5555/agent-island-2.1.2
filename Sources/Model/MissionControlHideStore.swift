import Foundation

/// Opt-in "Hide in Mission Control". The island ships with `.stationary`
/// (pinned like the desktop, unaffected by Exposé) — on notched MacBooks
/// Mission Control drops its Spaces bar below the camera housing, so the
/// island never collides. External displays have no notch: the Spaces bar
/// hugs the top edge and the island covers it. Enabling this swaps
/// `.stationary` for `.transient`, whose documented behavior is exactly
/// "hidden by Exposé" — verified on-device: transient goes invisible for
/// the duration of Mission Control and returns untouched, while spaces
/// behavior (canJoinAllSpaces) is unaffected. Off by default because
/// transient windows ride along with space-switch animations, a visual
/// trade-off notch users don't need to pay.
@MainActor
final class MissionControlHideStore: ObservableObject {
    static let shared = MissionControlHideStore()

    private static let key = "AgentIsland.hideInMissionControl"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
    }
}
