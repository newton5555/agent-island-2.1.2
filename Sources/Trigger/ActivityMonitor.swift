import Foundation

@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()
    private init() {}

    struct ActiveThread: Equatable {
        let sessionId: String
        let label: String
        let cwd: String
        let modified: Date
        let transcriptPath: String?
        let turnKey: String?
        let launchTarget: SessionLaunchTarget
    }

    enum State: Int {
        case idle = 0
        case working = 1
        case needsYou = 2
        case stalled = 3
        case rateLimited = 4
        case authRequired = 5

        var isAttentionState: Bool {
            switch self {
            case .stalled, .rateLimited, .authRequired: return true
            case .idle, .working, .needsYou: return false
            }
        }

        /// Attention states that keep the island/logo pulsing. authRequired
        /// is deliberately excluded: it can persist for hours, and an
        /// unexplained endless red blink reads as a crash — the first
        /// external tester filed it as "Claude 一直在跳" within minutes.
        /// It gets a static red treatment instead.
        var pulsesAttention: Bool {
            switch self {
            case .stalled, .rateLimited: return true
            case .idle, .working, .needsYou, .authRequired: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return L10n.tr("idle")
            case .working: return L10n.tr("running")
            case .needsYou: return L10n.tr("your turn")
            case .stalled: return L10n.tr("stalled")
            case .rateLimited: return L10n.tr("rate limited")
            case .authRequired: return L10n.tr("auth required")
            }
        }
    }

    /// Five-provider state maps (2.1.1: session status went five-wide;
    /// before this, Gemini/Grok/Cursor silently read CODEX's state).
    @Published private(set) var states: [AlertEngine.Provider: State] = [:]
    @Published private(set) var threads: [AlertEngine.Provider: ActiveThread] = [:]
    @Published private var demoStates: [AlertEngine.Provider: State] = [:]
    private var rawStates: [AlertEngine.Provider: State] = [:]
    private var lastWorking: [String: Date] = [:]

    var claude: State { state(for: .claude) }
    var codex: State { state(for: .codex) }

    func state(for provider: AlertEngine.Provider) -> State {
        demoStates[provider] ?? states[provider] ?? .idle
    }

    /// Pre-overlay scan state. The turn-alarm confirm gate must read this:
    /// the usage overlay (rateLimited/authRequired outrank needsYou) would
    /// otherwise swallow alarms exactly when the quota is exhausted or the
    /// network is down — the moments a finished turn most needs surfacing.
    func rawState(for provider: AlertEngine.Provider) -> State {
        rawStates[provider] ?? .idle
    }

    func demo(_ state: State?) {
        for provider in [AlertEngine.Provider.claude, .codex, .antigravity, .grok, .cursor] {
            demoStates[provider] = state
        }
    }

    func thread(for provider: AlertEngine.Provider) -> ActiveThread? {
        threads[provider]
    }

    private var timer: Timer?
    private var eventStream: TranscriptEventStream?
    private var lastEventKick = Date.distantPast
    private var pendingKick: Task<Void, Never>?

    func start() {
        // 电影模式 (recording rig): AGENTISLAND_DEMO_ACTIVITY=
        // "claude=idle,codex=working" pins the published states so clips
        // can stage any combination regardless of what's really running.
        if let raw = ProcessInfo.processInfo.environment["AGENTISLAND_DEMO_ACTIVITY"] {
            func parse(_ value: Substring) -> State? {
                switch value {
                case "idle": return .idle
                case "working": return .working
                case "needsYou": return .needsYou
                case "stalled": return .stalled
                case "rateLimited": return .rateLimited
                case "authRequired": return .authRequired
                default: return nil
                }
            }
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2,
                      let provider = AlertEngine.Provider(rawValue: String(kv[0]))
                else { continue }
                demoStates[provider] = parse(kv[1])
            }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        let stream = TranscriptEventStream { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.eventKick() }
        }
        stream.start()
        eventStream = stream
    }

    /// Event-driven rescan, throttled to ~1/s with a guaranteed trailing
    /// scan: a streaming transcript writes many times per second, but the
    /// LAST write of a turn (end_turn / task_complete) must never wait for
    /// the fallback poll — that write is exactly the one that stops the spin
    /// and raises the alarm.
    private func eventKick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEventKick)
        if elapsed >= 0.5 {
            lastEventKick = now
            tick()
            return
        }
        guard pendingKick == nil else { return }
        pendingKick = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.5 - elapsed, 0.05) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingKick = nil
            self.lastEventKick = Date()
            self.tick()
        }
    }

    private func tick() {
        let now = Date()
        let lastWorkingSnapshot = lastWorking
        Task.detached(priority: .utility) {
            let sessions = SessionScanner.monitoringScan(now: now, lastWorking: lastWorkingSnapshot)
            await MainActor.run {
                // Usage-level attention (rate-limited / auth-required red)
                // only applies to providers switched ON in Settings. Someone
                // who only runs Claude keeps Codex hidden — its missing login
                // must not pulse the island red forever.
                let visibility = ProviderVisibilityStore.shared
                self.updateLastWorking(from: sessions, now: now)
                var nextStates: [AlertEngine.Provider: State] = [:]
                var nextRaw: [AlertEngine.Provider: State] = [:]
                var nextThreads: [AlertEngine.Provider: ActiveThread] = [:]
                for (tool, provider) in Self.monitoredProviders {
                    let result = Self.bestSession(in: sessions, tool: tool) {
                        AgentReminderCenter.shared.hasAcknowledged(provider: provider, thread: $0)
                    }
                    nextRaw[provider] = result.state
                    nextThreads[provider] = result.thread
                    nextStates[provider] = visibility.isShown(provider)
                        ? self.overlayUsageAttention(result.state, usage: Self.usage(for: provider))
                        : result.state
                    AgentReminderCenter.shared.handle(
                        provider: provider,
                        needsYouThreads: Self.needsYouThreads(in: sessions, tool: tool)
                    )
                }
                self.rawStates = nextRaw
                self.threads = nextThreads
                self.states = nextStates
            }
        }
    }

    /// All five ride the scan now. Cursor graduated from "absent on
    /// purpose" once the real signal was found: per-workspace state.vscdb
    /// (+ -wal) mtime moves continuously while a window is open, unlike the
    /// batch-written conversation-search.db that disqualified it earlier.
    /// Its turn detector is `mtimeOnly`, so it can show working/idle but
    /// never a false "your turn".
    private static let monitoredProviders: [(TriggerTool, AlertEngine.Provider)] = [
        (.claude, .claude), (.codex, .codex), (.grok, .grok), (.antigravity, .antigravity),
        (.cursor, .cursor),
    ]

    private static func usage(for provider: AlertEngine.Provider) -> AppUsage {
        switch provider {
        case .claude: return UsageStore.shared.claude
        case .codex: return UsageStore.shared.codex
        case .antigravity, .grok, .cursor: return .empty
        }
    }

    private func updateLastWorking(from sessions: [ScannedSession], now: Date) {
        for session in sessions where session.status == .working {
            if let path = session.transcriptPath { lastWorking[path] = now }
        }
        let livePaths = Set(sessions.compactMap(\.transcriptPath))
        lastWorking = lastWorking.filter { livePaths.contains($0.key) }
    }

    private func overlayUsageAttention(_ state: State, usage: AppUsage) -> State {
        guard let attention = Self.usageAttentionState(usage) else { return state }
        return attention.rawValue > state.rawValue ? attention : state
    }

    private static func usageAttentionState(_ usage: AppUsage) -> State? {
        if usage.fiveHour.usedPercent >= 1 || usage.weekly.usedPercent >= 1 {
            return .rateLimited
        }
        let messages = [usage.fiveHour.error, usage.weekly.error].compactMap { $0?.lowercased() }
        if messages.contains(where: { $0.contains("rate limited") || $0.contains("rate_limit") }) {
            return .rateLimited
        }
        if messages.contains(where: { message in
            ClaudeCredentials.isAuthRecoverableError(message)
                || message.contains("auth")
                || message.contains("login")
                || message.contains("no codex")
        }) {
            return .authRequired
        }
        if messages.contains(where: isProviderOrNetworkError) {
            return .rateLimited
        }
        return nil
    }

    private static func isProviderOrNetworkError(_ message: String) -> Bool {
        message.hasPrefix("http ")
            || message.contains("bad response")
            || message.contains("parse error")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("offline")
            || message.contains("network")
            || message.contains("internet")
            || message.contains("connection")
            || message.contains("cannot connect")
            || message.contains("could not connect")
            || message.contains("not connected")
            || message.contains("dns")
            || message.contains("ssl")
            || message.contains("tls")
    }

    /// A turn still waiting on the user outranks everything. But once the
    /// user acknowledged it, the turn is old news: it must not pin the logo
    /// in a static needsYou (masking a genuinely running sibling, which
    /// should spin) for the remainder of its 20-minute needsYou window.
    /// Stalled stays above working so real anomalies surface; below unacked
    /// needsYou so it can't eat an actionable alarm.
    private static func selectionPriority(
        _ session: ScannedSession,
        isAcknowledged: (ActiveThread) -> Bool
    ) -> Int {
        switch session.status {
        case .needsYou: return isAcknowledged(makeThread(session)) ? 1 : 4
        case .stalled: return 3
        case .working: return 2
        case .idle, .authRequired, .rateLimited: return 0
        }
    }

    private static func bestSession(
        in sessions: [ScannedSession],
        tool: TriggerTool,
        isAcknowledged: (ActiveThread) -> Bool
    ) -> (state: State, thread: ActiveThread?) {
        let ranked = sessions
            .filter { $0.tool == tool }
            .map { (session: $0, priority: selectionPriority($0, isAcknowledged: isAcknowledged)) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.session.modified > rhs.session.modified
            }
        guard let top = ranked.first?.session else { return (.idle, nil) }
        let thread = top.status == .idle ? nil : makeThread(top)
        return (top.status, thread)
    }

    /// Every needsYou session, newest first. The reminder center tracks each
    /// finished turn separately, so one thread's alarm can never cancel or
    /// mask another's.
    private static func needsYouThreads(in sessions: [ScannedSession], tool: TriggerTool) -> [ActiveThread] {
        sessions
            .filter { $0.tool == tool && $0.status == .needsYou }
            .sorted { $0.modified > $1.modified }
            .map(makeThread)
    }

    private static func makeThread(_ session: ScannedSession) -> ActiveThread {
        ActiveThread(
            sessionId: session.sessionId,
            label: session.label,
            cwd: session.cwd,
            modified: session.modified,
            transcriptPath: session.transcriptPath,
            turnKey: session.turnKey,
            launchTarget: session.launchTarget
        )
    }
}
