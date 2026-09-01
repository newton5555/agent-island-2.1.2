import AppKit
import Foundation

/// Where a Claude sign-in link is sent. `.copyOnly` opens nothing — the
/// link goes to the pasteboard for accounts that live in no local browser
/// (a fresh or purchased account signs in via an incognito window instead).
enum ClaudeLoginBrowserTarget: Equatable {
    case systemDefault
    case chromiumProfile(appURL: URL, profileDirectory: String)
    case chromiumIncognito(appURL: URL)
    case copyOnly
}

/// One Chromium profile the sign-in link can be aimed at, with enough
/// identity (profile name + Google account email) for the user to recognize
/// which one holds their Claude session.
struct ChromiumBrowserProfile: Equatable, Hashable {
    let browserName: String
    let bundleID: String
    let appURL: URL
    let profileDirectory: String
    let displayName: String
    let email: String?
}

/// Answers "which browser window will the login link land in" BEFORE the
/// link is opened, so re-auth stops bouncing users into the wrong Google
/// profile. Detection is a read of each Chromium browser's `Local State`
/// JSON (profile names + account emails) plus Launch Services lookups —
/// no cookies are touched and nothing leaves the machine.
enum BrowserProfileResolver {
    struct DefaultBrowser: Equatable {
        let appURL: URL
        let name: String
    }

    struct InstalledChromium: Equatable {
        let name: String
        let bundleID: String
        let appURL: URL
    }

    struct LocalStateProfile: Equatable {
        let directory: String
        let displayName: String
        let email: String?
    }

    private struct ChromiumBrowser {
        let name: String
        let bundleID: String
        let supportSubdirectory: String
    }

    /// Order doubles as the incognito pick — first installed wins.
    private static let chromiumBrowsers = [
        ChromiumBrowser(name: "Chrome", bundleID: "com.google.Chrome", supportSubdirectory: "Google/Chrome"),
        ChromiumBrowser(name: "Edge", bundleID: "com.microsoft.edgemac", supportSubdirectory: "Microsoft Edge"),
        ChromiumBrowser(name: "Brave", bundleID: "com.brave.Browser", supportSubdirectory: "BraveSoftware/Brave-Browser"),
    ]

    static func defaultBrowser() -> DefaultBrowser? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return DefaultBrowser(appURL: appURL, name: FileManager.default.displayName(atPath: appURL.path))
    }

    /// Every profile of every installed Chromium browser. A browser whose
    /// app is gone (stale Application Support leftovers) contributes none.
    static func chromiumProfiles() -> [ChromiumBrowserProfile] {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [] }
        return chromiumBrowsers.flatMap { browser -> [ChromiumBrowserProfile] in
            guard let appURL = appURL(forBundleID: browser.bundleID) else { return [] }
            let localState = support
                .appendingPathComponent(browser.supportSubdirectory, isDirectory: true)
                .appendingPathComponent("Local State", isDirectory: false)
            return localStateProfiles(at: localState).map { profile in
                ChromiumBrowserProfile(
                    browserName: browser.name,
                    bundleID: browser.bundleID,
                    appURL: appURL,
                    profileDirectory: profile.directory,
                    displayName: profile.displayName,
                    email: profile.email
                )
            }
        }
    }

    static func firstInstalledChromium() -> InstalledChromium? {
        for browser in chromiumBrowsers {
            if let appURL = appURL(forBundleID: browser.bundleID) {
                return InstalledChromium(name: browser.name, bundleID: browser.bundleID, appURL: appURL)
            }
        }
        return nil
    }

    static func appURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func localStateProfiles(at url: URL) -> [LocalStateProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return localStateProfiles(in: data)
    }

    /// Parses `profile.info_cache` out of a Chromium `Local State` blob:
    /// `{directory: {name, gaia_name, user_name(=Google email), …}}`.
    /// Tolerant by design — a missing key, a non-object entry, or garbage
    /// JSON yields an empty/partial list, never a crash.
    static func localStateProfiles(in data: Data) -> [LocalStateProfile] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { directory, value -> LocalStateProfile? in
            guard let entry = value as? [String: Any] else { return nil }
            let name = nonEmpty(entry["name"])
            let gaiaName = nonEmpty(entry["gaia_name"])
            return LocalStateProfile(
                directory: directory,
                displayName: name ?? gaiaName ?? directory,
                email: nonEmpty(entry["user_name"])
            )
        }
        .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
