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

// The test binary is unbundled, so UserDefaults.standard resolves to a
// process-name domain — isolated from the real app's preferences. The
// runner script deletes the domain afterwards.
private let frontmostKey = "AgentIsland.agentReminderFrontmostSoundOnly"

@MainActor
private func testFrontmostSoundOnlyDefaultsOffAndPersists() throws {
    UserDefaults.standard.removeObject(forKey: frontmostKey)
    let store = AgentReminderStore.shared
    try expect(store.frontmostSoundOnly == false, "#9 chime must default off (silent as before)")

    store.frontmostSoundOnly = true
    try expect(UserDefaults.standard.bool(forKey: frontmostKey), "toggling on must persist")

    store.frontmostSoundOnly = false
    try expect(UserDefaults.standard.object(forKey: frontmostKey) != nil,
               "explicit off must write, not just clear")
    try expect(!UserDefaults.standard.bool(forKey: frontmostKey), "toggling off must persist")

    store.frontmostSoundOnly = true
    try expect(UserDefaults.standard.bool(forKey: frontmostKey), "round trip must land on on")
    UserDefaults.standard.removeObject(forKey: frontmostKey)
}

@MainActor
private func testChimeSoundResolves() throws {
    try expect(AgentReminderStore.shared.makeAlarmSound() != nil,
               "the chime must resolve a sound (Glass fallback) or #9 no-ops silently")
}


/// The Apple-ringtone tier ("苹果闹钟那种级别", owner 2026-08-09). Radar is
/// the iPhone default alarm and the new out-of-box choice; every curated
/// tone must decode from the system library it is referenced from, storage
/// must round-trip, and a tone absent from this system must fall back
/// rather than resolve to a silent alarm.
@MainActor
private func testAppleRingtoneChoices() throws {
    typealias Choice = AgentReminderStore.AlarmSoundChoice
    typealias Tones = AgentReminderStore.AppleRingtones

    // This machine ships the library (macOS 13+ always has), so the tier
    // must be populated and lead the picker.
    try expect(!Tones.available.isEmpty, "ringtone tier must exist on a stock macOS")
    if case .ringtone(let first) = Choice.all.first {
        try expect(first == Tones.available.first ?? "", "ringtones lead the picker")
    } else {
        throw TestFailure.assertion("first picker entry must be a ringtone")
    }
    try expect(Tones.available.first == "Radar", "Radar heads the curated order")

    let stored = Choice.ringtone("Radar").storageValue
    try expect(stored == "Ringtone:Radar", "storage format")
    try expect(Choice(storageValue: stored) == .ringtone("Radar"), "storage round-trips")
    try expect(Choice(storageValue: "Ringtone:Nonexistent Tone") == nil,
               "a tone this system lacks must not resolve — silent alarms are worse than the default")
    try expect(Choice(storageValue: "Glass") == .preset(.glass), "classic presets still parse")
}

@main
private enum AgentReminderStoreTestRunner {
    @MainActor
    static func main() {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("frontmost chime defaults off and persists", testFrontmostSoundOnlyDefaultsOffAndPersists),
            ("chime sound resolves", testChimeSoundResolves),
            ("apple ringtone choices", testAppleRingtoneChoices)
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("AgentReminderStoreTests GREEN")
        } catch {
            fputs("AgentReminderStoreTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
