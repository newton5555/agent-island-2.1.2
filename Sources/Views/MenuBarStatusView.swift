import SwiftUI
import AppKit

struct MenuBarStatusLabel: View {
    @ObservedObject private var monitor = ActivityMonitor.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private var icon: String {
        let state = strongestState
        switch state {
        case .authRequired: return "person.crop.circle.badge.exclamationmark"
        case .rateLimited: return "hourglass"
        case .stalled: return "pause.circle.fill"
        case .needsYou: return "bell.fill"
        case .working: return "sparkles"
        case .idle: return "circle"
        }
    }

    private var label: String {
        let state = strongestState
        switch state {
        case .authRequired: return "AUTH"
        case .rateLimited: return "LIMIT"
        case .stalled: return "PAUSE"
        case .needsYou: return "TURN"
        case .working: return "RUN"
        case .idle: return "AI"
        }
    }

    private var strongestState: ActivityMonitor.State {
        ProviderVisibilityStore.shared.slotProviders
            .map { monitor.state(for: $0.alertProvider) }
            .max { $0.rawValue < $1.rawValue } ?? .idle
    }
}

struct MenuBarStatusView: View {
    @ObservedObject private var monitor = ActivityMonitor.shared
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        Text("Agent Island")
        Divider()
        // One line per SELECTED provider — the menu mirrors the island's
        // slots instead of a hardcoded duo (a Grok+Gemini machine used to
        // read "Claude: idle / Codex: idle" here, both meaningless).
        ForEach(ProviderVisibilityStore.shared.slotProviders, id: \.self) { provider in
            Text("\(provider.alertProvider.displayName): \(monitor.state(for: provider.alertProvider).label)")
        }
        Divider()
        Button(L10n.tr("Refresh usage")) {
            usage.refresh()
        }
        Button(L10n.tr("Open Settings")) {
            SettingsWindowController.shared.show()
        }
        Button(L10n.tr("Quit Agent Island")) {
            NSApp.terminate(nil)
        }
        Divider()
        // The bottom slots are the prime slots — share lives there, not Quit
        // (owner's call, 2026-07-14).
        Button(L10n.tr("Share weekly report…")) {
            WeeklyReportWindowController.shared.show()
        }
        Button(L10n.tr("Share monthly report…")) {
            MonthlyReportWindowController.shared.show()
        }
    }
}
