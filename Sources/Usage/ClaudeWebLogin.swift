import AppKit
import CryptoKit
import Foundation
import Network

/// In-app Claude Code login using the same PKCE + loopback-callback flow the
/// `claude` CLI uses for a local sign-in. We open the real authorize page in
/// the user's default browser (so their existing claude.ai session is reused —
/// usually one click), and catch the OAuth redirect on a short-lived local
/// HTTP server, so the whole thing completes without a Terminal window and
/// without the user copy-pasting a code back. On success the fresh, fully-scoped
/// token pair is written to the `Claude Code-credentials` keychain item via
/// `ClaudeCredentials`, which is exactly what a `claude /login` would have done.
///
/// Why this exists: the previous re-auth spawned `claude auth login` in Terminal,
/// which blocks on an interactive "Paste code here" prompt (its browser callback
/// lands on a platform.claude.com web page, not a localhost listener), so it
/// never completed unattended and the usage tile stayed stuck. This flow removes
/// the paste step entirely by owning the loopback listener ourselves.
/// `@unchecked Sendable`: every mutable field is only ever touched on `queue`
/// (the listener callbacks, the timeout, and the single continuation resume all
/// run there), so the type is thread-safe by construction even though the
/// compiler can't prove it.
final class ClaudeWebLogin: @unchecked Sendable {
    static let shared = ClaudeWebLogin()

    enum Outcome {
        case success
        case failed(String)
        case canceled
    }

    /// All listener callbacks, timeout, and the single continuation resume are
    /// serialized on this queue, so a plain `finished` flag is enough to
    /// guarantee we resume exactly once.
    private let queue = DispatchQueue(label: "dev.agentisland.claude-web-login")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    private var verifier = ""
    private var state = ""
    private var redirectURI = ""
    private var timeout: DispatchWorkItem?
    private var onAuthorizeURL: ((URL) -> Void)?
    private var target: ClaudeLoginBrowserTarget = .systemDefault

