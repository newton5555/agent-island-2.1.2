import Foundation

/// One-click Codex account switching (owner call, 2026-08-08).
///
/// Codex keeps exactly one signed-in account in `~/.codex/auth.json`. This
/// parks a COPY of each account's credentials beside it and swaps the live
/// file on demand — the same thing a person does by hand with `mv`, minus
/// the mistakes. Two modes:
///   - MANUAL — the user picks from the menu, the file swaps.
///   - AUTO (opt-in, off by default) — when the live account's window
///     reads 100%, rotate to the next parked account. Modeled on the
///     open-source codex-auto pool tools, but keyed off the real
///     /wham/usage percentages instead of scraping terminal output for
///     failure text, so it never guesses. `UsageStore` owns the trigger
///     (it sees every fresh reading); this type owns policy + the swap.
enum CodexAccountSwitcher {
    /// A parked account: the label the user gave it plus its stored file.
    struct Account: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let path: String
        /// Account identity read from the stored credentials, when present.
        let email: String?
    }

    private static var codexHome: String { NSString("~/.codex").expandingTildeInPath }
    private static var livePath: String { codexHome + "/auth.json" }
    private static var storeDir: String { codexHome + "/agentisland-accounts" }

    /// Label of the account currently live, matched by credential contents —
    /// nil when the live file matches nothing parked (a fresh login).
    static func activeLabel() -> String? {
        guard let live = try? Data(contentsOf: URL(fileURLWithPath: livePath)) else { return nil }
        return accounts().first { parked in
            (try? Data(contentsOf: URL(fileURLWithPath: parked.path))) == live
        }?.label
    }

    static func accounts() -> [Account] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storeDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { name in
                let path = storeDir + "/" + name
                return Account(
                    label: String(name.dropLast(5)),
                    path: path,
                    email: email(inFileAt: path)
                )
            }
    }

    /// Park the CURRENT login under `label`, so it can be switched back to.
    @discardableResult
    static func parkCurrent(as label: String) -> Bool {
        let clean = sanitize(label)
        guard !clean.isEmpty,
              let live = try? Data(contentsOf: URL(fileURLWithPath: livePath)) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let target = URL(fileURLWithPath: storeDir + "/" + clean + ".json")
            try live.write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            NSLog("AgentIsland: could not park Codex account — %@", error.localizedDescription)
            return false
        }
    }

    /// Make `account` the live Codex login. The outgoing file is parked
    /// first when it matches nothing on disk, so a hand-made login is never
    /// destroyed by a switch.
    @discardableResult
    static func activate(_ account: Account) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: account.path)) else { return false }
        if activeLabel() == nil {
            parkCurrent(as: "previous-\(Int(Date().timeIntervalSince1970))")
        }
        do {
            try data.write(to: URL(fileURLWithPath: livePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: livePath)
            return true
        } catch {
            NSLog("AgentIsland: could not activate Codex account — %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Auto-switch (opt-in)

    private static let autoSwitchKey = "codexAutoSwitchWhenExhausted"

    /// Off by default: silently swapping logins surprises anyone who did
    /// not ask for it, and a mid-session file swap is visible to a running
    /// Codex CLI. The owner flips it on once and forgets it.
    static var autoSwitchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoSwitchKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSwitchKey) }
    }

    /// The next account worth rotating to: parked, not the live one, not
    /// yet tried this exhaustion episode. Stable label order, so rotation
    /// walks the pool deterministically instead of ping-ponging.
    static func rotationCandidate(excluding tried: Set<String>) -> Account? {
        let active = activeLabel()
        return accounts().first { $0.label != active && !tried.contains($0.label) }
    }

    @discardableResult
    static func forget(_ account: Account) -> Bool {
        (try? FileManager.default.removeItem(atPath: account.path)) != nil
    }

    // MARK: - Helpers (unit-tested)

    /// Labels become filenames: keep it to safe characters so a stray "/"
    /// or ".." can never escape the store directory.
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { allowed.contains($0) }
        )).trimmingCharacters(in: .whitespaces).prefix(40).description
    }

    /// Codex writes the account email under `tokens.account_id`-adjacent
    /// fields; read the first email-shaped string so the picker can show who
    /// each parked login belongs to. Never logs the token itself.
    static func email(inJSON object: [String: Any]) -> String? {
        for (_, value) in object {
            if let string = value as? String, string.contains("@"), !string.contains(" ") {
                return string
            }
            if let nested = value as? [String: Any], let found = email(inJSON: nested) {
                return found
            }
        }
        return nil
    }

    private static func email(inFileAt path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return email(inJSON: object)
    }
}
