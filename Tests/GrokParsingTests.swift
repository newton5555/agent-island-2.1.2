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

/// Real zero-usage weekly payload captured 2026-08-05 — creditUsagePercent
/// is genuinely absent, and the period stamps carry 6-digit fractions.
private let weeklyZeroFixture = Data("""
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-07-31T15:48:23.488813+00:00",
      "end": "2026-08-07T15:48:23.488813+00:00"
    },
    "onDemandCap": { "val": 0 },
    "onDemandUsed": { "val": 0 },
    "isUnifiedBillingUser": true,
    "prepaidBalance": { "val": 0 },
    "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
    "billingPeriodStart": "2026-07-31T15:48:23.488813+00:00",
    "billingPeriodEnd": "2026-08-07T15:48:23.488813+00:00"
  }
}
""".utf8)

private let weeklyActiveFixture = Data("""
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-07-31T15:48:23.488813+00:00",
      "end": "2026-08-07T15:48:23.488813+00:00"
    },
    "creditUsagePercent": 37.5,
    "productUsage": [
      { "product": "grok-code", "creditUsagePercent": 12.0 }
    ],
    "billingPeriodEnd": "2026-08-07T15:48:23.488813+00:00"
  }
}
""".utf8)

private let monthlyFixture = Data("""
{
  "config": {
    "monthlyLimit": { "val": 4000 },
    "used": { "val": 123 },
    "onDemandCap": { "val": 0 },
    "billingPeriodStart": "2026-08-01T00:00:00+00:00",
    "billingPeriodEnd": "2026-09-01T00:00:00+00:00",
    "history": []
  }
}
""".utf8)

private func fixtureAuthRoot(expiresAtMs: Int) -> String {
    """
    {
      "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
        "key": "old-access-token",
        "auth_mode": "oidc",
        "create_time": "2026-07-19T00:00:00.000000+00:00",
        "user_id": "user-1234",
        "email": "tester@example.com",
        "coding_data_retention_opt_out": true,
        "refresh_token": "old-refresh-token",
        "expires_at": \(expiresAtMs),
        "oidc_issuer": "https://auth.x.ai",
        "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
      },
      "https://accounts.x.ai/sign-in": {
        "key": "legacy-session-token",
        "auth_mode": "session",
        "email": "tester@example.com"
      }
    }
    """
}

private func makeTempAuthFile(expiresAtMs: Int) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("auth.json")
    try fixtureAuthRoot(expiresAtMs: expiresAtMs).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

// MARK: - Timestamp

private func testTimestampParsingHandlesMicrosecondFractions() throws {
    let micro = GrokTimestamp.parse("2026-07-31T15:48:23.488813+00:00")
    try expect(micro != nil, "6-digit fractional timestamps must parse")
    let base = GrokTimestamp.parse("2026-07-31T15:48:23+00:00")
    try expect(base != nil, "fraction-free timestamps must parse")
    if let micro, let base {
        let fraction = micro.timeIntervalSince1970 - base.timeIntervalSince1970
        try expect(abs(fraction - 0.488) < 0.01,
                   "microsecond fraction must survive (trimmed to milliseconds)")
    }
    try expect(GrokTimestamp.parse("not a date") == nil, "garbage must return nil")
}

// MARK: - Billing decode

private func testWeeklyZeroUsageOmittedPercentReadsAsZero() throws {
    let pool = GrokBillingParser.parseWeekly(weeklyZeroFixture)
    try expect(pool != nil, "zero-usage weekly payload must decode")
    try expect(pool?.usedPercent == 0, "omitted creditUsagePercent must read as 0")
    try expect(pool?.periodEnd != nil, "weekly period end must parse")
}

private func testWeeklyActiveUsageNormalizesPercent() throws {
    let pool = GrokBillingParser.parseWeekly(weeklyActiveFixture)
    try expect(pool != nil, "active weekly payload must decode")
    try expect(pool?.usedPercent == 0.375, "creditUsagePercent 37.5 must normalize to 0.375")
    try expect(pool?.products.count == 1, "productUsage rows must be captured")
    try expect(pool?.products.first?.product == "grok-code", "product name must survive")
    try expect(pool?.products.first?.usedPercent == 0.12,
               "per-product creditUsagePercent must normalize to 0...1")
}

