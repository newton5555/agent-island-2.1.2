import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginStore: ObservableObject {
    static let shared = LaunchAtLoginStore()

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    private func setEnabled(_ enabled: Bool) {
        // Gatekeeper runs quarantined apps from a randomized read-only path;
        // Background Task Management refuses to register those ("Operation
        // not permitted"), and it never starts working until the app runs
        // from a real location. Tell the user the actual fix instead of
        // relaying the errno string.
        if enabled, Bundle.main.bundlePath.contains("/AppTranslocation/") {
            errorMessage = L10n.tr("Move Agent Island into Applications, then relaunch it and try again")
            refresh()
            return
        }
        do {
            if enabled {
                // Ad-hoc builds get a fresh code signature on every update,
                // which can leave a stale Background Task Management record
                // under our bundle id — register() then fails with
                // "Operation not permitted". Clearing any old record first
                // makes the toggle idempotent.
                try? SMAppService.mainApp.unregister()
                try SMAppService.mainApp.register()
                errorMessage = nil
                if SMAppService.mainApp.status == .requiresApproval {
                    errorMessage = L10n.tr("Allow Agent Island under System Settings → General → Login Items")
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
                errorMessage = nil
            }
        } catch {
            let ns = error as NSError
            if enabled, ns.domain == NSPOSIXErrorDomain, ns.code == 1 {
                // EPERM from BTM: macOS is blocking the registration (stale
                // record, translocation, or the per-app "allow in background"
                // switch). The Login Items pane is where all of those get
                // resolved, so send the user straight there.
                errorMessage = L10n.tr("Allow Agent Island under System Settings → General → Login Items")
                SMAppService.openSystemSettingsLoginItems()
            } else {
                errorMessage = error.localizedDescription
            }
        }
        refresh()
    }
}
