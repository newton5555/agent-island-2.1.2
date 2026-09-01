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

private func base64URL(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Structurally real JWT (header.payload.signature), unsigned like the test
/// only needs — the app never verifies signatures on the id_token.
private let fixtureIDToken = [
    base64URL(#"{"alg":"RS256","typ":"JWT"}"#),
    base64URL(#"{"iss":"https://accounts.google.com","email":"tester@gmail.com","hd":null}"#),
    "sig",
].joined(separator: ".")

private func fixtureCredsJSON(expiryMs: Int) -> String {
    """
    {
      "access_token": "old-access-token",
      "refresh_token": "old-refresh-token",
      "scope": "https://www.googleapis.com/auth/cloud-platform openid",
      "token_type": "Bearer",
      "id_token": "\(fixtureIDToken)",
      "expiry_date": \(expiryMs)
    }
    """
}

private func makeTempGeminiHome(
    credsExpiryMs: Int? = 1_785_888_020_774,
    settingsJSON: String? = nil
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let credsExpiryMs {
        let url = dir.appendingPathComponent("oauth_creds.json")
        try fixtureCredsJSON(expiryMs: credsExpiryMs).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    if let settingsJSON {
        let url = dir.appendingPathComponent("settings.json")
        try settingsJSON.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

// MARK: - Settings / detection

/// The CLI ships no `oauth_creds.json` — its token lives in the keychain —
/// so a data root alone must read as signed-out, and the keychain item alone
/// (no creds file anywhere) must still read as signed-in. Getting this
/// backwards is exactly what left a freshly signed-in install showing "not
/// detected" (repro, 2026-08-08).
private func testDetectionStates() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-tests-missing-\(UUID().uuidString)", isDirectory: true)
    try expect(
        AntigravityCredentials.detect(roots: [missing], keychainCredential: false) == .notInstalled,
        "no data root and no keychain item must read as notInstalled")

    let bare = try makeTempGeminiHome(credsExpiryMs: nil)
    defer { try? FileManager.default.removeItem(at: bare) }
    try expect(
        AntigravityCredentials.detect(roots: [bare], keychainCredential: false) == .signedOut,
        "a CLI data root without any credential must read as signedOut, not notInstalled")
    try expect(
        AntigravityCredentials.detect(roots: [bare], keychainCredential: true) == .signedIn,
        "the keychain item alone must prove sign-in — the CLI writes no creds file")

    let withFile = try makeTempGeminiHome()
    defer { try? FileManager.default.removeItem(at: withFile) }
    try expect(
        AntigravityCredentials.detect(roots: [withFile], keychainCredential: false) == .signedIn,
        "an IDE root carrying oauth_creds.json must detect without the keychain")

    try expect(
        AntigravityCredentials.detect(roots: [], keychainCredential: true) == .signedIn,
        "a credential with no surviving data root still means a signed-in account")

    try expect(
        AntigravityCredentials.detect(roots: [missing, withFile], keychainCredential: false) == .signedIn,
        "one good root among several must be enough")
}

// MARK: - Quota
//
// Captured verbatim from the local language server on a signed-in account
// (agy 1.1.11, 2026-08-09). Two pools, both weekly — not the per-model
// Pro/Flash split the cloud-era code assumed.

private let realQuotaSummary = Data(#"""
{"response":{"groups":[{"displayName":"Gemini Models", "description":"Models within this group: Gemini Flash, Gemini Pro", "buckets":[{"bucketId":"gemini-weekly", "displayName":"Weekly Limit Remaining", "window":"weekly", "remainingFraction":0.9586032, "resetTime":"2026-08-16T02:00:27Z"}]}, {"displayName":"Claude and GPT models", "description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS", "buckets":[{"bucketId":"3p-weekly", "displayName":"Weekly Limit Remaining", "window":"weekly", "remainingFraction":1, "resetTime":"2026-08-16T07:33:07Z"}]}], "description":"Within each group, models share a weekly limit."}}
"""#.utf8)

private func testQuotaSummaryParsesRealPayload() throws {
    guard let parsed = AntigravityQuotaParser.parseQuotaSummary(realQuotaSummary) else {
        throw TestFailure.assertion("the real quota payload must parse")
    }
    try expect(parsed.buckets.count == 2, "both pools must survive, got \(parsed.buckets.count)")

    guard let gemini = parsed.buckets.first(where: { $0.bucketId == "gemini-weekly" }) else {
        throw TestFailure.assertion("gemini-weekly bucket missing")
    }
    // remainingFraction 0.9586032 is 4.14% consumed — the app speaks used%.
    try expect(abs(gemini.usedPercent - 0.0413968) < 1e-6,
               "remainingFraction must invert to used, got \(gemini.usedPercent)")
    try expect(gemini.shortLabel == "Gemini", "gemini pool short label")
    try expect(gemini.window == "weekly", "window must be carried")
    try expect(gemini.periodSeconds == 7 * 24 * 60 * 60,
               "a weekly bucket is a 7-day window — 24h was the Code Assist shape and made the island's elapsed arc wrong")
    try expect(gemini.resetAt != nil, "resetTime must parse")

    guard let third = parsed.buckets.first(where: { $0.bucketId == "3p-weekly" }) else {
        throw TestFailure.assertion("3p-weekly bucket missing")
    }
    try expect(third.usedPercent == 0, "a full pool is 0% used")
    try expect(third.shortLabel == "Claude·GPT", "3p pool gets a readable name, not the raw id")

    let snapshot = AntigravityQuotaSnapshot(
        buckets: parsed.buckets, tierID: nil, tierLabel: nil, note: parsed.note
    )
    try expect(snapshot.primary?.bucketId == "gemini-weekly",
               "the surfaced pool is Gemini's")
    // The 3p pool being MORE consumed must not steal the spot: Claude and
    // GPT are other providers' tiles in this app, so Antigravity surfaces
    // its Gemini pool regardless (owner call, 2026-08-09).
    let swapped = AntigravityQuotaSnapshot(
        buckets: [
            AntigravityQuotaBucket(bucketId: "3p-weekly", groupLabel: "Claude and GPT models",
                                   window: "weekly", usedPercent: 0.9, resetAt: nil),
            AntigravityQuotaBucket(bucketId: "gemini-weekly", groupLabel: "Gemini Models",
                                   window: "weekly", usedPercent: 0.1, resetAt: nil),
        ], tierID: nil, tierLabel: nil, note: nil
    )
    try expect(swapped.primary?.bucketId == "gemini-weekly",
               "a fuller 3p pool must not displace Gemini from the display")
    let no3p = AntigravityQuotaSnapshot(
        buckets: [AntigravityQuotaBucket(bucketId: "exotic-weekly", groupLabel: "Mystery",
                                         window: "weekly", usedPercent: 0.5, resetAt: nil)],
        tierID: nil, tierLabel: nil, note: nil
    )
    try expect(no3p.primary?.bucketId == "exotic-weekly",
               "an account with no Gemini pool still shows something rather than a blank")
    try expect(snapshot.note?.isEmpty == false, "Google's own explanation is carried through verbatim")
}

/// The tier must come off `userTier.name`. On the owner's free account
/// `planStatus.planInfo.planName` reads "Pro" — a field inherited from
/// Windsurf — so reading that would badge a free account as paid.
private func testUserStatusPrefersUserTierOverPlanName() throws {
    let payload = Data(#"""
    {"userStatus":{"name":"Tester","email":"tester@gmail.com",
      "userTier":{"id":"free-tier","name":"Antigravity Starter Quota"},
      "planStatus":{"planInfo":{"planName":"Pro","teamsTier":"TEAMS_TIER_PRO"}}}}
    """#.utf8)
    guard let profile = AntigravityQuotaParser.parseUserStatus(payload) else {
        throw TestFailure.assertion("user status must parse")
    }
    try expect(profile.tierLabel == "Antigravity Starter Quota",
               "tier must come from userTier.name, got \(profile.tierLabel ?? "nil")")
    try expect(profile.tierLabel != "Pro", "planInfo.planName must never win — it says Pro on a free account")
    try expect(profile.tierID == "free-tier", "tier id")
    try expect(profile.email == "tester@gmail.com", "email")
}

/// A bucket we cannot price must vanish, never render as full. Claiming 100%
/// headroom the account may not have is the exact dishonesty the publish gate
/// forbids.
private func testQuotaDegradesWithoutInventingHeadroom() throws {
    try expect(AntigravityQuotaParser.parseQuotaSummary(Data("not json".utf8)) == nil,
               "garbage must be nil, distinct from an empty answer")
    try expect(AntigravityQuotaParser.parseQuotaSummary(Data("{}".utf8))?.buckets.isEmpty == true,
               "a well-formed reply with no groups is zero buckets, not a failure")

    let missingFraction = Data(#"{"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a-weekly"}]}]}}"#.utf8)
    try expect(AntigravityQuotaParser.parseQuotaSummary(missingFraction)?.buckets.isEmpty == true,
               "a bucket with no remainingFraction must be dropped, never defaulted to 100% left")

    let disabled = Data(#"{"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a-weekly","disabled":true,"remainingFraction":1}]}]}}"#.utf8)
    try expect(AntigravityQuotaParser.parseQuotaSummary(disabled)?.buckets.isEmpty == true,
               "a disabled pool is one the account cannot use — showing it as full invents headroom")
}

/// The chip must sit beside PRO and MAX — "ANTIGRAVITY STARTER QUOTA" spans
/// the whole row (owner review, 2026-08-09).
private func testTierBadgeCompaction() throws {
    try expect(AntigravityQuotaParser.compactTierBadge(
                label: "Antigravity Starter Quota", tierID: "free-tier") == "STARTER",
               "the free tier compacts to STARTER")
    try expect(AntigravityQuotaParser.compactTierBadge(
                label: "Google AI Ultra", tierID: "g1-ultra-tier") == "AI ULTRA",
               "paid tiers keep the words that identify the plan")
    try expect(AntigravityQuotaParser.compactTierBadge(
                label: "Google AI Pro", tierID: nil) == "AI PRO",
               "AI Pro compacts")
    try expect(AntigravityQuotaParser.compactTierBadge(
                label: "Antigravity Quota", tierID: "free-tier") == "FREE",
               "all-filler names on the free tier fall back to FREE, never an empty chip")
    try expect(AntigravityQuotaParser.compactTierBadge(label: nil, tierID: "free-tier") == nil,
               "no label, no chip")
}

/// Envelope and number shapes this server has been seen to vary.
private func testQuotaToleratesShapeVariants() throws {
    let bare = Data(#"{"groups":[{"displayName":"G","buckets":[{"bucketId":"x-weekly","window":"weekly","remainingFraction":0.5}]}]}"#.utf8)
    try expect(AntigravityQuotaParser.parseQuotaSummary(bare)?.buckets.first?.usedPercent == 0.5,
               "groups at the root, with no response envelope, must still parse")

    let oneof = Data(#"{"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":{"case":"f","value":0.25}}]}]}}"#.utf8)
    guard let bucket = AntigravityQuotaParser.parseQuotaSummary(oneof)?.buckets.first else {
        throw TestFailure.assertion("oneof-expanded fraction must parse")
    }
    try expect(bucket.usedPercent == 0.75, "0.25 remaining is 75% used")
    try expect(bucket.periodSeconds == 5 * 60 * 60,
               "a 5h window (documented for paid tiers) must not be treated as weekly")

    let unknownPool = Data(#"{"response":{"groups":[{"displayName":"Mystery models","buckets":[{"bucketId":"zzz-weekly","remainingFraction":1}]}]}}"#.utf8)
    try expect(AntigravityQuotaParser.parseQuotaSummary(unknownPool)?.buckets.first?.shortLabel == "Mystery",
               "an unseen pool falls back to Google's group name, never a raw id")
}

/// The CLI wraps every user message in a `<USER_REQUEST>` envelope and then
/// appends metadata blocks; a raw label would show the tags and the machine's
/// local time. Shapes taken from a real transcript (2026-08-08).
private func testAntigravityRequestTextUnwrapsEnvelope() throws {
    let request = "Write a haiku about gravity, then explain why apples fall."
    let real = "<USER_REQUEST>\n\(request)\n"
        + "</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-08-08T22:01:06-04:00.\n"
        + "</ADDITIONAL_METADATA>"
    let label = SessionScanner.antigravityRequestText(real)
    try expect(label == String(request.prefix(48)),
               "the envelope and trailing metadata must be stripped, then clipped to 48")
    try expect(!(label ?? "").contains("USER_REQUEST"),
               "no envelope tag may leak into a label")
    try expect(!(label ?? "").contains("local time"),
               "the metadata block must never become the label")

    try expect(SessionScanner.antigravityRequestText("<USER_REQUEST>\n--output-format\n</USER_REQUEST>")
                == "--output-format",
               "a short request must survive intact")
    try expect(SessionScanner.antigravityRequestText("plain text, no envelope") == "plain text, no envelope",
               "a record without the envelope must still yield its text")
    try expect(SessionScanner.antigravityRequestText("<USER_REQUEST>\n\n</USER_REQUEST>") == nil,
               "an empty request must yield nil so the caller falls back")
    try expect(SessionScanner.antigravityRequestText("   \n  ") == nil,
               "whitespace must yield nil, never a blank label")
}

/// The roots are probed under ~/.gemini, and the CLI root is preferred —
/// pointing these at ~/.antigravity is what broke detection.
private func testDataRootNamesAndOrder() throws {
    try expect(AntigravityCredentials.rootNames.first == "antigravity-cli",
               "the CLI root must be probed first — it is the one a brew install creates")
    try expect(Set(AntigravityCredentials.rootNames)
                == ["antigravity-cli", "antigravity-ide", "antigravity"],
               "all three renamed roots must stay in the probe list")
    let home = AntigravityCredentials.homeDirectory().path
    try expect(home.contains("/.gemini/"),
               "roots live under ~/.gemini, never ~/.antigravity")
}

// MARK: - Credentials

private func testLoadCredsParsesFieldsAndEmail() throws {
    let home = try makeTempGeminiHome(credsExpiryMs: 1_785_888_020_774)
    defer { try? FileManager.default.removeItem(at: home) }

    let creds = AntigravityCredentials.loadCreds(from: AntigravityCredentials.credsURL(home: home))
    try expect(creds != nil, "fixture oauth_creds.json must load")
    try expect(creds?.accessToken == "old-access-token", "access_token must parse")
    try expect(creds?.refreshToken == "old-refresh-token", "refresh_token must parse")
    try expect(creds?.email == "tester@gmail.com", "email must decode from the id_token JWT")
    if let expiryDate = creds?.expiryDate {
        try expect(abs(expiryDate.timeIntervalSince1970 - 1_785_888_020.774) < 1,
                   "expiry_date must decode as epoch milliseconds")
    } else {
        try expect(false, "expiry_date must be present")
    }
}

private func testNeedsRefreshHonorsSkew() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func creds(expiringIn seconds: TimeInterval?) -> AntigravityOAuthCreds {
        AntigravityOAuthCreds(
            accessToken: "t",
            refreshToken: "r",
            idToken: nil,
            expiryDate: seconds.map { now.addingTimeInterval($0) }
        )
    }
    try expect(AntigravityCredentials.needsRefresh(creds(expiringIn: 30), now: now),
               "a token expiring inside the skew window must refresh")
    try expect(!AntigravityCredentials.needsRefresh(creds(expiringIn: 600), now: now),
               "a token with 10 minutes left must not refresh")
    try expect(!AntigravityCredentials.needsRefresh(creds(expiringIn: nil), now: now),
               "no expiry means no proactive refresh")
}

private func testApplyRefreshRewritesAtomicallyAndPreservesEverythingElse() throws {
    let home = try makeTempGeminiHome(credsExpiryMs: 1_000)
    defer { try? FileManager.default.removeItem(at: home) }
    let url = AntigravityCredentials.credsURL(home: home)
    let now = Date()
    let response = Data("""
    { "access_token": "new-access-token", "expires_in": 3599,
      "scope": "openid", "token_type": "Bearer" }
    """.utf8)

    let updated = AntigravityCredentials.applyRefreshResponse(response, to: url, now: now)
    try expect(updated != nil, "refresh writeback must succeed")
    try expect(updated?.accessToken == "new-access-token", "returned creds must carry the new token")
    try expect(updated?.refreshToken == "old-refresh-token",
               "an unrotated refresh token must survive the writeback")

    let raw = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        try expect(false, "rewritten oauth_creds.json must stay a JSON object")
        return
    }
    try expect(root["access_token"] as? String == "new-access-token",
               "access_token must be rewritten on disk")
    try expect(root["refresh_token"] as? String == "old-refresh-token",
               "refresh_token must be preserved on disk")
    try expect(root["scope"] as? String == "https://www.googleapis.com/auth/cloud-platform openid",
               "fields this app doesn't understand must survive")
    if let ms = root["expiry_date"] as? Double {
        let expected = (now.timeIntervalSince1970 + 3599) * 1000
        try expect(abs(ms - expected) < 2_000, "expiry_date must be rewritten as epoch milliseconds")
    } else {
        try expect(false, "expiry_date must remain a number")
    }

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    try expect(perms & 0o777 == 0o600, "rewritten oauth_creds.json must stay 0600")
}

private func testFailedRefreshLeavesFileUntouched() throws {
    let home = try makeTempGeminiHome(credsExpiryMs: 1_000)
    defer { try? FileManager.default.removeItem(at: home) }
    let url = AntigravityCredentials.credsURL(home: home)
    let before = try Data(contentsOf: url)

    let updated = AntigravityCredentials.applyRefreshResponse(
        Data(#"{ "error": "invalid_grant" }"#.utf8), to: url
    )
    try expect(updated == nil, "an error response must not report success")
    let after = try Data(contentsOf: url)
    try expect(before == after, "a failed refresh must leave oauth_creds.json byte-identical")
}

// MARK: - Client extraction

private func testClientExtractionRegex() throws {
    let doubleQuoted = """
    // license header
    export const OAUTH_CLIENT_ID = "681255809395-abc.apps.googleusercontent.com";
    export const OAUTH_CLIENT_SECRET = "GOCSPX-fixture-secret";
    """
    let extracted = GeminiClientExtractor.extract(fromOAuth2JS: doubleQuoted)
    try expect(extracted?.clientID == "681255809395-abc.apps.googleusercontent.com",
               "double-quoted client id must extract")
    try expect(extracted?.clientSecret == "GOCSPX-fixture-secret",
               "double-quoted client secret must extract")

    let minified = "var a=1;const OAUTH_CLIENT_ID='id-single';const OAUTH_CLIENT_SECRET='secret-single';x()"
    let single = GeminiClientExtractor.extract(fromOAuth2JS: minified)
    try expect(single?.clientID == "id-single", "single-quoted minified id must extract")
    try expect(single?.clientSecret == "secret-single", "single-quoted minified secret must extract")

    try expect(GeminiClientExtractor.extract(fromOAuth2JS: "const OAUTH_CLIENT_ID = \"only-id\";") == nil,
               "id without secret must fail extraction")
    try expect(GeminiClientExtractor.extract(fromOAuth2JS: "nothing here") == nil,
               "unrelated content must fail extraction")
}

private func testClientExtractionFromFixtureFile() throws {
    let home = try makeTempGeminiHome(credsExpiryMs: nil)
    defer { try? FileManager.default.removeItem(at: home) }
    let js = home.appendingPathComponent("oauth2.js")
    try """
    const OAUTH_CLIENT_ID = "file-client-id";
    const OAUTH_CLIENT_SECRET = "file-client-secret";
    """.write(to: js, atomically: true, encoding: .utf8)
    let content = try String(contentsOf: js, encoding: .utf8)
    let extracted = GeminiClientExtractor.extract(fromOAuth2JS: content)
    try expect(extracted == GeminiClientCredentials(
        clientID: "file-client-id", clientSecret: "file-client-secret"
    ), "extraction from a fixture js file must round-trip")
}

private func testClientEnvOverride() throws {
    let env = [
        "GEMINI_OAUTH_CLIENT_ID": "env-id",
        "GEMINI_OAUTH_CLIENT_SECRET": "env-secret",
    ]
    try expect(GeminiClientExtractor.fromEnvironment(env)
               == GeminiClientCredentials(clientID: "env-id", clientSecret: "env-secret"),
               "env override must resolve")
    try expect(GeminiClientExtractor.fromEnvironment(["GEMINI_OAUTH_CLIENT_ID": "only"]) == nil,
               "half an override must not resolve")
}

// MARK: - Quota decode

@main
private enum GeminiParsingTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("detection states", testDetectionStates),
            ("data root names and order", testDataRootNamesAndOrder),
            ("request text unwraps the USER_REQUEST envelope", testAntigravityRequestTextUnwrapsEnvelope),
            ("quota summary parses the real payload", testQuotaSummaryParsesRealPayload),
            ("user status prefers userTier over planName", testUserStatusPrefersUserTierOverPlanName),
            ("quota degrades without inventing headroom", testQuotaDegradesWithoutInventingHeadroom),
            ("quota tolerates shape variants", testQuotaToleratesShapeVariants),
            ("tier badge compacts to chip length", testTierBadgeCompaction),
            ("creds parse fields and email", testLoadCredsParsesFieldsAndEmail),
            ("needsRefresh honors skew", testNeedsRefreshHonorsSkew),
            ("refresh writeback rewrites atomically", testApplyRefreshRewritesAtomicallyAndPreservesEverythingElse),
            ("failed refresh leaves file untouched", testFailedRefreshLeavesFileUntouched),
            ("client extraction regex", testClientExtractionRegex),
            ("client extraction from fixture file", testClientExtractionFromFixtureFile),
            ("client env override", testClientEnvOverride),
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("AntigravityParsingTests GREEN")
        } catch {
            fputs("AntigravityParsingTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