private func testProductUsageAcceptsBothPercentKeysAndOmission() throws {
    let fixture = Data("""
    {
      "config": {
        "creditUsagePercent": 50,
        "productUsage": [
          { "product": "grok-code", "usagePercent": 41.5 },
          { "product": "grok-web", "creditUsagePercent": 8 },
          { "product": "grok-voice" },
          { "product": "" }
        ]
      }
    }
    """.utf8)
    let pool = GrokBillingParser.parseWeekly(fixture)
    try expect(pool?.products.count == 3, "empty product names must drop, unnamed percents must stay")
    try expect(pool?.products[0].usedPercent == 0.415, "usagePercent spelling must decode")
    try expect(pool?.products[1].usedPercent == 0.08, "creditUsagePercent spelling must decode")
    try expect(pool?.products[2].usedPercent == nil,
               "a product without a percent must read as nil, not fake 0")
}

private func testWeeklyGarbageReturnsNil() throws {
    try expect(GrokBillingParser.parseWeekly(Data("{}".utf8)) == nil,
               "payload without config must be a parse failure, not fake 0%")
    try expect(GrokBillingParser.parseWeekly(Data("not json".utf8)) == nil,
               "non-JSON must be a parse failure")
}

private func testMonthlyBudgetDecodesCents() throws {
    let budget = GrokBillingParser.parseMonthly(monthlyFixture)
    try expect(budget != nil, "monthly payload must decode")
    try expect(budget?.limitCents == 4000, "monthlyLimit.val must decode as cents")
    try expect(budget?.usedCents == 123, "used.val must decode as cents")
    try expect(budget?.periodEnd != nil, "billingPeriodEnd must parse")
}

private func testCentsToDollarsFormatting() throws {
    try expect(GrokBillingParser.dollars(fromCents: 4000) == "40", "whole dollars drop the decimals")
    try expect(GrokBillingParser.dollars(fromCents: 123) == "1.23", "cents render two decimals")
    try expect(GrokBillingParser.dollars(fromCents: 0) == "0", "zero renders bare")
    try expect(GrokBillingParser.dollars(fromCents: -50) == "0", "negative clamps to zero")
}

// MARK: - Auth file

private func testLoadEntryPrefersOIDCScopeAndParsesFields() throws {
    let url = try makeTempAuthFile(expiresAtMs: 1_785_888_020_774)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let entry = GrokAuthFile.loadEntry(from: url)
    try expect(entry != nil, "fixture auth.json must load")
    try expect(entry?.scope.contains("auth.x.ai") == true, "the auth.x.ai scope must win over legacy")
    try expect(entry?.accessToken == "old-access-token", "key field must map to accessToken")
    try expect(entry?.refreshToken == "old-refresh-token", "refresh_token must parse")
    try expect(entry?.email == "tester@example.com", "email must parse")
    try expect(entry?.isSuperGrok == true, "auth_mode oidc must read as SuperGrok")
    try expect(entry?.oidcClientID == "b1a00492-073a-47ea-816f-4c329264a828",
               "client id must parse")
    if let expiresAt = entry?.expiresAt {
        try expect(abs(expiresAt.timeIntervalSince1970 - 1_785_888_020.774) < 1,
                   "expires_at must decode as epoch milliseconds")
    } else {
        try expect(false, "expires_at must be present")
    }
}

private func testNeedsRefreshHonorsSkew() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func entry(expiringIn seconds: TimeInterval?) -> GrokAuthEntry {
        GrokAuthEntry(
            scope: "https://auth.x.ai::client",
            accessToken: "t",
            refreshToken: "r",
            expiresAt: seconds.map { now.addingTimeInterval($0) },
            authMode: "oidc",
            email: nil,
            oidcIssuer: GrokAuthFile.defaultIssuer,
            oidcClientID: "client"
        )
    }
    try expect(GrokAuthFile.needsRefresh(entry(expiringIn: 30), now: now),
               "a token expiring inside the skew window must refresh")
    try expect(!GrokAuthFile.needsRefresh(entry(expiringIn: 600), now: now),
               "a token with 10 minutes left must not refresh")
    try expect(!GrokAuthFile.needsRefresh(entry(expiringIn: nil), now: now),
               "no expiry means no proactive refresh")
}

