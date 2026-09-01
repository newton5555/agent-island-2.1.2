import AppKit
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@discardableResult
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws -> Bool {
    guard condition() else { throw TestFailure.assertion(message) }
    return true
}

// MARK: - Fixtures

/// Shaped like a real Chrome `Local State`: extra top-level keys, a Chinese
/// profile name, an email-less entry, an empty-strings entry, and one
/// non-object entry that must be skipped rather than sink the whole parse.
private let multiProfileFixture = Data("""
{
  "browser": { "enabled_labs_experiments": [] },
  "profile": {
    "info_cache": {
      "Profile 10": { "name": "备用号", "gaia_name": "Bei Yong", "user_name": "beiyong@example.com" },
      "Default": { "name": "工作号", "gaia_name": "Tristan T", "user_name": "work@example.com", "is_ephemeral": false },
      "Profile 3": { "gaia_name": "Side Account" },
      "Profile 4": { "name": "", "user_name": "" },
      "System Profile": 42
    },
    "last_used": "Default"
  }
}
""".utf8)

private let corruptedFixture = Data("{ \"profile\": { \"info_cache\": {".utf8)

private let wrongShapeFixture = Data("{ \"profile\": { \"info_cache\": [1, 2, 3] } }".utf8)

// MARK: - Local State parsing

private func testMultiProfileParsing() throws {
    let profiles = BrowserProfileResolver.localStateProfiles(in: multiProfileFixture)
    try expect(profiles.count == 4, "4 object entries expected, got \(profiles.count)")
    try expect(profiles.map(\.directory) == ["Default", "Profile 3", "Profile 4", "Profile 10"],
               "directories must sort numerically with Default first, got \(profiles.map(\.directory))")

    let defaultProfile = profiles[0]
    try expect(defaultProfile.displayName == "工作号", "Chinese profile name must survive parsing")
    try expect(defaultProfile.email == "work@example.com", "user_name must surface as email")

    let gaiaOnly = profiles[1]
    try expect(gaiaOnly.displayName == "Side Account", "missing name must fall back to gaia_name")
    try expect(gaiaOnly.email == nil, "missing user_name must read as no email")

    let empty = profiles[2]
    try expect(empty.displayName == "Profile 4", "all-empty entry must fall back to the directory name")
    try expect(empty.email == nil, "empty user_name must read as no email")
}

private func testCorruptedJSONReturnsEmpty() throws {
    try expect(BrowserProfileResolver.localStateProfiles(in: corruptedFixture).isEmpty,
               "corrupted JSON must yield an empty list")
    try expect(BrowserProfileResolver.localStateProfiles(in: wrongShapeFixture).isEmpty,
               "info_cache of the wrong type must yield an empty list")
    try expect(BrowserProfileResolver.localStateProfiles(in: Data()).isEmpty,
               "empty data must yield an empty list")
}

private func testFileBackedParsingAndMissingFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("browser-profile-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let localState = dir.appendingPathComponent("Local State")
    try multiProfileFixture.write(to: localState)
    try expect(BrowserProfileResolver.localStateProfiles(at: localState).count == 4,
               "file-backed parse must match in-memory parse")

    let missing = dir.appendingPathComponent("Does Not Exist")
    try expect(BrowserProfileResolver.localStateProfiles(at: missing).isEmpty,
               "missing file must yield an empty list, not an error")
}

// MARK: - Target store persistence

private let testSuite = "agentisland-browser-profile-tests"

@MainActor
private func freshDefaults() throws -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: testSuite) else {
        throw TestFailure.assertion("could not create test defaults suite")
    }
    defaults.removePersistentDomain(forName: testSuite)
    return defaults
}

@MainActor
private func testStoreDefaultsToSystemDefault() throws {
    let defaults = try freshDefaults()
    let store = ClaudeLoginTargetStore(defaults: defaults)
    try expect(store.target == .systemDefault, "fresh store must default to the system browser")
}

