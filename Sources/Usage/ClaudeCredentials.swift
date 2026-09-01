import Foundation

/// Deep module owning Claude OAuth credential acquisition: the
/// env → keychain → refresh → rotation-writeback flow, plus the in-app
/// re-auth helpers. The usage fetcher hands it a probe closure (the single
/// `/api/oauth/usage` HTTP call) and `ClaudeCredentials` drives token
/// selection, deciding when to advance sources and when to surface re-auth.
///
/// The asymmetry between token sources is load-bearing:
///   - An env-token scope-insufficient (403) does NOT short-circuit; we
///     still try the keychain token.
///   - A keychain-token (or refreshed-token) scope-insufficient short-circuits
///     to re-auth, because refresh re-issues the same scope set and cannot
///     recover a missing `user:profile`.
enum ClaudeCredentials {
    /// Emitted as `WindowUsage.error` when the keychain token is structurally
    /// valid but missing a scope the Claude usage endpoint now requires
    /// (`user:profile`, added mid-2026). The UI layer matches on this exact
    /// string to swap the error caption for an in-app re-auth button.
    static let reauthRequiredMessage = "re-login: claude /login"
    static let authRequiredMessage = "auth required — run claude"
    /// Shown when a 401'd keychain token could not be refreshed (revoked
    /// refresh token, endpoint failure, timeout). Previously this path fell
    /// out with the generic cold-start caption, leaving users no way to
    /// self-diagnose (#22). Localized at creation like `shortError`'s
    /// "network drop"; the raw key is matched too so recoverability
    /// detection survives a mid-session language switch.
    static let tokenRefreshFailedKey = "token refresh failed — sign in again"
    static var tokenRefreshFailedMessage: String { L10n.tr(tokenRefreshFailedKey) }

    // MARK: - OAuth endpoints (shared by refresh + in-app web login)

    /// Claude Code's public OAuth client. Confirmed from the live `claude`
    /// authorize URL and already used by the refresh path below.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Where `ClaudeWebLogin` sends the browser to sign in.
    ///
    /// This MUST be the claude.ai (subscription) authorize base, not the
    /// Console one. `platform.claude.com` is the DEVELOPER CONSOLE — the
    /// API-key product with its own separate accounts; sending a Max/Pro
    /// subscriber there lands them on "Build on the Claude Platform" with
    /// a sign-up form and no authorization code (owner screenshot,
    /// 2026-08-08). The CLI keeps both bases and picks this one for a
    /// subscription login: `CLAUDE_AI_AUTHORIZE_URL` in its config.
    static let authorizeURLBase = "https://claude.com/cai/oauth/authorize"
    /// Token endpoint for both refresh and authorization_code exchange.
    static let tokenURLString = "https://platform.claude.com/v1/oauth/token"

    /// Anthropic's own paste-flow redirect. The pairing is deliberately
    /// CROSS-origin: authorize lives on claude.com/cai (subscription) while
    /// the code-display page lives on platform.claude.com — both URLs sit
    /// verbatim in the claude CLI 2.1.153 binary, which is the ground
    /// truth here. Selected by `code=true`; the browser lands on a page
    /// showing a code to copy back — no loopback listener, no
    /// browser-profile guessing, no Google account required.
    static let pasteRedirectURI = "https://platform.claude.com/oauth/code/callback"

    /// Builds the paste-flow authorize URL and its PKCE verifier. Caller
    /// opens the URL, the user copies the code, then calls
    /// `completePasteLogin` with it.
    static func pasteLoginRequest() -> (url: URL, verifier: String, state: String)? {
        let verifier = ClaudeWebLogin.randomURLSafe(32)
        let state = ClaudeWebLogin.randomURLSafe(16)
        let challenge = ClaudeWebLogin.pkceChallenge(for: verifier)
        guard var comps = URLComponents(string: authorizeURLBase) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: oauthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: pasteRedirectURI),
            URLQueryItem(name: "scope", value: loginScopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps.url else { return nil }
        return (url, verifier, state)
    }