private func testApplyRefreshRotatesTokensAtomicallyAndPreservesEverythingElse() throws {
    let url = try makeTempAuthFile(expiresAtMs: 1_785_888_020_774)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let scope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    let now = Date()
    let response = Data("""
    { "access_token": "new-access-token", "refresh_token": "new-refresh-token",
      "expires_in": 21600, "token_type": "Bearer" }
    """.utf8)

    let updated = GrokAuthFile.applyRefreshResponse(response, to: url, scope: scope, now: now)
    try expect(updated != nil, "refresh writeback must succeed")
    try expect(updated?.accessToken == "new-access-token", "returned entry must carry the new token")
    try expect(updated?.refreshToken == "new-refresh-token", "returned entry must carry the rotated refresh token")

    let raw = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let entry = root[scope] as? [String: Any] else {
        try expect(false, "rewritten auth.json must stay a scope-keyed object")
        return
    }
    try expect(entry["key"] as? String == "new-access-token", "key must be rewritten on disk")
    try expect(entry["refresh_token"] as? String == "new-refresh-token",
               "rotated refresh token must be persisted — losing it strands the CLI login")
    if let ms = entry["expires_at"] as? Double {
        let expected = (now.timeIntervalSince1970 + 21_600) * 1000
        try expect(abs(ms - expected) < 2_000, "expires_at must be rewritten as epoch milliseconds")
    } else {
        try expect(false, "expires_at must remain a number")
    }
    try expect(entry["email"] as? String == "tester@example.com", "untouched fields must survive")
    try expect(entry["coding_data_retention_opt_out"] as? Bool == true,
               "fields this app doesn't understand must survive")
    try expect(root["https://accounts.x.ai/sign-in"] != nil, "sibling scope entries must survive")

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    try expect(perms & 0o777 == 0o600, "rewritten auth.json must stay 0600")
}

private func testApplyRefreshWithoutAccessTokenLeavesFileUntouched() throws {
    let url = try makeTempAuthFile(expiresAtMs: 1_785_888_020_774)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let scope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    let before = try Data(contentsOf: url)

    let updated = GrokAuthFile.applyRefreshResponse(
        Data("{ \"error\": \"invalid_grant\" }".utf8), to: url, scope: scope
    )
    try expect(updated == nil, "an error response must not report success")
    let after = try Data(contentsOf: url)
    try expect(before == after, "a failed refresh must leave auth.json byte-identical")
}

@main
private enum GrokParsingTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("timestamp parsing handles microsecond fractions", testTimestampParsingHandlesMicrosecondFractions),
            ("weekly zero usage reads as 0", testWeeklyZeroUsageOmittedPercentReadsAsZero),
            ("weekly active usage normalizes percent", testWeeklyActiveUsageNormalizesPercent),
            ("product usage accepts both percent keys", testProductUsageAcceptsBothPercentKeysAndOmission),
            ("weekly garbage returns nil", testWeeklyGarbageReturnsNil),
            ("monthly budget decodes cents", testMonthlyBudgetDecodesCents),
            ("cents to dollars formatting", testCentsToDollarsFormatting),
            ("load entry prefers oidc scope", testLoadEntryPrefersOIDCScopeAndParsesFields),
            ("needsRefresh honors skew", testNeedsRefreshHonorsSkew),
            ("refresh writeback rotates atomically", testApplyRefreshRotatesTokensAtomicallyAndPreservesEverythingElse),
            ("failed refresh leaves file untouched", testApplyRefreshWithoutAccessTokenLeavesFileUntouched)
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("GrokParsingTests GREEN")
        } catch {
            fputs("GrokParsingTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
