import Foundation
import Security

/// How Antigravity is signed in on this machine.
///
/// This is NOT the Gemini CLI's file layout, which is what the first cut of
/// this file assumed. Verified against a real install (2026-08-08): the
/// Antigravity CLI keeps its data under `~/.gemini/antigravity-cli/` and
/// stores the OAuth token in the **login keychain** (service `gemini`,
/// account `antigravity`) — it writes no `oauth_creds.json` at all. The
/// `~/.gemini/oauth_creds.json` that may sit alongside belongs to the
/// separate Gemini CLI product and must not be read as Antigravity's.
enum AntigravityAuthDetection: Equatable {
    /// No Antigravity footprint at all — zero-intrusion, show nothing.
    case notInstalled
    /// A data root exists but no credential — installed, sign-in not done.
    case signedOut
    /// A credential is present.
    case signedIn
}

/// Parsed `~/.gemini/antigravity-ide/oauth_creds.json`. `expiry_date` is epoch milliseconds
/// (the CLI writes `Date.now() + expires_in * 1000`).
struct AntigravityOAuthCreds: Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiryDate: Date?

    var email: String? { idToken.flatMap(GeminiJWT.email(fromIDToken:)) }
}

/// Reader/refresher for the Gemini CLI credential + settings files. Mirrors
/// `GrokAuthFile`'s contract: refresh results MUST be written back (the CLI
/// reads the same file), writes are atomic (tmp file created 0600 in the
/// same directory, then rename(2)), and every field this app doesn't
/// understand is preserved.
enum AntigravityCredentials {
    /// Google has renamed this directory twice (1.x `antigravity`, 2.x
    /// `antigravity-ide`) and the CLI keeps a third root, so all three are
    /// probed rather than one hardcoded guess. CLI first: it is the root
    /// that exists on a plain `brew install antigravity-cli` machine.
    static let rootNames = ["antigravity-cli", "antigravity-ide", "antigravity"]

    static func dataRoots() -> [URL] {
        let base = URL(fileURLWithPath: NSString("~/.gemini").expandingTildeInPath,
                       isDirectory: true)
        return rootNames
            .map { base.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func homeDirectory() -> URL {
        dataRoots().first
            ?? URL(fileURLWithPath: NSString("~/.gemini/antigravity-cli").expandingTildeInPath,
                   isDirectory: true)
    }

    static func settingsURL(home: URL = homeDirectory()) -> URL {
        home.appendingPathComponent("settings.json")
    }

    /// Only the IDE roots have ever written this file; the CLI uses the
    /// keychain. Returns the first root that actually has one so the quota
    /// fetcher reads a real file instead of a guessed path.
    static func credsURL(home: URL? = nil) -> URL {
        if let home { return home.appendingPathComponent("oauth_creds.json") }
        let named = dataRoots().map { $0.appendingPathComponent("oauth_creds.json") }
        return named.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? homeDirectory().appendingPathComponent("oauth_creds.json")
    }

    /// Attributes-only keychain probe. Deliberately omits `kSecReturnData`:
    /// asking for the secret itself triggers the "wants to access your
    /// keychain" dialog, and this runs on every refresh tick. Measured at
    /// 9ms with no prompt on the owner's machine (2026-08-08).
    static func hasKeychainCredential(service: String = "gemini",
                                      account: String = "antigravity") -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    static func detect() -> AntigravityAuthDetection {
        detect(roots: dataRoots(), keychainCredential: hasKeychainCredential())
    }

    /// Split out so tests can drive both inputs; the keychain half is not
    /// reachable from a fixture directory.
    static func detect(roots: [URL], keychainCredential: Bool) -> AntigravityAuthDetection {
        let installed = roots.contains { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
        }
        // The IDE roots write oauth_creds.json; the CLI uses the keychain.
        // Either one proves a signed-in account.
        let fileCredential = roots.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("oauth_creds.json").path)
        }
        if keychainCredential || fileCredential { return .signedIn }
        return installed ? .signedOut : .notInstalled
    }

