import AppKit

/// Which terminal a resume command opens in, and how it gets there.
///
/// The old flow hardcoded Terminal.app, so a Ghostty or iTerm user clicking
/// an alarm got a stock Terminal window from nowhere (user report relayed by
/// the owner, 2026-08-09). The terminal someone actually uses is not a thing
/// to guess — it is observable: every alarm click that finds a live CLI
/// session walks the process tree to the app hosting it, and when that app
/// is a terminal emulator it is remembered here. The remembered terminal
/// then receives any future spawn, so the choice keeps tracking reality
/// without a settings knob.
enum TerminalLauncher {
    /// Emulators recognized for remembering and for the cold-start scan.
    /// Fronting a live session works for ANY host app (VS Code included);
    /// this list only decides where a NEW window may be spawned — an IDE
    /// that happens to host a shell is not a spawn target.
    static let knownTerminals: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    private static let preferredKey = "AgentIsland.preferredTerminalBundleID"

    /// Called from the front-running paths whenever a live CLI session's
    /// hosting app resolves. Non-terminals (IDEs) are ignored on purpose.
    static func remember(bundleID: String?) {
        guard let bundleID, knownTerminals.contains(bundleID) else { return }
        UserDefaults.standard.set(bundleID, forKey: preferredKey)
    }

    /// The terminal a fresh resume window should open in.
    ///
    /// Remembered observation first. Cold start falls back to whichever
    /// known terminal is running — preferring a third-party one over
    /// Terminal.app, because someone with Ghostty open next to the stock
    /// Terminal almost always lives in Ghostty. Nothing running, nothing
    /// remembered: Terminal.app, the pre-2.1.2 behavior.
    static func spawnTarget() -> String {
        if let stored = UserDefaults.standard.string(forKey: preferredKey),
           knownTerminals.contains(stored),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: stored) != nil {
            return stored
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for candidate in knownTerminals where candidate != "com.apple.Terminal" {
            if running.contains(candidate) { return candidate }
        }
        return "com.apple.Terminal"
    }

    /// Runs `command` in a fresh window of the preferred terminal. Returns
    /// false when there is no verified strategy for that terminal — the
    /// caller falls back to the Terminal.app path, which is the strongest
    /// "a window definitely appears" guarantee we have.
    ///
    /// Strategies are per-app and only the tested ones ship (real installs,
    /// 2026-08-09). No AppleScript for third parties: it would raise a
    /// fresh automation-consent dialog per app, and Ghostty has no
    /// scripting interface anyway.
    ///
    /// - iTerm2 executes an opened `.command` file natively (verified,
    ///   3.6.11).
    /// - Ghostty does NOT execute `.command` files (verified — it just
    ///   opened a plain window), but its own documented macOS route works:
    ///   a new app instance with `-e <cmd>` arguments (verified, 1.3.1,
    ///   including while another Ghostty instance is running).
    /// - Warp/kitty/Alacritty/WezTerm/Hyper: no route verified yet; they
    ///   still get live-session fronting, and spawns fall back to
    ///   Terminal.app.
    @MainActor
    static func spawnInPreferredTerminal(command: String, executable: String, sessionId: String) -> Bool {
        switch spawnTarget() {
        case "com.mitchellh.ghostty":
            return spawnGhostty(command: command)
        case "com.googlecode.iterm2":
            guard let appURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.googlecode.iterm2"),
                  let file = writeCommandFile(
                    command: command, executable: executable, sessionId: sessionId)
            else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.hide(nil) }
            }
            return true
        default:
            return false
        }
    }

    /// `open -na Ghostty.app --args -e …`, as NSWorkspace calls. The new
    /// instance is required: arguments only reach Ghostty at launch, so
    /// without it a running Ghostty would just come forward and silently
    /// drop the command. The command travels as argv, never through a
    /// shell, so no quoting can break it.
    @MainActor
    private static func spawnGhostty(command: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.mitchellh.ghostty") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-e", "/bin/zsh", "-c", command]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.hide(nil) }
        }
        return true
    }

    /// The same .command scratch file the Terminal fallback uses, shared so
    /// both paths overwrite one file per session instead of littering.
    static func writeCommandFile(command: String, executable: String, sessionId: String) -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root
            .appendingPathComponent("AgentIsland", isDirectory: true)
            .appendingPathComponent("ResumeCommands", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                "resume-\(safeComponent(executable))-\(safeComponent(sessionId)).command")
            let body = """
            #!/bin/zsh
            \(command)
            """
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    private static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let text = String(scalars)
        return text.isEmpty ? "session" : String(text.prefix(80))
    }
}
