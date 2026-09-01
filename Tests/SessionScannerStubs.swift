import Foundation

// App-only symbols the isolated SessionScanner test build must satisfy. The
// real declarations live in the app target (SubagentAlarmStore.swift); the two
// sets are never compiled together, so this is a stand-in, not a duplicate.
let subagentAlarmDefaultsKey = "AgentIsland.showSubagentAlarms"

enum TriggerTool: String {
    case claude
    case codex
    case antigravity
    case grok
    case cursor
}

enum ActivityMonitor {
    enum State: Int {
        case idle = 0
        case working = 1
        case needsYou = 2
        case stalled = 3
        case rateLimited = 4
        case authRequired = 5
    }
}
