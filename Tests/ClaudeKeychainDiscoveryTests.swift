import Foundation

/// Exercises the keychain-item discovery that heals the "auth required"
/// dead end after Claude Code 2.x moved logins to suffixed item names.
/// Fixture lines mirror real `security dump-keychain` metadata output.

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
    print("PASS \(message)")
    return true
}

// MARK: - Fixtures

private let dumpFixture = """
keychain: "/Users/u/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="u"
    "svce"<blob>="Claude Code-credentials-1a948339"
    "mdat"<timedate>=0x32303236303631363035333832375A00  "20260616053827Z\\000"
class: "genp"
attributes:
    "svce"<blob>="Claude Code-credentials-0499e89e"
class: "genp"
attributes:
    "svce"<blob>="Claude Code-credentials"
class: "genp"
attributes:
    "svce"<blob>="Suite App Safe Storage"
class: "genp"
attributes:
    "svce"<blob>="Claude Code-credentials-1a948339"
class: "genp"
attributes:
    "svce"<blob>="gh:github.com"
"""

/// A hostile value embedding the prefix inside a non-svce attribute line
/// must not register as a candidate.
private let spoofedFixture = """
    "acct"<blob>="Claude Code-credentials-deadbeef"
    "svce"<blob>="Other Service"
"""

// MARK: - Runner

@main
private struct Runner {
    static func main() {
        do {
            try expect(
                ClaudeKeychainDiscovery.parseServiceNames(fromDump: dumpFixture)
                    == ["Claude Code-credentials-0499e89e", "Claude Code-credentials-1a948339"],
                "parse collects suffixed names, dedupes, skips unsuffixed and foreign items")

            try expect(ClaudeKeychainDiscovery.parseServiceNames(fromDump: "").isEmpty,
                       "empty dump parses to no candidates")

            try expect(ClaudeKeychainDiscovery.parseServiceNames(fromDump: "garbage\nlines\nonly").isEmpty,
                       "garbage dump parses to no candidates")

            try expect(ClaudeKeychainDiscovery.parseServiceNames(fromDump: spoofedFixture).isEmpty,
                       "prefix inside a non-svce attribute does not count")

            try expect(ClaudeKeychainDiscovery.pickFreshest([(value: "a", expiresAt: 0)]) == "a",
                       "single candidate wins regardless of expiry")

            try expect(ClaudeKeychainDiscovery.pickFreshest([
                (value: "stale", expiresAt: 1_000),
                (value: "live", expiresAt: 2_000),
                (value: "old", expiresAt: 500),
            ]) == "live", "latest expiresAt wins")

            try expect(ClaudeKeychainDiscovery.pickFreshest([(value: String, expiresAt: Double)]()) == nil,
                       "no candidates picks nil")

            // Two revoked accounts, both expired: still returns the newer
            // one — the refresh path decides whether it is actually usable.
            try expect(ClaudeKeychainDiscovery.pickFreshest([
                (value: "older-dead", expiresAt: 100),
                (value: "newer-dead", expiresAt: 200),
            ]) == "newer-dead", "all-expired still yields the newest for the refresh attempt")

            print("ClaudeKeychainDiscoveryTests GREEN")
        } catch {
            fputs("ClaudeKeychainDiscoveryTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