    /// Runs the full flow and resolves once the browser round-trip completes,
    /// times out (~3 min one-click; 10 min once the link is copied for a
    /// manual paste), or fails to start. Safe to call again afterwards.
    /// `target` picks which browser/profile the authorize page opens in —
    /// the loopback callback accepts whichever browser ends up loading it.
    /// `onAuthorizeURL` fires on the main thread with the authorize URL the
    /// moment it exists — the UI surfaces it as a copyable link so users
    /// whose Claude session lives in a different browser profile can paste
    /// it there.
    func start(
        target: ClaudeLoginBrowserTarget = .systemDefault,
        onAuthorizeURL: ((URL) -> Void)? = nil
    ) async -> Outcome {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                self?.target = target
                self?.onAuthorizeURL = onAuthorizeURL
                self?.begin(cont)
            }
        }
    }

    /// Re-arms the round-trip timeout to 10 minutes. Called when the user
    /// copies the login link — finding the right profile, pasting, and
    /// signing in takes longer than the one-click default-browser path,
    /// and a 3-minute cutoff killed the flow mid-paste.
    func extendTimeoutForManualPaste() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.timeout?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.finish(.failed("login timed out")) }
            self.timeout = item
            self.queue.asyncAfter(deadline: .now() + 600, execute: item)
        }
    }

    // MARK: - Flow

    private func begin(_ cont: CheckedContinuation<Outcome, Never>) {
        finished = false
        continuation = cont
        verifier = Self.randomURLSafe(32)
        state = Self.randomURLSafe(16)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            finish(.failed("could not open local callback server"))
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener?.port?.rawValue else {
                    self.finish(.failed("no callback port"))
                    return
                }
                self.redirectURI = "http://localhost:\(port)/callback"
                self.openAuthorizePage(challenge: challenge)
                self.armTimeout()
            case .failed(let error):
                self.finish(.failed("callback server failed: \(error)"))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func openAuthorizePage(challenge: String) {
        guard var comps = URLComponents(string: ClaudeCredentials.authorizeURLBase) else {
            finish(.failed("bad authorize base"))
            return
        }
        // `code=true` rides BOTH of the CLI's variants — its localhost
        // loopback URL and its paste URL carry it identically (captured
        // live from `claude setup-token`, 2026-08-08). An earlier theory
        // here called it a paste-flow selector and dropped it; wrong.
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeCredentials.oauthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ClaudeCredentials.loginScopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps.url else {
            finish(.failed("bad authorize URL"))
            return
        }
        let publish = onAuthorizeURL
        let target = self.target
        DispatchQueue.main.async {
            publish?(url)
            Self.open(url, using: target)
        }
    }

    /// Routes the authorize URL to the chosen destination. `.copyOnly` opens
    /// nothing — the store copies the published URL to the pasteboard
    /// instead. Chromium targets launch a fresh app instance (`open -na`
    /// semantics) because handing the URL to an already-running browser
    /// ignores the profile/incognito arguments.
    private static func open(_ url: URL, using target: ClaudeLoginBrowserTarget) {
        switch target {
        case .copyOnly:
            break
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .chromiumProfile(let appURL, let profileDirectory):
            openChromium(url, appURL: appURL, arguments: ["--profile-directory=\(profileDirectory)"])
        case .chromiumIncognito(let appURL):
            openChromium(url, appURL: appURL, arguments: ["--incognito"])
        }
    }

    private static func openChromium(_ url: URL, appURL: URL, arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            // The picked browser vanished between detection and click — a
            // default-browser open beats a dead click.
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    private func armTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.finish(.failed("login timed out")) }
        timeout = item
        // Ten minutes, same as the manual-paste path. The old 180s assumed a
        // signed-in browser and a single Authorize click; a fresh incognito
        // sign-in via email code (owner's flow — the account lives in no
        // local browser) takes minutes, and the timer expiring mid-login
        // killed the listener before the redirect landed (owner repro,
        // 2026-08-08).
        queue.asyncAfter(deadline: .now() + 600, execute: item)
    }

    // MARK: - Callback

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first,
                  let rawPath = requestLine.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: "http://localhost\(rawPath)"),
                  comps.path == "/callback" else {
                // Favicon or an unrelated probe — answer politely, keep waiting.
                self.send(conn, ok: false)
                return
            }
            let items = comps.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

            if let error = value("error") {
                self.send(conn, ok: false)
                self.finish(.failed(error))
                return
            }
            guard let code = value("code"), value("state") == self.state else {
                self.send(conn, ok: false)
                self.finish(.failed("state mismatch"))
                return
            }

            Task {
                let ok = await ClaudeCredentials.completeWebLogin(
                    code: code,
                    codeVerifier: self.verifier,
                    redirectURI: self.redirectURI,
                    state: self.state
                )
                self.send(conn, ok: ok)
                if ok {
                    DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
                    self.finish(.success)
                } else {
                    self.finish(.failed("token exchange failed"))
                }
            }
        }
    }

    private func send(_ conn: NWConnection, ok: Bool) {
        let emoji = ok ? "✅" : "⚠️"
        // Localized — this page was hardcoded Chinese and leaked into the
        // English UI (owner report, 1.7.2).
        let title = ok ? L10n.tr("Connected to Claude") : L10n.tr("Login incomplete")
        let note = ok
            ? L10n.tr("Authentication succeeded — close this page and return to Agent Island")
            : L10n.tr("Please return to Agent Island and try again")
        let body = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Agent Island</title></head>\
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#0b0f0e;color:#e8f0ee;font-family:-apple-system,system-ui,sans-serif">\
        <div style="text-align:center"><div style="font-size:46px;margin-bottom:14px">\(emoji)</div>\
        <div style="font-size:19px;font-weight:600">\(title)</div>\
        <div style="margin-top:8px;color:#8a9a95">\(note)</div></div></body></html>
        """
        let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ outcome: Outcome) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.timeout?.cancel()
            self.timeout = nil
            self.listener?.cancel()
            self.listener = nil
            self.onAuthorizeURL = nil
            let cont = self.continuation
            self.continuation = nil
            cont?.resume(returning: outcome)
        }
    }

    // MARK: - PKCE helpers

    /// S256 challenge for a verifier — shared with the paste flow.
    static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
