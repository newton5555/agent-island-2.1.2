import Foundation

/// Pure logic for locating the Claude login among keychain items, split
/// from `ClaudeCredentials` so it compiles alone under test.
///
/// Claude Code 2.x renamed its keychain item: account credentials now land
/// under "Claude Code-credentials-<8 hex>" (a per-config sha256 suffix),
/// while our own web login and pre-2.x CLIs write the unsuffixed name. The
/// suffixed prefix is ALSO where per-config MCP OAuth caches live, so the
/// name alone doesn't identify the login — an entry counts only when it
/// parses as `claudeAiOauth` with a token pair, and the freshest
/// `expiresAt` wins when several accounts have left entries behind
/// (observed 2026-08-08: a dozen stale suffixed entries on one machine,
/// none of them the login).
enum ClaudeKeychainDiscovery {
    static let baseService = "Claude Code-credentials"

    /// Line-parse of `security dump-keychain` metadata output: collects
    /// unique service names carrying the suffixed credentials prefix.
    /// Metadata only — the dump never includes secrets.
    static func parseServiceNames(fromDump output: String) -> [String] {
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: "\"svce\"<blob>=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<end])
            if name.hasPrefix(baseService + "-") { names.insert(name) }
        }
        return names.sorted()
    }

    /// Freshest-wins pick among parsed candidates: the latest `expiresAt`
    /// takes the slot so a dead account's leftovers never shadow a live
    /// login.
    static func pickFreshest<T>(_ candidates: [(value: T, expiresAt: Double)]) -> T? {
        candidates.max(by: { $0.expiresAt < $1.expiresAt })?.value
    }
}
