import Foundation

/// How "Open thread" treats a Claude *Desktop* session: land in the Desktop
/// app (default), or resume the exact conversation in a terminal via
/// `claude --resume`. Desktop can't jump to a specific chat yet — the
/// `claude://code/<bridge-id>` route exists in its code but sits behind
/// Anthropic's server-side flag — so people who care more about "exact
/// conversation" than "my usual window" can pick the CLI here.
@MainActor
final class ClaudeJumpPreferenceStore: ObservableObject {
    static let shared = ClaudeJumpPreferenceStore()

    private static let key = "AgentIsland.claudeJumpPrefersCLI"

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
