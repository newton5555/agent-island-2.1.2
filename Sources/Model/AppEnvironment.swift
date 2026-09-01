import Foundation

enum AppMode {
    case normal
    case demo
    case debug
}

enum AppEnvironment {
    static let current: AppMode = {
        let env = ProcessInfo.processInfo.environment
        func on(_ key: String) -> Bool { env[key] == "1" }
        if on("AGENTISLAND_DEMO") { return .demo }
        if on("AGENTISLAND_DEBUG") { return .debug }
        return .normal
    }()

    static var isDemo: Bool { current == .demo }
    static var isDebug: Bool { current == .debug }

    static var demoGuestFixturesEnabled: Bool {
        isDemo && ProcessInfo.processInfo.environment["AGENTISLAND_DEMO_GUESTS"] == "1"
    }
}
