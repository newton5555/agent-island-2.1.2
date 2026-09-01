import Foundation

/// Which providers occupy the island's two silhouette slots, plus per-
/// provider machine detection.
///
/// The silhouette geometry is fixed at two tabs + two pills — provider
/// choice binds providers to those slots, it never adds a third. The
/// enabled list (max 2, canonical order) drives the slots; one enabled
/// provider gets the solo split layout.
///
/// Detection layers per provider:
///   - claude/codex: CLI footprint stat'd once at launch. A provider with
///     no footprint auto-yields its half of the island so single-
///     subscription users get the solo layout without hunting for a
///     Settings toggle (top user ask after 1.6.1 — "只订阅一个的时候整个
///     界面看起来非常尴尬"). Manual wins once touched: flipping the toggle
///     records intent, and detection stops second-guessing that provider.
///   - gemini/grok: zero-intrusion. No login on this machine → no toggle,
///     no slot, no panel strip.
@MainActor
final class ProviderVisibilityStore: ObservableObject {
    static let shared = ProviderVisibilityStore()

    private static let enabledKey = "AgentIsland.enabledProviders.v1"
    private static let claudeKey = "AgentIsland.claudeVisible"
    private static let codexKey = "AgentIsland.codexVisible"
    private static let claudeTouchedKey = "AgentIsland.claudeVisibleTouched"
    private static let codexTouchedKey = "AgentIsland.codexVisibleTouched"

    /// The providers bound to the island slots, canonical order, max 2.
    @Published private(set) var enabled: [DisplayProvider]

    /// CLI footprint, evaluated once at launch.
    @Published private(set) var claudeDetected: Bool
    @Published private(set) var codexDetected: Bool
    /// Grok counts as installed only with a login on disk (`auth.json`) —
    /// a bare ~/.grok from an aborted install has nothing to show.
    @Published private(set) var grokDetected: Bool
    /// Antigravity counts as installed once a credential exists (keychain for
    /// the CLI, oauth_creds.json for the IDE). A data root with no credential
    /// is a real install awaiting sign-in — surfaced as a Settings caption
    /// (`antigravitySignedOut`), never as a slot candidate.
    @Published private(set) var antigravityDetected: Bool
    /// Cursor counts as installed when the editor's state db exists — that
    /// db is also where its session token lives, so no db means no login.
    @Published private(set) var cursorDetected: Bool
    @Published private(set) var antigravitySignedOut: Bool

