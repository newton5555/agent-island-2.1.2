import AppKit
import Foundation

/// Durable form of the user's sign-in destination pick. Persists bundle ID +
/// profile directory rather than an app path, so the pick survives the app
/// moving and can be re-validated against today's machine on every use.
enum StoredClaudeLoginTarget: Codable, Equatable {
    case systemDefault
    case chromiumProfile(bundleID: String, profileDirectory: String)
    case chromiumIncognito(bundleID: String)
    case copyOnly
}

/// Remembers where the last Claude re-auth was aimed so the next one (and
/// the usage-panel button, which has no menu) reuses it.
@MainActor
final class ClaudeLoginTargetStore: ObservableObject {
    static let shared = ClaudeLoginTargetStore()

    private static let key = "AgentIsland.claudeLoginTarget"
    private let defaults: UserDefaults

    @Published var target: StoredClaudeLoginTarget {
        didSet {
            guard let data = try? JSONEncoder().encode(target) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// `defaults` is injectable so tests round-trip against an isolated
    /// suite instead of the app domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(StoredClaudeLoginTarget.self, from: data) {
            target = stored
        } else {
            target = .systemDefault
        }
    }

    /// Maps the remembered pick onto the current machine. A browser that was
    /// uninstalled or a profile that no longer exists falls back to the
    /// system default instead of launching Chromium into a ghost profile.
    func resolvedTarget(
        profiles: [ChromiumBrowserProfile],
        appURLForBundleID: (String) -> URL?
    ) -> ClaudeLoginBrowserTarget {
        switch target {
        case .systemDefault:
            return .systemDefault
        case .copyOnly:
            return .copyOnly
        case .chromiumProfile(let bundleID, let profileDirectory):
            guard let match = profiles.first(where: {
                $0.bundleID == bundleID && $0.profileDirectory == profileDirectory
            }) else { return .systemDefault }
            return .chromiumProfile(appURL: match.appURL, profileDirectory: match.profileDirectory)
        case .chromiumIncognito(let bundleID):
            guard let appURL = appURLForBundleID(bundleID) else { return .systemDefault }
            return .chromiumIncognito(appURL: appURL)
        }
    }

    func resolvedTarget() -> ClaudeLoginBrowserTarget {
        resolvedTarget(
            profiles: BrowserProfileResolver.chromiumProfiles(),
            appURLForBundleID: BrowserProfileResolver.appURL(forBundleID:)
        )
    }
}
