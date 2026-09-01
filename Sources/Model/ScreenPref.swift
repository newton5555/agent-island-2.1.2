import Foundation

/// Which page of the expanded panel is currently active. Persisted across
/// launches so the app reopens on the last-viewed page.
@MainActor
final class ScreenPref: ObservableObject {
    static let shared = ScreenPref()

    enum Screen: String, CaseIterable {
        case usage
        case cost
        case overview

        var pageIndex: Int {
            Self.allCases.firstIndex(of: self) ?? 0
        }

        var pageLabel: String {
            switch self {
            case .usage:    return L10n.tr("Usage")
            case .cost:     return L10n.tr("Cost")
            case .overview: return L10n.tr("Overview")
            }
        }
    }

    private static let key = "AgentIsland.screen"
    private static let swipedKey = "AgentIsland.hasSwipedScreen"

    @Published var screen: Screen {
        didSet {
            UserDefaults.standard.set(screen.rawValue, forKey: Self.key)
            // Once the user has swiped between pages even once, we've made
            // our point — kill the discoverability peek in `PagedContent`.
            if oldValue != screen, !hasSwipedScreen { hasSwipedScreen = true }
        }
    }

    @Published var hasSwipedScreen: Bool {
        didSet { UserDefaults.standard.set(hasSwipedScreen, forKey: Self.swipedKey) }
    }

    private static let costDefaultMigration = "AgentIsland.defaultScreenCost.v1"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        // Cost is the default landing page (product call, 2026-07-13): the
        // money number is what people open the panel to see — and what they
        // share. One-time migration nudges existing users there too; their
        // swipes still persist afterwards.
        var initial = Screen(rawValue: raw) ?? .cost
        if !UserDefaults.standard.bool(forKey: Self.costDefaultMigration) {
            UserDefaults.standard.set(true, forKey: Self.costDefaultMigration)
            if CostPanelVisibilityStore.shared.showInTopPanel {
                initial = .cost
                UserDefaults.standard.set(Screen.cost.rawValue, forKey: Self.key)
            }
        }
        self.screen = initial
        // Demo mode forces the discoverability peek to fire on every
        // launch so screen recordings always capture it. didSet does not
        // run for init assignments, so this never persists back to
        // UserDefaults — the real app's onboarding state is preserved.
        self.hasSwipedScreen = AppEnvironment.isDemo ? false : UserDefaults.standard.bool(forKey: Self.swipedKey)
    }

    var visibleScreens: [Screen] {
        // Auto-resume was deleted outright in 2.1.1 (owner call,
        // 2026-08-08, upgrading the 07-13 gating to a removal): the
        // engine, stores, pages, and settings are gone from the tree.
        if CostPanelVisibilityStore.shared.showInTopPanel {
            return [.usage, .cost, .overview]
        }
        return [.usage, .overview]
    }

    var visiblePageIndex: Int {
        visibleScreens.firstIndex(of: screen) ?? 0
    }

    func ensureVisibleScreen() {
        guard !visibleScreens.contains(screen) else { return }
        screen = .usage
    }

    /// Edge-clamped carousel — swiping past the rightmost page does
    /// nothing (no wrap to page 1), and likewise for the leftmost page.
    /// Matches the iOS Home Screen rubber-band feel where the user
    /// understands they've hit a boundary instead of teleporting around.
    func advance() {
        let pages = visibleScreens
        let index = visiblePageIndex
        guard index < pages.count - 1 else { return }
        screen = pages[index + 1]
    }

    func rewind() {
        let pages = visibleScreens
        let index = visiblePageIndex
        guard index > 0 else { return }
        screen = pages[index - 1]
    }
}
