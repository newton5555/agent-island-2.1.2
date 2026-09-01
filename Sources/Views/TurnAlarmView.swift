import AppKit
import SwiftUI

/// Which rate-limit window a quota-exhausted alarm is about.
enum QuotaWindowKind: String {
    case fiveHour
    case weekly
}

/// Why the full-screen alarm is showing. `yourTurn` is the thread-finished
/// alarm; `quotaExhausted` is the distinct "you're out of quota until <time>"
/// alarm, which has no thread to open — only an acknowledge.
enum TurnAlarmKind: Equatable {
    case yourTurn
    case quotaExhausted(window: QuotaWindowKind, resetAt: Date?)
}

struct TurnAlarmView: View {
    let provider: AlertEngine.Provider
    let providerName: String
    let thread: ActivityMonitor.ActiveThread?
    var kind: TurnAlarmKind = .yourTurn
    let dismiss: () -> Void

    @ObservedObject private var reminders = AgentReminderStore.shared
    @State private var glowPulse = false

    private func openThreadAndDismiss() {
        // Navigate FIRST: this is an .accessory app, so closing our only key
        // window hands focus back to the previous app, after which macOS 14+
        // may refuse or delay the cooperative activation the jump relies on.
        TurnAlarmNavigator.open(provider: provider, thread: thread)
        dismiss()
    }

    var body: some View {
        ZStack {
            alarmBackground

            VStack(spacing: 0) {
                Spacer(minLength: 42)

                TurnAlarmProviderMark(provider: provider, providerColor: providerColor)
                    .padding(.bottom, 20)

                VStack(spacing: 9) {
                    Text(headline)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(waitingTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(provider.accentGradient(from: .leading, to: .trailing))
                        .lineLimit(1)

                    Text(detailText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.bottom, 24)

                if !isExhausted, reminders.showSessionDetails {
                    TurnAlarmMetadata(
                        providerName: providerName,
                        threadName: threadName,
                        projectName: projectName,
                        providerColor: providerColor,
                        providerStops: providerStops
                    )
                        .padding(.bottom, 22)
                }

                if !isExhausted {
                    Button {
                        openThreadAndDismiss()
                    } label: {
                        Text(L10n.tr("Open thread"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(provider.accentIsLight ? Color.black.opacity(0.85) : .white)
                            .frame(width: 396, height: 48)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(buttonGradient)
                                    .shadow(color: providerColor.opacity(0.46), radius: 18, y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    .onReceive(NotificationCenter.default.publisher(for: .islandDemoCommand)) { note in
                        // Recording rig: replay the open-thread interaction.
                        if (note.userInfo?["cmd"] as? String) == "alarm:open" {
                            openThreadAndDismiss()
                        }
                    }
                }

                Button {
                    dismiss()
                } label: {
                    Text(L10n.tr("I know"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 396, height: 42)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.white.opacity(0.08))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                                }
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                Spacer(minLength: 18)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CardWindow.cornerRadius, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear(perform: startAnimations)
    }

    private var alarmBackground: some View {
        ZStack {
            CardWindow.base
            RadialGradient(
                colors: providerStops.map { $0.opacity(glowPulse ? 0.30 : 0.18) }
                    + [providerColor.opacity(glowPulse ? 0.09 : 0.04), .clear],
                center: UnitPoint(x: 0.5, y: 0.15),
                startRadius: 16,
                endRadius: glowPulse ? 285 : 220
            )
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: providerStops.map { $0.opacity(glowPulse ? 0.24 : 0.13) }
                                + [providerColor.opacity(0.02), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 210)
                Spacer(minLength: 0)
            }
        }
    }

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
    }

    private var providerColor: Color {
        provider.accent
    }

    /// Antigravity's four Google hues; one repeated swatch for everyone else.
    private var providerStops: [Color] {
        provider.accentStops
    }

    private var buttonGradient: LinearGradient {
        LinearGradient(
            colors: providerStops.count > 2
                ? providerStops.map { $0.opacity(0.88) }
                : [providerColor.opacity(0.96), providerColor.opacity(0.72)],
            startPoint: providerStops.count > 2 ? .leading : .top,
            endPoint: providerStops.count > 2 ? .trailing : .bottom
        )
    }

    private var isExhausted: Bool {
        if case .quotaExhausted = kind { return true }
        return false
    }

    private var headline: String {
        switch kind {
        case .yourTurn:       return L10n.tr("It's your turn")
        case .quotaExhausted: return L10n.tr("Out of quota")
        }
    }

    private var waitingTitle: String {
        switch kind {
        case .yourTurn:
            return L10n.tr("%@ is waiting", headlineName)
        case .quotaExhausted(let window, _):
            let windowName = window == .fiveHour ? L10n.tr("5-hour limit") : L10n.tr("Weekly limit")
            return "\(providerName) · \(windowName)"
        }
    }

    private var detailText: String {
        switch kind {
        case .yourTurn:
            return L10n.tr("The thread finished. Come back and reply.")
        case .quotaExhausted(_, let resetAt):
            guard let resetAt else { return L10n.tr("You're rate-limited for now.") }
            return Self.resetDetail(resetAt)
        }
    }

    /// "Resets at 15:55 (~2h)" — absolute time plus a coarse relative gap.
    private static func resetDetail(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let clock = formatter.string(from: date)
        let minutes = max(1, Int((date.timeIntervalSinceNow / 60).rounded()))
        let relative = minutes >= 60 ? L10n.tr("~%dh", minutes / 60) : L10n.tr("~%dm", minutes)
        return L10n.tr("Resets at %@ (%@)", clock, relative)
    }

    private var headlineName: String {
        reminders.showSessionDetails ? threadName : providerName
    }

    private var threadName: String {
        guard let label = thread?.label, !label.isEmpty else {
            return L10n.tr("Demo thread")
        }
        return label
    }

    private var projectName: String? {
        guard let cwd = thread?.cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