    static func loadCreds(from url: URL) -> AntigravityOAuthCreds? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = nonEmpty(root["access_token"]) else { return nil }
        return AntigravityOAuthCreds(
            accessToken: accessToken,
            refreshToken: nonEmpty(root["refresh_token"]),
            idToken: nonEmpty(root["id_token"]),
            expiryDate: parseExpiry(root["expiry_date"])
        )
    }

    /// Refresh a minute early so an in-flight request never races the clock.
    static func needsRefresh(_ creds: AntigravityOAuthCreds,
                             now: Date = Date(),
                             skew: TimeInterval = 60) -> Bool {
        guard let expiryDate = creds.expiryDate else { return false }
        return now.addingTimeInterval(skew) >= expiryDate
    }

    /// Apply a Google token response (`access_token` / `expires_in` seconds,
    /// occasionally a fresh `id_token`) to oauth_creds.json and persist.
    /// Returns the updated creds, or nil when nothing was written — the
    /// caller keeps using its in-memory token.
    @discardableResult
    static func applyRefreshResponse(_ data: Data,
                                     to url: URL,
                                     now: Date = Date()) -> AntigravityOAuthCreds? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = nonEmpty(response["access_token"]) else { return nil }

        guard let fileData = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] else {
            return nil
        }

        root["access_token"] = accessToken
        if let expiresIn = seconds(response["expires_in"]), expiresIn > 0 {
            root["expiry_date"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        }
        if let rotatedRefresh = nonEmpty(response["refresh_token"]) {
            root["refresh_token"] = rotatedRefresh
        }
        if let freshIDToken = nonEmpty(response["id_token"]) {
            root["id_token"] = freshIDToken
        }

        guard let output = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".oauth_creds.json.tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: output,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return AntigravityOAuthCreds(
            accessToken: accessToken,
            refreshToken: nonEmpty(root["refresh_token"]),
            idToken: nonEmpty(root["id_token"]),
            expiryDate: parseExpiry(root["expiry_date"])
        )
    }

    /// `expiry_date` is epoch milliseconds on current CLI logins; tolerate
    /// epoch seconds from other writer versions.
    static func parseExpiry(_ value: Any?) -> Date? {
        if let raw = value as? Double {
            return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
        }
        if let raw = value as? Int {
            return parseExpiry(Double(raw))
        }
        return nil
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let raw = value as? Double { return raw }
        if let raw = value as? Int { return TimeInterval(raw) }
        if let raw = value as? String { return TimeInterval(raw) }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        return raw
    }
}

/// Minimal JWT payload reader — enough to pull the account email out of the
/// Google `id_token` without any signature verification (we only display it).
enum GeminiJWT {
    static func payload(fromJWT jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func email(fromIDToken idToken: String) -> String? {
        guard let email = payload(fromJWT: idToken)?["email"] as? String,
              !email.isEmpty else { return nil }
        return email
    }
}

/// Google OAuth client id/secret for the token-refresh call. Google ships
/// them inside the Gemini CLI itself (`oauth2.js`), so we extract them from
/// the local install at runtime instead of hardcoding another product's
/// credentials into this binary.
struct GeminiClientCredentials: Equatable {
    let clientID: String
    let clientSecret: String
}

enum GeminiClientExtractor {
    static let clientIDEnvKey = "GEMINI_OAUTH_CLIENT_ID"
    static let clientSecretEnvKey = "GEMINI_OAUTH_CLIENT_SECRET"
    private static let binaryEnvKeys = ["GEMINI_PATH", "GEMINI_CLI_PATH"]
    private static let coreRelativePath =
        "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"

    /// Regex pull of `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` from the CLI's
    /// oauth2.js (or any bundle chunk that inlines the same constants).
    static func extract(fromOAuth2JS content: String) -> GeminiClientCredentials? {
        guard let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*["']([^"']+)["']"#, in: content),
              let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*["']([^"']+)["']"#, in: content)
        else { return nil }
        return GeminiClientCredentials(clientID: id, clientSecret: secret)
    }

    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> GeminiClientCredentials? {
        guard let id = env[clientIDEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = env[clientSecretEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return GeminiClientCredentials(clientID: id, clientSecret: secret)
    }

    /// Env override first, then the local gemini-cli install.
    static func resolve() -> GeminiClientCredentials? {
        if let fromEnv = fromEnvironment() { return fromEnv }
        guard let jsURL = locateOAuth2JS(),
              let content = try? String(contentsOf: jsURL, encoding: .utf8) else { return nil }
        return extract(fromOAuth2JS: content)
    }

    /// Walk up from the resolved `agy` binary looking for the CLI package
    /// in its three shipped layouts (direct core install, npm-style nested
    /// package, Homebrew libexec), then fall back to the fixed Homebrew
    /// package roots for setups where the binary itself isn't findable.
    static func locateOAuth2JS(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let binary = locateGeminiBinary(env: env),
           let near = oauth2JS(nearBinary: binary) {
            return near
        }
        let home = NSString("~").expandingTildeInPath
        let packageRoots = [
            "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli",
            "/usr/local/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli",
            "\(home)/.local/lib/node_modules/@google/gemini-cli",
        ]
        for root in packageRoots {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(coreRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func locateGeminiBinary(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for key in binaryEnvKeys {
            if let raw = env[key], !raw.isEmpty,
               isExecutableFile(raw) {
                return URL(fileURLWithPath: raw)
            }
        }
        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                let candidate = "\(dir)/agy"
                if isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        let home = NSString("~").expandingTildeInPath
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/gemini",
            "/usr/bin/gemini",
        ]
        for candidate in candidates where isExecutableFile(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func oauth2JS(nearBinary binary: URL) -> URL? {
        let resolved = binary.resolvingSymlinksInPath()
        var dir = resolved.deletingLastPathComponent()
        for _ in 0..<8 {
            let relatives = [
                coreRelativePath,
                "@google/gemini-cli/\(coreRelativePath)",
                "lib/node_modules/@google/gemini-cli/\(coreRelativePath)",
                "libexec/lib/node_modules/@google/gemini-cli/\(coreRelativePath)",
            ]
            for relative in relatives {
                let candidate = dir.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func firstMatch(_ pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
              ),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let value = String(content[range])
        return value.isEmpty ? nil : value
    }
}