    /// Exchanges a hand-pasted authorization code. Anthropic's success page
    /// shows it as `<code>#<state>`; accept either form.
    static func completePasteLogin(pasted: String, verifier: String, state: String) async -> Bool {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts[0])
        let returnedState = parts.count > 1 ? String(parts[1]) : state
        guard let tokens = await exchangeAuthorizationCode(
            code: code, codeVerifier: verifier,
            redirectURI: pasteRedirectURI, state: returnedState
        ) else { return false }
        return persistFreshLogin(tokens)
    }
    /// EXACTLY the six scopes `claude /login` sends — captured verbatim
    /// from the running CLI by intercepting the authorize URL it opens
    /// (2026-08-08). An earlier round cut this to two based on
    /// `setup-token`, which is a DIFFERENT flow with a smaller scope set;
    /// the subscription /login the app mimics needs all six, and the
    /// server rejects a partial set as "Invalid request format" AFTER the
    /// user signs in. This is the exact string, order included.
    static let loginScopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    static func isAuthRecoverableError(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == authRequiredMessage || message == reauthRequiredMessage
            || message == tokenRefreshFailedKey || message == tokenRefreshFailedMessage
    }

    /// Outcome of a single usage-endpoint probe against one token. The fetcher
    /// owns the HTTP + parsing and reports back through this; `ClaudeCredentials`
    /// interprets it to decide whether to advance to the next token source.
    enum ProbeOutcome {
        case success(AppUsage)
        case rateLimited
        case unauthorized
        /// Token is structurally valid but missing a scope the server now requires
        /// (Anthropic added `user:profile` to /api/oauth/usage in mid-2026).
        /// Refresh won't help — only a fresh `claude /login` re-issues with the
        /// expanded scope set.
        case scopeInsufficient
        case otherError(String)
    }

    /// Resolution of the full token flow once probed against the usage endpoint.
    enum Resolution {
        /// A token was accepted by the probe; carries the parsed usage.
        case usage(AppUsage)
        /// A fresh `claude /login` is required (scope-insufficient on a keychain
        /// or refreshed token). Carries the exact UI-facing error message.
        case reauthRequired(String)
        /// No token source produced usage; carries the last error seen, which
        /// the fetcher renders as the error caption.
        case failed(String)
    }

    // MARK: - Resolution

    /// Three token sources, in order of freshness:
    ///   1. CLAUDE_CODE_OAUTH_TOKEN — set by Claude Desktop for child
    ///      processes; always fresh while Desktop is running.
    ///   2. macOS Keychain item "Claude Code-credentials" — stable across
    ///      relaunches; the access token expires after ~8h, after which
    ///      we fall through to refresh.
    ///   3. platform.claude.com/v1/oauth/token refresh — Anthropic
    ///      rotates the refresh_token on every call (the response carries
    ///      a new pair). We must persist that new pair back to the keychain
    ///      via writeClaudeCreds, otherwise Claude Code itself 401s on its
    ///      next refresh because the keychain still holds the now-revoked
    ///      old token. (The OAuth host migrated from console.anthropic.com
    ///      to platform.claude.com — old URL still resolves but is not the
    ///      canonical issuer for fresh tokens.)
    static func resolveUsage(probe: (_ token: String, _ plan: String?) async -> ProbeOutcome) async -> Resolution {
        var lastError = authRequiredMessage
        // Plan tier ships in the keychain dict only — Anthropic's usage
        // endpoint doesn't echo it back. We peek the keychain even on the
        // env-token path so the chip works for users whose token came from
        // Claude Desktop's child env rather than from `claude /login`.
        let cachedCreds = readClaudeCreds()
        let plan = cachedCreds?.subscriptionType

        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !envToken.isEmpty {
            switch await probe(envToken, plan) {
            case .success(let u):       return .usage(u)
            case .rateLimited:          lastError = "rate limited"
            case .unauthorized:         break
            case .scopeInsufficient:    lastError = reauthRequiredMessage
            case .otherError(let e):    lastError = e
            }
        }

        if let creds = cachedCreds {
            var keychainTokensDead = false
            switch await probe(creds.accessToken, plan) {
            case .success(let u):       return .usage(u)
            case .rateLimited:          lastError = "rate limited"
            case .unauthorized:         keychainTokensDead = true
            // Refresh hands back tokens with the same scope set, so it cannot
            // recover from a missing-scope 403. Bail out and surface the only
            // remediation that actually works.
            case .scopeInsufficient:    return .reauthRequired(reauthRequiredMessage)
            case .otherError(let e):    lastError = e
            }

            if let refreshed = await refreshClaudeToken(refreshToken: creds.refreshToken) {
                keychainTokensDead = false
                // Anthropic's OAuth token endpoint rotates the refresh token,
                // so the one we just used is now invalidated server-side. If we
                // do not write the new pair back, Claude Code's next refresh
                // attempt 401s and forces the user to re-run /login. Persist
                // the rotated tokens so the keychain stays in sync with what
                // the server considers valid.
                var updated = creds.oauth
                updated["accessToken"] = refreshed.accessToken
                updated["refreshToken"] = refreshed.refreshToken
                updated["expiresAt"] = refreshed.expiresAt
                writeClaudeCreds(service: creds.service, account: creds.account, oauth: updated)

                switch await probe(refreshed.accessToken, plan) {
                case .success(let u):       return .usage(u)
                case .rateLimited:          lastError = "rate limited"
                case .unauthorized:         break
                case .scopeInsufficient:    return .reauthRequired(reauthRequiredMessage)
                case .otherError(let e):    lastError = e
                }
            } else {
                // The keychain token 401'd AND the refresh grant failed —
                // without this the caption stayed on the cold-start "auth
                // required" text forever (#22). The precise failure reason
                // is in the log; the caption carries the remediation.
                lastError = tokenRefreshFailedMessage
            }

            // This entry's tokens are dead end to end. Forget it so the next
            // poll re-runs discovery — a revoked account's leftover entry
            // must not shadow a fresh login that minted a NEW suffixed item.
            if keychainTokensDead || lastError == tokenRefreshFailedMessage {
                invalidateServiceCache()
            }
        }

        return .failed(lastError)
    }

    // MARK: - Keychain

    private struct ClaudeCreds {
        let service: String
        let account: String
        let accessToken: String
        let refreshToken: String
        let oauth: [String: Any]
        let subscriptionType: String?
    }

    /// See `ClaudeKeychainDiscovery` for the naming story (2.x suffixed
    /// items, MCP-cache lookalikes, freshest-wins).
    private static var baseService: String { ClaudeKeychainDiscovery.baseService }
    private static let cachedServiceKey = "AgentIsland.claudeKeychainService"

    /// Forget the remembered item name so the next read re-runs discovery.
    /// Called when the remembered entry's tokens stop answering — a revoked
    /// account's entry can shadow a fresh login that minted a NEW suffix.
    static func invalidateServiceCache() {
        UserDefaults.standard.removeObject(forKey: cachedServiceKey)
    }

    /// Suffixed candidates from the keychain listing. Metadata only — no
    /// `-d`, no secrets — and only runs when the remembered/unsuffixed
    /// items both miss, so steady state never pays for the dump.
    private static func discoverSuffixedServices() -> [String] {
        guard let data = runSecurity(["dump-keychain"], timeout: 20) else { return [] }
        return ClaudeKeychainDiscovery.parseServiceNames(
            fromDump: String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs `/usr/bin/security` with a hard deadline and returns stdout on
    /// exit 0, nil otherwise.
    ///
    /// `security` can block FOREVER behind a keychain-authorization dialog
    /// that never surfaces. Observed 2026-07-17: nine 6-hour-old children,
    /// one per refresh tick — each parked its Swift-concurrency thread in
    /// `waitUntilExit`, and the 90s "wedged fetch" restart spawned the next
    /// one, until the whole cooperative pool was starved and every async
    /// path in the app (Codex fetch included) froze while the UI kept
    /// animating. The watchdog terminates the child at the deadline so the
    /// caller degrades to its next token source instead of eating a thread.
    ///
    /// stdout is drained BEFORE waitUntilExit — the reverse order deadlocks
    /// when the child fills the pipe buffer.
    private static func runSecurity(_ arguments: [String], timeout: TimeInterval = 10) -> Data? {
        let task = Process()
        task.launchPath = "/usr/bin/security"
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem {
            if task.isRunning {
                NSLog("AgentIsland: security %@ exceeded %.0fs — terminating", arguments.first ?? "?", timeout)
                task.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return data
    }

    /// Reads the freshest Claude login the keychain holds. Fast path is the
    /// remembered item, then the unsuffixed name (what our web login
    /// writes); only when both miss does the suffixed-item discovery run.
    /// Returns nil silently on any error — the caller falls through to the
    /// next token source. Captures the item name and account so a refresh
    /// writes back to the SAME entry (rotating a different entry's tokens
    /// would 401 the CLI's next refresh).
    private static func readClaudeCreds() -> ClaudeCreds? {
        var fastPath: [String] = []
        if let cached = UserDefaults.standard.string(forKey: cachedServiceKey) {
            fastPath.append(cached)
        }
        if !fastPath.contains(baseService) { fastPath.append(baseService) }
        if let hit = freshestCreds(in: fastPath) { return remember(hit) }

        let suffixed = discoverSuffixedServices().filter { !fastPath.contains($0) }
        guard let hit = freshestCreds(in: suffixed) else { return nil }
        return remember(hit)
    }

    private static func remember(_ creds: ClaudeCreds) -> ClaudeCreds {
        UserDefaults.standard.set(creds.service, forKey: cachedServiceKey)
        return creds
    }

    private static func freshestCreds(in services: [String]) -> ClaudeCreds? {
        ClaudeKeychainDiscovery.pickFreshest(services.compactMap { service in
            guard let creds = readCreds(service: service) else { return nil }
            let expires = (creds.oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            return (creds, expires)
        })
    }

    private static func readCreds(service: String) -> ClaudeCreds? {
        guard let account = readClaudeKeychainMetadataValue("acct", service: service) else { return nil }

        guard let data = runSecurity([
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ]) else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let jsonData = raw.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = outer["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String else { return nil }
        let plan = oauth["subscriptionType"] as? String
        return ClaudeCreds(service: service, account: account, accessToken: access, refreshToken: refresh, oauth: oauth, subscriptionType: plan)
    }

    /// The CLI-login fallback polls this every 3s while a login runs. A
    /// fresh 2.x login may mint a brand-new suffixed item, so on a miss the
    /// discovery re-runs — the stamp flipping nil → non-nil is exactly the
    /// "login landed" signal that poll wants.
    static func keychainModificationStamp() -> String? {
        var candidates: [String] = []
        if let cached = UserDefaults.standard.string(forKey: cachedServiceKey) {
            candidates.append(cached)
        }
        if !candidates.contains(baseService) { candidates.append(baseService) }
        for service in candidates {
            if let stamp = readClaudeKeychainMetadataValue("mdat", service: service) { return stamp }
        }
        for service in discoverSuffixedServices() where !candidates.contains(service) {
            if let stamp = readClaudeKeychainMetadataValue("mdat", service: service) { return stamp }
        }
        return nil
    }

    /// `security add-generic-password -U` requires the original account name
    /// to find and update the existing item. The metadata listing puts it on
    /// a line shaped like: `    "acct"<blob>="ericpark"` — pull the value
    /// from inside the trailing quotes. Returns nil if the line is missing
    /// or the value is `<NULL>`.
    private static func readClaudeKeychainMetadataValue(_ key: String, service: String) -> String? {
        guard let data = runSecurity(["find-generic-password", "-s", service]) else {
            return nil
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"\(key)\"") else { continue }
            guard let inner = lastQuotedValue(afterEqualsIn: trimmed) else { return nil }
            return inner.isEmpty ? nil : String(inner)
        }
        return nil
    }

    private static func lastQuotedValue(afterEqualsIn line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let rhs = line[line.index(after: eq)...]
        guard let end = rhs.lastIndex(of: "\"") else { return nil }
        let beforeEnd = rhs[..<end]
        guard let start = beforeEnd.lastIndex(of: "\"") else { return nil }
        return String(rhs[rhs.index(after: start)..<end])
    }

    /// Updates the given credentials keychain item in place (`-U` flag) so
    /// the rotated OAuth tokens persist — always the SAME item the tokens
    /// were read from: the CLI's next refresh reads its own entry, and a
    /// rotation written anywhere else would leave it holding a revoked
    /// token. Best-effort: a failure here means the next AgentIsland
    /// refresh will pay the same rotation cost again, but Claude Code
    /// itself recovers because the fresh refresh_token we wrote — if the
    /// write actually landed — works.
    /// Note: passing the JSON via `-w` makes it briefly visible in `ps` to
    /// processes owned by the same user. The keychain itself is gated by
    /// the same trust boundary, so this is not a meaningful regression.
    @discardableResult
    private static func writeClaudeCreds(service: String, account: String, oauth: [String: Any]) -> Bool {
        let payload: [String: Any] = ["claudeAiOauth": oauth]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("AgentIsland: failed to serialize rotated Claude tokens for keychain write")
            return false
        }

        guard runSecurity([
            "add-generic-password",
            "-U",
            "-s", service,
            "-a", account,
            "-w", json,
        ]) != nil else {
            NSLog("AgentIsland: failed to write rotated Claude tokens to keychain")
            return false
        }
        return true
    }

    // MARK: - Refresh

    private struct RefreshedTokens {
        let accessToken: String
        let refreshToken: String
        /// Milliseconds since epoch — matches Claude Code's keychain shape.
        let expiresAt: Int64
    }

    /// Anthropic's token endpoint rotates the refresh_token on every call,
    /// so the response always carries a new pair. Caller is responsible for
    /// persisting them; otherwise the keychain falls out of sync with the
    /// server and any downstream consumer (Claude Code, Claude Desktop)
    /// 401s on its next refresh.
    private static func refreshClaudeToken(refreshToken: String) async -> RefreshedTokens? {
        var req = URLRequest(url: URL(string: tokenURLString)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25 // never let a wedged tunnel hang the poll loop
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                NSLog("AgentIsland: Claude token refresh failed — HTTP %d", status)
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String,
                  let refresh = obj["refresh_token"] as? String else {
                NSLog("AgentIsland: Claude token refresh failed — malformed token response")
                return nil
            }
            // expires_in is seconds; Claude Code stores absolute ms.
            let expiresIn = (obj["expires_in"] as? Double) ?? 28_800
            let expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
            return RefreshedTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        } catch {
            let nsError = error as NSError
            NSLog("AgentIsland: Claude token refresh failed — %@ %ld", nsError.domain, nsError.code)
            return nil
        }
    }

    // MARK: - Web login (PKCE loopback)

    /// Second half of the loopback login: exchange the authorization code for a
    /// fresh token pair and persist it to the keychain. Called by
    /// `ClaudeWebLogin` after it catches the OAuth redirect. Returns true only
    /// if both the exchange and the keychain write succeed.
    static func completeWebLogin(code: String, codeVerifier: String, redirectURI: String, state: String) async -> Bool {
        guard let tokens = await exchangeAuthorizationCode(
            code: code, codeVerifier: codeVerifier, redirectURI: redirectURI, state: state
        ) else { return false }
        return persistFreshLogin(tokens)
    }

    /// Mirrors `refreshClaudeToken` but with grant_type=authorization_code, for
    /// the very first token pair from a fresh browser sign-in.
    private static func exchangeAuthorizationCode(
        code: String, codeVerifier: String, redirectURI: String, state: String
    ) async -> RefreshedTokens? {
        var req = URLRequest(url: URL(string: tokenURLString)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "client_id": oauthClientID,
            "redirect_uri": redirectURI,
            "state": state,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String,
                  let refresh = obj["refresh_token"] as? String else { return nil }
            let expiresIn = (obj["expires_in"] as? Double) ?? 28_800
            let expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
            return RefreshedTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        } catch {
            return nil
        }
    }

    /// Writes a freshly-minted token pair into the credentials keychain
    /// item, preserving the existing item name, account, and any auxiliary
    /// fields (subscriptionType, scopes) so downstream consumers keep
    /// working. Seeds a minimal dict under the unsuffixed name if no item
    /// exists yet — that name stays first in the read order, so an in-app
    /// login lands somewhere every future read finds.
    @discardableResult
    private static func persistFreshLogin(_ tokens: RefreshedTokens) -> Bool {
        let existing = readClaudeCreds()
        let service = existing?.service ?? baseService
        let account = existing?.account ?? NSUserName()
        var oauth = existing?.oauth ?? [:]
        oauth["accessToken"] = tokens.accessToken
        oauth["refreshToken"] = tokens.refreshToken
        oauth["expiresAt"] = tokens.expiresAt
        let ok = writeClaudeCreds(service: service, account: account, oauth: oauth)
        if ok { UserDefaults.standard.set(service, forKey: cachedServiceKey) }
        return ok
    }

    // MARK: - In-app re-auth

    /// True only when the in-app "Re-authenticate" button can actually spawn
    /// the Claude Code login helper. We only require the CLI here: a missing
    /// keychain item is itself a valid reason to offer login, and the CLI owns
    /// writing the `Claude Code-credentials` item after OAuth succeeds. We
    /// deliberately do not shell out to `which`; LaunchServices gives the app
    /// a stripped PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so a `which` call
    /// would miss every Homebrew/nvm/Bun install and the button would silently
    /// never appear for most users.
    static func canPromptReauth() -> Bool {
        return locateClaudeBinary() != nil
    }

    /// Opens a visible Terminal running `claude auth login`. A detached GUI
    /// `Process` can strand users when the CLI expects an interactive TTY or
    /// prints a browser URL instead of opening one. A temporary `.command`
    /// file avoids AppleScript automation prompts while still giving the CLI
    /// a real Terminal session.
    @discardableResult
    static func spawnReauth() -> Bool {
        guard let path = locateClaudeBinary() else { return false }
        let command = "\(shellQuoted(path)) auth login"
        let script = """
        #!/bin/zsh
        echo "Agent Island is opening Claude Code login..."
        exec \(command)
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentIsland", isDirectory: true)
        let file = dir.appendingPathComponent("claude-auth-login.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            NSLog("AgentIsland: failed to prepare claude auth login command: %@", error.localizedDescription)
            return false
        }

        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Terminal", file.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            return true
        } catch {
            NSLog("AgentIsland: failed to spawn claude auth login: %@", error.localizedDescription)
            return false
        }
    }

    private static func shellQuoted(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Common install locations for the Claude Code CLI, in priority order.
    /// nvm is special-cased because its bin path embeds a node version we
    /// can't predict. We don't probe Volta/asdf/etc.; users with exotic
    /// installs will fall through to the manual `claude /login` path.
    private static func locateClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            // Sort descending so the newest installed Node version wins —
            // matches what `nvm use` would resolve to in practice.
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
