import Foundation

@MainActor
final class CostPanelVisibilityStore: ObservableObject {
    static let shared = CostPanelVisibilityStore()

    private static let key = "AgentIsland.showCostPanelPage"

    @Published var showInTopPanel: Bool {
        didSet { UserDefaults.standard.set(showInTopPanel, forKey: Self.key) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            // Hidden by default: the cost page is a secondary retrospective view
            // that doesn't answer the app's core jobs (whose turn / how much quota
            // is left / when it resets). Anyone who wants it flips it back on in
            // Settings → "Show cost page in top panel".
            showInTopPanel = false
        } else {
            showInTopPanel = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
