import Foundation

/// How the usage tiles and peek pills present a quota window: percent
/// consumed ("73%") or percent still available ("27%"). Some people plan
/// around what's left, not what's spent — this flips every percent readout
/// in one place while the underlying data stays `usedPercent`.
@MainActor
final class QuotaDisplayModeStore: ObservableObject {
    static let shared = QuotaDisplayModeStore()

    private static let key = "AgentIsland.quotaShowsRemaining"

    @Published var showsRemaining: Bool {
        didSet { UserDefaults.standard.set(showsRemaining, forKey: Self.key) }
    }

    private init() {
        showsRemaining = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// 0-100 display value for a window, honoring the mode.
    func displayValue(usedPercent: Double) -> Double {
        let used = usedPercent * 100
        return showsRemaining ? max(0, 100 - used) : used
    }
}
