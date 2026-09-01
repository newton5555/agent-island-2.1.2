import Foundation

enum TriggerTool: String, Codable, CaseIterable {
    case claude
    case codex
    case antigravity
    case grok
    case cursor

    var display: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        }
    }

}

/// Resolves CLI binaries by probing known install locations. LaunchServices
/// hands GUI apps a stripped PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so a
/// `which` call would miss every Homebrew/nvm/Bun install — same reasoning as
/// `ClaudeCredentials.locateClaudeBinary`.
enum CLILocator {
    static func path(for tool: TriggerTool) -> String? {
        switch tool {
        case .claude: return locate("claude")
        case .codex: return locate("codex")
        case .antigravity: return locate("agy") ?? locate("antigravity-cli")
        case .grok: return locate("grok")
        case .cursor: return nil
        }
    }

    private static func locate(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            // hermes-managed npm prefix (owner's machine): global CLIs land
            // here, invisible to every conventional prefix above.
            "\(home)/.hermes/node/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
