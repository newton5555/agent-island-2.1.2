import AppKit
import Foundation
import UserNotifications

@MainActor
final class AgentReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentReminderCenter()

    private var deliveredNeedsYouKeys: [String: Date] = [:]
    private var activeNeedsYouKeys: [String: Set<String>] = [:]
    private var acknowledgedNeedsYouKeys: [String: Date] = [:]
    private var pendingNeedsYouTasks: [String: Task<Void, Never>] = [:]
    private var observedProviders: Set<String> = []
    private let rememberedKeyLifetime: TimeInterval = 12 * 60 * 60
    // Scans are event-driven: a reply appended to the transcript triggers a
    // rescan within ~0.6s (FSEvents debounce + kick throttle) that cancels
    // this pending confirm; anything that still slips through auto-dismisses.
    // 1s keeps the popup inside the "it just finished" moment.
    private let needsYouConfirmationDelay: TimeInterval = 1
    private static let acknowledgedDefaultsKey = "AgentIsland.acknowledgedNeedsYouKeys"

    private let startedAt = Date()

    private override init() {
        acknowledgedNeedsYouKeys = Self.loadAcknowledgedKeys()
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                NSLog("AgentIsland reminder authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("AgentIsland reminders not authorized")
            }
        }
    }

    func handle(provider: AlertEngine.Provider, needsYouThreads: [ActivityMonitor.ActiveThread]) {
        guard AgentReminderStore.shared.enabled else { return }
        pruneRememberedKeys()
        let providerKey = provider.rawValue
        let isFirstObservation = markObserved(provider)
        let keyed = needsYouThreads.map { thread in
            (key: deliveryKey(provider: provider, state: .needsYou, thread: thread), thread: thread)
        }
        let currentKeys = Set(keyed.map(\.key))
        // Turns that left needsYou (the user replied, or they aged out): the
        // pending confirm is void and a visible panel for them is pure noise.
        for staleKey in (activeNeedsYouKeys[providerKey] ?? []).subtracting(currentKeys) {
            cancelPending(staleKey)
            TurnAlarmWindowController.shared.autoDismiss(provider: provider, deliveryKey: staleKey)
        }
        activeNeedsYouKeys[providerKey] = currentKeys
        var fresh: [(key: String, thread: ActivityMonitor.ActiveThread)] = []
        for (key, thread) in keyed {
            guard acknowledgedNeedsYouKeys[key] == nil,
                  deliveredNeedsYouKeys[key] == nil,
                  pendingNeedsYouTasks[key] == nil
            else { continue }
            // First sighting at launch, and turns finished before this app was
            // running, are history rather than news — record, don't alarm.
            if isFirstObservation || thread.modified < startedAt {
                baseline(key)
                continue
            }
            fresh.append((key, thread))
        }
        // Storm collapse: an orchestration fanning out dozens of subagents
        // finishes them in bursts. To the human that is ONE event — alarm for
        // the newest turn only and record the rest, or the queue replays a
        // popup per child.
        if let first = fresh.first {
            scheduleDelivery(provider: provider, thread: first.thread, deliveryKey: first.key)
        }
        for extra in fresh.dropFirst() {
            baseline(extra.key)
        }
    }

    func hasAcknowledged(provider: AlertEngine.Provider, thread: ActivityMonitor.ActiveThread?) -> Bool {
        acknowledgedNeedsYouKeys[deliveryKey(provider: provider, state: .needsYou, thread: thread)] != nil
    }

    func acknowledge(provider: AlertEngine.Provider, thread: ActivityMonitor.ActiveThread?) {
        let deliveryKey = deliveryKey(provider: provider, state: .needsYou, thread: thread)
        cancelPending(deliveryKey)
        acknowledgedNeedsYouKeys[deliveryKey] = Date()
        deliveredNeedsYouKeys[deliveryKey] = Date()
        persistAcknowledgedKeys()
    }

    private func pruneRememberedKeys() {
        let cutoff = Date().addingTimeInterval(-rememberedKeyLifetime)
        let acknowledgedBefore = acknowledgedNeedsYouKeys
        deliveredNeedsYouKeys = deliveredNeedsYouKeys.filter { $0.value >= cutoff }
        acknowledgedNeedsYouKeys = acknowledgedNeedsYouKeys.filter { $0.value >= cutoff }
        if acknowledgedBefore.count != acknowledgedNeedsYouKeys.count {
            persistAcknowledgedKeys()
        }
    }

    private func markObserved(_ provider: AlertEngine.Provider) -> Bool {
        let providerKey = provider.rawValue
        guard !observedProviders.contains(providerKey) else { return false }
        observedProviders.insert(providerKey)
        return true
    }

    private func baseline(_ deliveryKey: String) {
        acknowledgedNeedsYouKeys[deliveryKey] = Date()
        persistAcknowledgedKeys()
    }

    private func deliveryKey(
        provider: AlertEngine.Provider,
        state: ActivityMonitor.State,
        thread: ActivityMonitor.ActiveThread?
    ) -> String {
        ReminderDeliveryKey.make(
            providerRawValue: provider.rawValue,
            stateRawValue: state.rawValue,
            transcriptPath: thread?.transcriptPath,
            sessionId: thread?.sessionId ?? "",
            cwd: thread?.cwd ?? "",
            label: thread?.label ?? "",
            turnKey: thread?.turnKey
        )
    }

    private func scheduleDelivery(
        provider: AlertEngine.Provider,
        thread: ActivityMonitor.ActiveThread,
        deliveryKey: String
    ) {
        pendingNeedsYouTasks[deliveryKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(needsYouConfirmationDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            confirmAndDeliver(provider: provider, thread: thread, deliveryKey: deliveryKey)
        }
    }

    private func confirmAndDeliver(
        provider: AlertEngine.Provider,
        thread: ActivityMonitor.ActiveThread,
        deliveryKey: String
    ) {
        pendingNeedsYouTasks[deliveryKey] = nil
        // Event-driven scans re-evaluate the active set within ~1.2s of any
        // transcript write, so by fire time a turn the user already answered
        // was removed (and this task cancelled) by that fresher scan.
        guard AgentReminderStore.shared.enabled,
              activeNeedsYouKeys[provider.rawValue, default: []].contains(deliveryKey),
              acknowledgedNeedsYouKeys[deliveryKey] == nil,
              deliveredNeedsYouKeys[deliveryKey] == nil
        else { return }
        // The user is already looking at the session (its hosting app is
        // frontmost) when the turn finishes: they watched it happen, so the
        // turn counts as seen. v1.7.1 held these and re-fired them on the
        // next app switch, which read as a stale popup ambush minutes or
        // hours later (owner report, 2026-08-05) — acknowledged, not queued.
        // #9 opt-in: one chime at that moment, because frontmost doesn't
        // always mean noticed — still no popup, still baselined.
        if !AgentReminderStore.shared.alarmWhenFrontmost,
           AgentHostAppResolver.isHostAppFrontmost(
            provider: provider, cwd: thread.cwd, launchTarget: thread.launchTarget
        ) {
            if AgentReminderStore.shared.frontmostSoundOnly {
                AgentReminderStore.shared.playFrontmostChime()
            }
            baseline(deliveryKey)
            return
        }
        deliveredNeedsYouKeys[deliveryKey] = Date()
        deliver(provider: provider, state: .needsYou, thread: thread)
    }

    private func cancelPending(_ deliveryKey: String) {
        pendingNeedsYouTasks[deliveryKey]?.cancel()
        pendingNeedsYouTasks[deliveryKey] = nil
    }

    private static func loadAcknowledgedKeys() -> [String: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: acknowledgedDefaultsKey) as? [String: TimeInterval] else {
            return [:]
        }
        return stored.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func persistAcknowledgedKeys() {
        let stored = acknowledgedNeedsYouKeys.mapValues(\.timeIntervalSince1970)
        UserDefaults.standard.set(stored, forKey: Self.acknowledgedDefaultsKey)
    }

    private func deliver(provider: AlertEngine.Provider, state: ActivityMonitor.State, thread: ActivityMonitor.ActiveThread?) {
        let content = UNMutableNotificationContent()
        content.title = title(provider: provider, state: state)
        content.body = body(provider: provider, state: state, thread: thread)

        let request = UNNotificationRequest(
            identifier: "agent-island-\(provider.rawValue)-\(state.rawValue)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AgentIsland reminder failed: %@", error.localizedDescription)
            }
        }
        TurnAlarmWindowController.shared.show(provider: provider, thread: thread)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    private func title(provider: AlertEngine.Provider, state: ActivityMonitor.State) -> String {
        let name = provider.displayName
        switch state {
        case .needsYou: return L10n.tr("%@ is waiting for you", name)
        case .idle, .working, .stalled, .authRequired, .rateLimited: return name
        }
    }

    private func body(
        provider: AlertEngine.Provider,
        state: ActivityMonitor.State,
        thread: ActivityMonitor.ActiveThread?
    ) -> String {
        switch state {
        case .needsYou:
            if AgentReminderStore.shared.showSessionDetails, let thread {
                return L10n.tr("A background coding session finished a turn: %@.", thread.label)
            }
            return L10n.tr("A background coding session finished a turn. It is your turn.")
        case .idle, .working, .stalled, .authRequired, .rateLimited:
            return ""
        }
    }
}