    private init() {
        // Demo shares the real user's defaults — pin the recording rig to
        // the classic duo and never write the selection back.
        if AppEnvironment.isDemo {
            if AppEnvironment.demoGuestFixturesEnabled {
                let raw = ProcessInfo.processInfo.environment["AGENTISLAND_DEMO_PROVIDERS"]?
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? []
                let selected = ProviderSelection.sanitize(raw)
                self.enabled = selected.isEmpty ? [.claude, .grok] : selected
            } else {
                self.enabled = [.claude, .codex]
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.enabledKey),
                  let raw = try? JSONDecoder().decode([String].self, from: data) {
            self.enabled = ProviderSelection.sanitize(raw)
        } else {
            // First run on 1.8.1: carry the pre-slot toggles over so existing
            // users keep exactly the island they had.
            self.enabled = ProviderSelection.migrated(
                claudeVisible: Pref.seededBool(key: Self.claudeKey, default: true),
                codexVisible: Pref.seededBool(key: Self.codexKey, default: true)
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        func hasDir(_ relative: String) -> Bool {
            var isDir: ObjCBool = false
            let path = home.appendingPathComponent(relative).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        }
        self.claudeDetected = hasDir(".claude") || hasDir(".config/claude")
        self.codexDetected = hasDir(".codex")
        self.grokDetected = false
        self.cursorDetected = false
        self.antigravityDetected = false
        self.antigravitySignedOut = false
        redetectGuests()

        if !AppEnvironment.isDemo, UserDefaults.standard.data(forKey: Self.enabledKey) == nil {
            persist()
        }
    }

    /// Re-probe the guests' on-disk login state.
    ///
    /// Detection used to run ONCE in init, so signing into a provider after
    /// launch left the app insisting it was not installed until a relaunch —
    /// the owner logged into the Gemini CLI twenty minutes after starting the
    /// app and the row stayed "not detected" (repro, 2026-08-08). The refresh
    /// cycle calls this, so a fresh login shows up within one poll.
    func redetectGuests() {
        guard !AppEnvironment.isDemo else {
            let onForDemo = AppEnvironment.demoGuestFixturesEnabled
            if grokDetected != onForDemo { grokDetected = onForDemo }
            if cursorDetected != onForDemo { cursorDetected = onForDemo }
            if antigravityDetected != onForDemo { antigravityDetected = onForDemo }
            if antigravitySignedOut { antigravitySignedOut = false }
            return
        }
        let grok = GrokAuthFile.exists()
        if grokDetected != grok { grokDetected = grok }
        let cursor = CursorCredentials.exists()
        if cursorDetected != cursor { cursorDetected = cursor }

        let antigravity: Bool
        let signedOut: Bool
        switch AntigravityCredentials.detect() {
        case .signedIn:
            antigravity = true
            signedOut = false
        case .signedOut:
            // The CLI is installed and simply hasn't been through its sign-in
            // wizard — a fixable state, not an absence. Say so rather than
            // claiming Antigravity isn't here.
            antigravity = false
            signedOut = true
        case .notInstalled:
            antigravity = false
            signedOut = false
        }
        if antigravityDetected != antigravity { antigravityDetected = antigravity }
        if antigravitySignedOut != signedOut { antigravitySignedOut = signedOut }
    }

    // MARK: - Toggling

    /// Flip a provider's slot membership. Returns false when this would
    /// enable a third provider — the caller explains and nothing changes
    /// (never silently evict someone else's pick).
    @discardableResult
    func requestToggle(_ provider: DisplayProvider) -> Bool {
        switch ProviderSelection.toggling(enabled, provider) {
        case .refusedLimit:
            return false
        case .updated(let next):
            enabled = next
            markTouched(provider)
            persist()
            return true
        }
    }

    func isEnabled(_ provider: DisplayProvider) -> Bool {
        enabled.contains(provider)
    }

    private func markTouched(_ provider: DisplayProvider) {
        guard !AppEnvironment.isDemo else { return }
        switch provider {
        case .claude: UserDefaults.standard.set(true, forKey: Self.claudeTouchedKey)
        case .codex:  UserDefaults.standard.set(true, forKey: Self.codexTouchedKey)
        case .antigravity, .grok, .cursor: break
        }
    }

    private func persist() {
        guard !AppEnvironment.isDemo else { return }
        guard let data = try? JSONEncoder().encode(enabled.map(\.rawValue)) else { return }
        UserDefaults.standard.set(data, forKey: Self.enabledKey)
    }

    // MARK: - What the island renders

    /// Slot occupants after detection has its say, canonical order.
    /// Left slot = first, right slot = second; one entry = solo layout.
    var slotProviders: [DisplayProvider] {
        enabled.filter(shown(_:))
    }

    var soloSlotProvider: DisplayProvider? {
        let slots = slotProviders
        return slots.count == 1 ? slots[0] : nil
    }

    func shown(_ provider: DisplayProvider) -> Bool {
        guard enabled.contains(provider) else { return false }
        switch provider {
        case .claude:
            if UserDefaults.standard.bool(forKey: Self.claudeTouchedKey) { return true }
            return claudeDetected || !(enabled.contains(.codex) && codexDetected)
        case .codex:
            if UserDefaults.standard.bool(forKey: Self.codexTouchedKey) { return true }
            return codexDetected || !(enabled.contains(.claude) && claudeDetected)
        case .antigravity:
            return antigravityDetected
        case .grok:
            return grokDetected
        case .cursor:
            return cursorDetected
        }
    }

    /// Detection only speaks for a provider whose toggle was never touched,
    /// and only hides one side when the other slot holds its detected
    /// counterpart — a machine with neither footprint still shows both
    /// instead of a blank island.
    var claudeShown: Bool { shown(.claude) }
    var codexShown: Bool { shown(.codex) }

    /// The selection is the single source of truth everywhere (owner call,
    /// 2026-08-08: 计费/用量/一切都只是四选二) — the expanded panel shows
    /// exactly the slot providers, never a detected-but-unselected extra.
    var claudePanelShown: Bool { shown(.claude) }
    var codexPanelShown: Bool { shown(.codex) }

    /// Alert-domain reads (AlertEngine, glow attention): the manual slot
    /// pick, before detection's auto-yield.
    var claudeVisible: Bool { enabled.contains(.claude) }
    var codexVisible: Bool { enabled.contains(.codex) }

    /// Panel guest strips (usage page) follow the slot selection like every
    /// other surface — an unselected guest shows nothing and fetches
    /// nothing, no matter what login sits on disk.
    var grokPanelShown: Bool { shown(.grok) }
    var antigravityPanelShown: Bool { shown(.antigravity) }
    var cursorPanelShown: Bool { shown(.cursor) }

    /// Number of quota-only rows appended to the usage page. Selection-
    /// driven, so the panel re-sizes when a guest slot is toggled
    /// (IslandModel subscribes to `$enabled`).
    var guestPanelCount: Int {
        (antigravityPanelShown ? 1 : 0) + (grokPanelShown ? 1 : 0) + (cursorPanelShown ? 1 : 0)
    }

    /// Single accessor for call sites that have an `AlertEngine.Provider`
    /// in hand.
    func effectiveVisible(provider: AlertEngine.Provider) -> Bool {
        switch provider {
        case .claude: return claudeShown
        case .codex:  return codexShown
        case .antigravity: return antigravityPanelShown
        case .grok:   return grokPanelShown
        case .cursor: return cursorPanelShown
        }
    }

    /// Same check under the name the ActivityMonitor rewrite reads.
    func isShown(_ provider: AlertEngine.Provider) -> Bool {
        effectiveVisible(provider: provider)
    }
}
