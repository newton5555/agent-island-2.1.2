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

private func testSanitizeAndRoundTrip() throws {
    let dirty = ["grok", "claude", "claude", "future-provider", "gemini"]
    let sanitized = ProviderSelection.sanitize(dirty)
    try expect(sanitized == [.claude, .antigravity], "sanitize must dedupe, order, and cap at two")

    let encoded = try JSONEncoder().encode(sanitized.map(\.rawValue))
    let decoded = try JSONDecoder().decode([String].self, from: encoded)
    try expect(ProviderSelection.sanitize(decoded) == sanitized,
               "persisted provider selection must round-trip")
}

private func testMaximumTwoRefusesWithoutEviction() throws {
    let current: [DisplayProvider] = [.claude, .codex]
    let outcome = ProviderSelection.toggling(current, .antigravity)
    try expect(outcome == .refusedLimit, "enabling a third provider must be refused")
    try expect(current == [.claude, .codex], "refusal must not evict an existing provider")
}

private func testToggleAndCanonicalOrder() throws {
    try expect(
        ProviderSelection.toggling([.grok], .claude) == .updated([.claude, .grok]),
        "new selections must use stable slot order"
    )
    try expect(
        ProviderSelection.toggling([.claude, .grok], .claude) == .updated([.grok]),
        "an enabled provider must turn off"
    )
}

private func testLegacyMigrationAndCapabilities() throws {
    try expect(ProviderSelection.migrated(claudeVisible: true, codexVisible: true) == [.claude, .codex],
               "classic duo must migrate unchanged")
    try expect(ProviderSelection.migrated(claudeVisible: false, codexVisible: true) == [.codex],
               "solo Codex must migrate unchanged")
    try expect(DisplayProvider.claude.hasFullMonitoring && DisplayProvider.codex.hasFullMonitoring,
               "Claude and Codex must retain full monitoring")
    try expect(!DisplayProvider.antigravity.hasFullMonitoring && !DisplayProvider.grok.hasFullMonitoring,
               "Gemini and Grok must stay quota-only")
}

@main
private enum ProviderSelectionTestRunner {
    static func main() throws {
        try testSanitizeAndRoundTrip()
        try testMaximumTwoRefusesWithoutEviction()
        try testToggleAndCanonicalOrder()
        try testLegacyMigrationAndCapabilities()
        print("✓ provider selection tests passed")
    }
}
