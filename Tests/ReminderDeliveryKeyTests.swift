import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.assertion(message) }
}

private func testNilTurnKeyUsesStableSameTurnKey() throws {
    let first = ReminderDeliveryKey.make(
        providerRawValue: "claude",
        stateRawValue: 2,
        transcriptPath: "/Users/me/.claude/projects/demo/session.jsonl",
        sessionId: "session-a",
        cwd: "/Users/me/demo",
        label: "Demo",
        turnKey: nil
    )
    let second = ReminderDeliveryKey.make(
        providerRawValue: "claude",
        stateRawValue: 2,
        transcriptPath: "/Users/me/.claude/projects/demo/session.jsonl",
        sessionId: "session-a",
        cwd: "/Users/me/demo",
        label: "Demo",
        turnKey: nil
    )
    try expect(first == second, "same thread without a parsed turn key must not become a new reminder key")
    try expect(first.hasSuffix("-latest"), "nil turn keys should use a stable latest marker")
}

private func testNewTurnKeyCreatesNewReminderKey() throws {
    let first = ReminderDeliveryKey.make(
        providerRawValue: "codex",
        stateRawValue: 2,
        transcriptPath: "/Users/me/.codex/sessions/session.jsonl",
        sessionId: "session-a",
        cwd: "/Users/me/demo",
        label: "Demo",
        turnKey: "turn-1"
    )
    let second = ReminderDeliveryKey.make(
        providerRawValue: "codex",
        stateRawValue: 2,
        transcriptPath: "/Users/me/.codex/sessions/session.jsonl",
        sessionId: "session-a",
        cwd: "/Users/me/demo",
        label: "Demo",
        turnKey: "turn-2"
    )
    try expect(first != second, "a real new turn key must be allowed to trigger a new reminder")
}

private func testTranscriptPathIsPreferredForThreadIdentity() throws {
    let key = ReminderDeliveryKey.threadKey(
        transcriptPath: "/Users/me/.claude/projects/demo/session.jsonl",
        sessionId: "session-a",
        cwd: "/Users/me/demo",
        label: "Demo"
    )
    try expect(key == "/Users/me/.claude/projects/demo/session.jsonl", "transcript path should be the stable thread identity when available")
}

@main
private enum ReminderDeliveryKeyTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("nil turn key is stable", testNilTurnKeyUsesStableSameTurnKey),
            ("new turn key changes reminder key", testNewTurnKeyCreatesNewReminderKey),
            ("transcript path identifies thread", testTranscriptPathIsPreferredForThreadIdentity)
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("ReminderDeliveryKeyTests GREEN")
        } catch {
            fputs("ReminderDeliveryKeyTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
