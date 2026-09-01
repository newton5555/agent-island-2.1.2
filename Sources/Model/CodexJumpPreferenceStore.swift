import Foundation

/// How "Open thread" treats a Codex session: deep-link into the desktop
/// app's exact thread (default — `codex://threads/<id>` is the app's own
/// official route), or reopen the conversation in a terminal via
/// `codex resume`, for people who live in the CLI.
@MainActor
final class CodexJumpPreferenceStore: ObservableObject {
    static let shared = CodexJumpPreferenceStore()

    private static let key = "AgentIsland.codexJumpPrefersCLI"

    @Published var prefersCLI: Bool {
        didSet { UserDefaults.standard.set(prefersCLI, forKey: Self.key) }
    }

    private init() {
        // The picker is gone from Settings (2026-07-14) — desktop app is
        // the one behavior. The stored value is ignored, not erased, so
        // the picker can return without losing anyone's old choice.
        prefersCLI = false
    }
}
