import Foundation

/// Cursor dashboard-RPC parsing plus the credential helpers. Fixtures
/// mirror a live GetCurrentPeriodUsage / GetPlanInfo capture (2026-08-08,
/// free tier): Connect encodes int64 as STRING, percentages arrive 0-100.

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

private let usageFixture = Data("""
{
 "billingCycleStart": "1783618546267",
 "billingCycleEnd": "1786296946267",
 "planUsage": {
  "totalSpend": 41, "bonusSpend": 41, "remainingBonus": false,
  "autoPercentUsed": 41, "apiPercentUsed": 0, "totalPercentUsed": 20.5
 },
 "displayThreshold": 200,
 "displayMessage": "You've used 0% of your included usage"
}
""".utf8)

private let usageNoTotalFixture = Data("""
{
 "billingCycleEnd": "1786296946267",
 "planUsage": { "autoPercentUsed": 63, "apiPercentUsed": 12 }
}
""".utf8)

private let planFixture = Data("""
{
 "planInfo": { "planName": "Free", "price": "Free", "billingCycleEnd": "1786296946267" },
 "nextUpgrade": { "tier": "pro", "name": "Pro" }
}
""".utf8)

/// header.payload.signature with payload {"sub":"google-oauth2|user_01TEST"}
private let jwtFixture = "eyJhbGciOiJSUzI1NiJ9."
    + Data(#"{"sub":"google-oauth2|user_01TEST"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    + ".sig"

// MARK: - Runner

@main
private struct Runner {
    static func main() {
        do {
            let snapshot = CursorUsageFetcher.parseUsage(usageFixture)
            try expect(snapshot != nil, "live-shape usage fixture parses")
            try expect(abs((snapshot?.usedPercent ?? 0) - 0.205) < 0.0001,
                       "totalPercentUsed 20.5 lands as fraction 0.205")
            try expect(snapshot?.periodEnd != nil, "string-encoded billingCycleEnd parses")
            try expect(abs((snapshot?.periodEnd?.timeIntervalSince1970 ?? 0) - 1_786_296_946.267) < 0.001,
                       "cycle end converts from epoch millis")

            let fallback = CursorUsageFetcher.parseUsage(usageNoTotalFixture)
            try expect(abs((fallback?.usedPercent ?? 0) - 0.63) < 0.0001,
                       "missing totalPercentUsed falls back to max(auto, api)")

            try expect(CursorUsageFetcher.parseUsage(Data("{}".utf8)) == nil,
                       "empty object refuses to parse rather than fake zeros")
            try expect(CursorUsageFetcher.parseUsage(Data("not json".utf8)) == nil,
                       "garbage refuses to parse")

            try expect(CursorUsageFetcher.parsePlanName(planFixture) == "free",
                       "plan name parses lowercased")
            try expect(CursorUsageFetcher.parsePlanName(Data("{}".utf8)) == nil,
                       "missing plan info yields nil")

            try expect(CursorCredentials.decodeSubject(fromJWT: jwtFixture) == "google-oauth2|user_01TEST",
                       "JWT sub decodes through base64url without padding")
            try expect(CursorCredentials.decodeSubject(fromJWT: "eyJhbGciOiJSUzI1NiJ9") == nil,
                       "single-segment token yields nil")
            try expect(CursorCredentials.looksLikeJWT(jwtFixture),
                       "three-segment eyJ token passes the shape check")
            try expect(!CursorCredentials.looksLikeJWT("free"),
                       "a bare tier string is not a JWT")

            try expect(CursorCredentials.normalizePlan("pro_plusXtrailing") == "pro plus",
                       "longest tier prefix wins over pro")
            try expect(CursorCredentials.normalizePlan("free") == "free",
                       "free normalizes")
            try expect(CursorCredentials.normalizePlan("weird") == nil,
                       "unknown tier drops instead of showing garbage")
            try expect(CursorCredentials.normalizePlan(nil) == nil,
                       "nil plan stays nil")

            print("CursorParsingTests GREEN")
        } catch {
            fputs("CursorParsingTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