@MainActor
private func testStoreRoundTripsEveryVariant() throws {
    let variants: [StoredClaudeLoginTarget] = [
        .chromiumProfile(bundleID: "com.google.Chrome", profileDirectory: "Profile 3"),
        .chromiumIncognito(bundleID: "com.brave.Browser"),
        .copyOnly,
        .systemDefault,
    ]
    for variant in variants {
        let defaults = try freshDefaults()
        ClaudeLoginTargetStore(defaults: defaults).target = variant
        let reloaded = ClaudeLoginTargetStore(defaults: defaults)
        try expect(reloaded.target == variant, "round trip must preserve \(variant)")
    }
}

@MainActor
private func testStoreSurvivesCorruptPersistedData() throws {
    let defaults = try freshDefaults()
    defaults.set(Data("not json".utf8), forKey: "AgentIsland.claudeLoginTarget")
    let store = ClaudeLoginTargetStore(defaults: defaults)
    try expect(store.target == .systemDefault, "corrupt persisted data must fall back to system default")
}

// MARK: - Resolution against the current machine

private let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")

private let knownProfiles = [
    ChromiumBrowserProfile(
        browserName: "Chrome",
        bundleID: "com.google.Chrome",
        appURL: chromeApp,
        profileDirectory: "Profile 3",
        displayName: "工作号",
        email: "work@example.com"
    )
]

@MainActor
private func testResolutionMapsAndFallsBack() throws {
    let defaults = try freshDefaults()
    let store = ClaudeLoginTargetStore(defaults: defaults)
    let resolveChrome: (String) -> URL? = { $0 == "com.google.Chrome" ? chromeApp : nil }

    store.target = .chromiumProfile(bundleID: "com.google.Chrome", profileDirectory: "Profile 3")
    try expect(
        store.resolvedTarget(profiles: knownProfiles, appURLForBundleID: resolveChrome)
            == .chromiumProfile(appURL: chromeApp, profileDirectory: "Profile 3"),
        "a still-present profile must resolve to its app URL"
    )

    store.target = .chromiumProfile(bundleID: "com.google.Chrome", profileDirectory: "Profile 99")
    try expect(
        store.resolvedTarget(profiles: knownProfiles, appURLForBundleID: resolveChrome) == .systemDefault,
        "a vanished profile must fall back to the system default"
    )

    store.target = .chromiumIncognito(bundleID: "com.google.Chrome")
    try expect(
        store.resolvedTarget(profiles: [], appURLForBundleID: resolveChrome)
            == .chromiumIncognito(appURL: chromeApp),
        "incognito must resolve through the bundle lookup"
    )

    store.target = .chromiumIncognito(bundleID: "com.brave.Browser")
    try expect(
        store.resolvedTarget(profiles: [], appURLForBundleID: resolveChrome) == .systemDefault,
        "incognito for an uninstalled browser must fall back to the system default"
    )

    store.target = .copyOnly
    try expect(
        store.resolvedTarget(profiles: [], appURLForBundleID: resolveChrome) == .copyOnly,
        "copy-only must survive resolution untouched"
    )
}

@main
private enum BrowserProfileResolverTestRunner {
    @MainActor
    static func main() {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("multi-profile Local State parses with fallbacks", testMultiProfileParsing),
            ("corrupted JSON yields empty list", testCorruptedJSONReturnsEmpty),
            ("file-backed parse + missing file", testFileBackedParsingAndMissingFile),
            ("store defaults to system default", testStoreDefaultsToSystemDefault),
            ("store round-trips every variant", testStoreRoundTripsEveryVariant),
            ("store survives corrupt persisted data", testStoreSurvivesCorruptPersistedData),
            ("resolution maps picks and falls back", testResolutionMapsAndFallsBack)
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("BrowserProfileResolverTests GREEN")
        } catch {
            fputs("BrowserProfileResolverTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
