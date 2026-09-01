import Foundation

/// Reads Antigravity's quota from its local language server. Display-only —
/// no transcript monitoring, no alarms live here.
///
/// Everything here talks to 127.0.0.1. The cloud endpoints this file used to
/// call are gone for consumer accounts: verified 2026-08-08 against a real
/// login, `loadCodeAssist` answers `UNSUPPORTED_CLIENT` with a note to
/// migrate to Antigravity, and the only cloud quota that still answers is the
/// legacy Code Assist pool, which reports models the CLI never runs.
enum AntigravityUsageFetcher {
    enum Outcome {
        case success(AntigravityQuotaSnapshot)
        /// Signed in, but nothing is listening — Antigravity holds its quota
        /// in-process, so a closed app means no numbers. Not an error, and
        /// not a reason to drop the last good snapshot.
        case notRunning
        case failed(String)
        /// No credential anywhere — Antigravity never signed in here.
        case notInstalled
    }

    static func fetch() async -> Outcome {
        switch AntigravityCredentials.detect() {
        case .notInstalled, .signedOut: return .notInstalled
        case .signedIn: break
        }
        guard let port = await AntigravityLanguageServer.discover() else { return .notRunning }

        guard let quota = await callWithCSRFRetry("RetrieveUserQuotaSummary", port: port) else {
            return .notRunning
        }
        guard quota.status == 200 else {
            return .failed(L10n.tr("quota unavailable (HTTP %d)", quota.status))
        }
        guard let parsed = AntigravityQuotaParser.parseQuotaSummary(quota.body) else {
            return .failed(L10n.tr("could not read the quota reply"))
        }

        // Identity is a second call and a lesser prize: losing it costs a
        // tier badge, not the numbers.
        var profile: AntigravityQuotaParser.UserProfile?
        if let status = await callWithCSRFRetry("GetUserStatus", port: port), status.status == 200 {
            profile = AntigravityQuotaParser.parseUserStatus(status.body)
        }

        return .success(AntigravityQuotaSnapshot(
            buckets: parsed.buckets,
            tierID: profile?.tierID,
            tierLabel: profile?.tierLabel,
            note: parsed.note
        ))
    }

    /// The account email, for the strip's hover card. Same call as the tier,
    /// kept separate so the store can ask for it without a quota round-trip.
    static func accountEmail() async -> String? {
        guard let port = await AntigravityLanguageServer.discover(),
              let reply = await callWithCSRFRetry("GetUserStatus", port: port),
              reply.status == 200 else { return nil }
        return AntigravityQuotaParser.parseUserStatus(reply.body)?.email
    }

    /// The CLI's server wants no CSRF token and is the verified path. The
    /// desktop IDE gates on one, so a 401 — and only a 401 — earns a single
    /// retry with a token lifted from the owning process's argv.
    private static func callWithCSRFRetry(
        _ method: String,
        port: UInt16
    ) async -> AntigravityLanguageServer.Reply? {
        guard let reply = await AntigravityLanguageServer.call(method, port: port) else { return nil }
        guard reply.status == 401 else { return reply }
        for pid in AntigravityLanguageServer.antigravityProcesses() {
            guard AntigravityLanguageServer.listeningPorts(pid).contains(port),
                  let token = AntigravityLanguageServer.csrfToken(pid: pid) else { continue }
            return await AntigravityLanguageServer.call(method, port: port, csrfToken: token)
        }
        return reply
    }
}
