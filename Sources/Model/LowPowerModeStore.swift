import Foundation
import Combine

/// User preference for the ambient halo + loading sweep, surfaced in
/// Settings as the two visual modes:
///
///   Calm  (`enabled == true`): NO ambient light at all — no halo, no
///   sweep, no hover glow. A clean black pill. Only functional signals
///   remain: approaching-limit amber/red and the attention pulse.
///
///   Vivid (`enabled == false`, the DEFAULT): the halo glow and the orbit
///   sweep run continuously in the chosen glow color; the "Glow color"
///   setting lives under this mode.
///
/// Vivid-by-default in the brand teal is the owner's call (2026-07-16),
/// revising the Calm default of 2026-07-15: with the glow now on-brand and
/// color-choosable, the light IS the identity; Calm stays one click away
/// as the zero-effects escape.
///
/// `effectiveEnabled` ORs the user choice with macOS's system-wide Low
/// Power Mode: system battery saving forces Calm regardless of the picker —
/// same convention Apple's own apps follow.
@MainActor
final class LowPowerModeStore: ObservableObject {
    static let shared = LowPowerModeStore()

    private static let key = "AgentIsland.lowPowerMode"

    /// true = Calm (event-gated effects), false = Vivid (continuous).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    /// Mirrors `ProcessInfo.processInfo.isLowPowerModeEnabled`. Updated
    /// via NSProcessInfoPowerStateDidChange.
    @Published private(set) var systemLowPowerEnabled: Bool

    /// True if either the user opted in OR macOS reports system LPM is on.
    /// Use this in render-gating predicates instead of `enabled` directly.
    var effectiveEnabled: Bool { enabled || systemLowPowerEnabled }

    private var observer: NSObjectProtocol?

    private init() {
        // Vivid unless the user explicitly chose Calm. `bool(forKey:)`
        // returns false for a missing key, which is exactly Vivid — but
        // keep the presence check explicit so the default stays legible
        // (it has flipped once already; see the type comment).
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            self.enabled = false
        } else {
            self.enabled = UserDefaults.standard.bool(forKey: Self.key)
        }
        self.systemLowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                if now != self.systemLowPowerEnabled {
                    self.systemLowPowerEnabled = now
                }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
