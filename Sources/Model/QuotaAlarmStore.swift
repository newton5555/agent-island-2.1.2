import Foundation

/// Whether hitting 100% on a 5-hour or weekly window raises the full-screen
/// "out of quota until <time>" alarm. Some people only want auto-resume and
/// treat the quota popup as low-priority — turning this off silences the
/// exhaustion alarm while leaving turn alarms untouched. Default ON, so the
/// pre-setting behavior is preserved for everyone who never opens Settings.
@MainActor
final class QuotaAlarmStore: ObservableObject {
    static let shared = QuotaAlarmStore()

    private static let key = "AgentIsland.quotaAlarmEnabled"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        // Missing key → ON (bool(forKey:) would default false and silence it
        // for existing users who never touched the setting).
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
