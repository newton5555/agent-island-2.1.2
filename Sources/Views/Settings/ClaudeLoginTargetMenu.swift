import SwiftUI

/// Everything the sign-in target picker needs to know about this machine,
/// loaded in one shot when the Providers tab appears. Detection reads each
/// Chromium browser's Local State plus Launch Services — never cookies,
/// never the network.
struct ClaudeLoginDetection: Equatable {
    var defaultBrowser: BrowserProfileResolver.DefaultBrowser?
    var profiles: [ChromiumBrowserProfile]
    var incognitoApp: BrowserProfileResolver.InstalledChromium?

    static let empty = ClaudeLoginDetection(defaultBrowser: nil, profiles: [], incognitoApp: nil)

    static func detect() -> ClaudeLoginDetection {
        if AppEnvironment.demoGuestFixturesEnabled {
            let bundleID = "com.google.Chrome"
            let appURL = BrowserProfileResolver.appURL(forBundleID: bundleID)
                ?? URL(fileURLWithPath: "/Applications/Google Chrome.app")
            let profiles = [
                ChromiumBrowserProfile(
                    browserName: "Chrome",
                    bundleID: bundleID,
                    appURL: appURL,
                    profileDirectory: "Default",
                    displayName: "Default",
                    email: nil
                ),
                ChromiumBrowserProfile(
                    browserName: "Chrome",
                    bundleID: bundleID,
                    appURL: appURL,
                    profileDirectory: "Profile 1",
                    displayName: "Work",
                    email: nil
                ),
                ChromiumBrowserProfile(
                    browserName: "Chrome",
                    bundleID: bundleID,
                    appURL: appURL,
                    profileDirectory: "Profile 3",
                    displayName: "Personal",
                    email: nil
                ),
            ]
            return ClaudeLoginDetection(
                defaultBrowser: BrowserProfileResolver.DefaultBrowser(appURL: appURL, name: "Chrome"),
                profiles: profiles,
                incognitoApp: BrowserProfileResolver.InstalledChromium(
                    name: "Chrome",
                    bundleID: bundleID,
                    appURL: appURL
                )
            )
        }
        return ClaudeLoginDetection(
            defaultBrowser: BrowserProfileResolver.defaultBrowser(),
            profiles: BrowserProfileResolver.chromiumProfiles(),
            incognitoApp: BrowserProfileResolver.firstInstalledChromium()
        )
    }
}

extension ChromiumBrowserProfile {
    /// "Chrome · 工作号 (work@example.com)" — enough identity to spot the
    /// profile that actually holds the claude.ai session.
    var pickerLabel: String {
        let base = "\(browserName) · \(displayName)"
        guard let email else { return base }
        return "\(base) (\(email))"
    }
}

/// Chevron half of the split re-auth control: lists everywhere the sign-in
/// link could land (detected default browser, each Chromium profile with
/// its Google account, an incognito window for accounts that live in no
/// local browser, or copy-the-link), remembers the pick, and starts the
/// login right away. The Re-authenticate pill next to it reuses the
/// remembered pick.
struct ClaudeLoginTargetMenu: View {
    let detection: ClaudeLoginDetection
    let startLogin: () -> Void

    @ObservedObject private var targetStore = ClaudeLoginTargetStore.shared

    var body: some View {
        Menu {
            Button(defaultBrowserLabel) { pick(.systemDefault) }
            if !detection.profiles.isEmpty {
                Divider()
                ForEach(detection.profiles, id: \.self) { profile in
                    Button(profile.pickerLabel) {
                        pick(.chromiumProfile(
                            bundleID: profile.bundleID,
                            profileDirectory: profile.profileDirectory
                        ))
                    }
                }
            }
            Divider()
            if let incognito = detection.incognitoApp {
                Button(L10n.tr("Incognito window (%@)", incognito.name)) {
                    pick(.chromiumIncognito(bundleID: incognito.bundleID))
                }
            }
            Button(L10n.tr("Copy login link")) { pick(.copyOnly) }
            Divider()
            Text(L10n.tr("Account not in any browser? Incognito gives it a clean sign-in"))
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.tr("Choose where the sign-in opens"))
    }

    private var defaultBrowserLabel: String {
        guard let name = detection.defaultBrowser?.name else { return L10n.tr("Default browser") }
        return L10n.tr("Default browser · %@", name)
    }

    private func pick(_ stored: StoredClaudeLoginTarget) {
        targetStore.target = stored
        startLogin()
    }
}
