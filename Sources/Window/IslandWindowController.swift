import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandWindowController {
    let window: NSWindow
    let model: IslandModel
    private let host: IslandHostingView
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var trackingTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var sessionResignObserver: NSObjectProtocol?
    private var sessionActiveObserver: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var recoveryTimer: Timer?
    private var subs: Set<AnyCancellable> = []
    private var hasSeenMouseEvent = false
    private var isMouseInsideIsland = false
    private var cmdQMonitor: Any?

    // Sized for the largest content: expanded overview at 150% interface
    // scale. The window is transparent and click-through outside the shape,
    // so the extra headroom costs nothing.
    static let windowSize = CGSize(width: 1440, height: 640)

    init() {
        let notch = NotchInfo.detect(from: Self.targetScreen())
        self.model = IslandModel(notch: notch)

        window = BorderlessFloatingWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.collectionBehavior = Self.collectionBehavior(
            hideInMissionControl: MissionControlHideStore.shared.enabled
        )
        window.isMovable = false

        host = IslandHostingView(
            rootView: IslandRootView(model: model),
            model: model
        )
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    func show() {
        repositionForCurrentScreen()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        installMouseTracking()
        observeScreenChanges()
        observeTargetChoice()
        observeOcclusion()
        observeSessionState()
        observeMissionControlPreference()
        observeVisibilityRecovery()
    }

    /// `.stationary` pins the island through Exposé (fine on notched
    /// MacBooks, where Mission Control drops its Spaces bar below the
    /// housing) — on external displays the Spaces bar hugs the top edge and
    /// the island covers it. The opt-in swaps in `.transient`, whose
    /// documented (and on-device verified) behavior is "hidden by Exposé";
    /// spaces behavior is unchanged either way.
    /// `.fullScreenAuxiliary` keeps the island over fullscreen apps —
    /// without it the island simply isn't on a fullscreen Space, which
    /// read as "the island randomly disappears" (owner report,
    /// 2026-08-09; the notch is physically there in fullscreen too).
    private static func collectionBehavior(hideInMissionControl: Bool) -> NSWindow.CollectionBehavior {
        hideInMissionControl
            ? [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    private func observeMissionControlPreference() {
        MissionControlHideStore.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.window.collectionBehavior = Self.collectionBehavior(hideInMissionControl: enabled)
            }
            .store(in: &subs)
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = sessionResignObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = sessionActiveObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // wakeObservers spans two centers (workspace + default); removing a
        // token from the wrong one is a harmless no-op, so sweep both.
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = cmdQMonitor { NSEvent.removeMonitor(m) }
        trackingTimer?.invalidate()
        recoveryTimer?.invalidate()
    }

    /// Click-through for everything outside the visible shape. We watch cursor
    /// position globally and flip ignoresMouseEvents accordingly so clicks
    /// outside the notch pill go straight to whatever's underneath.
    ///
    /// The hitTest override on IslandHostingView is necessary but not
    /// sufficient — without the global monitor, the window still steals focus
    /// on click even when hitTest returns nil.
    private func installMouseTracking() {
        window.ignoresMouseEvents = true

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hasSeenMouseEvent = true
                self.invalidateTrackingTimerIfReady()
                self.updateMouseEventsBasedOnCursor()
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        }

        // Polling safety net for the case where the cursor is already inside
        // the shape area at launch — no mouseMoved event would otherwise fire.
        // Self-invalidates once any real mouseMoved arrives, so steady-state
        // doesn't pay the 10Hz timer cost forever.
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateMouseEventsBasedOnCursor() }
        }
    }

    private func invalidateTrackingTimerIfReady() {
        guard hasSeenMouseEvent, let timer = trackingTimer else { return }
        timer.invalidate()
        trackingTimer = nil
    }

    private func updateMouseEventsBasedOnCursor() {
        let cursor = NSEvent.mouseLocation
        let win = window.frame
        let local = NSPoint(x: cursor.x - win.minX, y: cursor.y - win.minY)

        let size = model.size
        let rect = NSRect(
            x: win.width / 2 - size.width / 2,
            y: win.height - size.height,
            width: size.width,
            height: size.height
        )
        let inside = rect.contains(local)
        if window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }
        if inside != isMouseInsideIsland {
            isMouseInsideIsland = inside
            if inside {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
                cmdQMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.modifierFlags.contains(.command),
                       event.charactersIgnoringModifiers == "q" {
                        // Quit only when the island is deliberately engaged.
                        // The pill steals key on hover-through, so a Cmd+Q
                        // aimed at the app underneath was silently killing
                        // AgentIsland — the other face of "the island just
                        // disappears" (owner report, 2026-08-09).
                        if let self, self.model.state == .expanded {
                            NSApp.terminate(nil)
                            return nil
                        }
                    }
                    return event
                }
            } else {
                if let m = cmdQMonitor { NSEvent.removeMonitor(m) }
                cmdQMonitor = nil
            }
        }
    }

    @MainActor
    private static func targetScreen() -> NSScreen? {
        DisplayInfo.currentTarget()?.screen
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.repositionForCurrentScreen() }
        }
    }

    /// Pauses the LoadingSweep when the user can't see the island —
    /// fullscreen apps on a separate Space, the screen going to sleep,
    /// or anything else macOS reports as making the window invisible.
    /// The 30Hz TimelineView is the dominant idle-CPU cost; pausing it
    /// while occluded drops idle to ~0%.
    private func observeOcclusion() {
        // Seed the initial state — the notification doesn't fire on launch.
        WindowOcclusionStore.shared.update(
            isVisible: window.occlusionState.contains(.visible)
        )
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let visible = self.window.occlusionState.contains(.visible)
            Task { @MainActor in
                WindowOcclusionStore.shared.update(isVisible: visible)
            }
        }
    }

    /// Hides the island when the screen locks so it doesn't ride the
    /// lock-screen slide animation (which makes the notch appear to fall).
    /// DistributedNotificationCenter "com.apple.screenIsLocked" fires as soon
    /// as the lock is initiated, before the slide animation completes.
    private func observeSessionState() {
        let dc = DistributedNotificationCenter.default()
        sessionResignObserver = dc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.fadeOut() }
        }
        sessionActiveObserver = dc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.fadeIn() }
        }
    }

    /// The island must never stay gone. `fadeOut` on lock is the only
    /// deliberate orderOut, and its undo rides a distributed notification
    /// macOS delivers best-effort — one missed "screenIsUnlocked" (Touch ID
    /// races, fast user switching) stranded the island until relaunch
    /// (owner report, 2026-08-09: 经常莫名其妙就消失). Recovery is belt and
    /// suspenders: wake/session notifications trigger an immediate check,
    /// and a slow sweep catches whatever they miss. Ground truth for "may
    /// I show?" is the session dictionary, not our own state — our state
    /// is exactly what a missed notification corrupts.
    private func observeVisibilityRecovery() {
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.recoverIfStranded() }
            })
        }
        // A hide (Cmd+H aimed at another app while the island held key)
        // must be undone by the EVENT, not the sweep timer — a hidden app
        // naps, and napping is precisely when timers stop firing.
        wakeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recoverIfStranded() }
        })
        let sweep = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recoverIfStranded() }
        }
        sweep.tolerance = 5
        recoveryTimer = sweep
    }

    private func recoverIfStranded() {
        guard !window.isVisible, !Self.screenIsCurrentlyLocked else { return }
        // A Cmd+H aimed at another app while the island held key hides the
        // whole app — unhide quietly before re-ordering the window in.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        fadeIn()
    }

    private static var screenIsCurrentlyLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func fadeOut() {
        window.orderOut(nil)
    }

    private func fadeIn() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1
        }
    }

    private func observeTargetChoice() {
        IslandTargetDisplayStore.shared.$choice
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.repositionForCurrentScreen() }
            }
            .store(in: &subs)
    }

    private func repositionForCurrentScreen() {
        guard let screen = Self.targetScreen() else { return }
        model.updateNotch(NotchInfo.detect(from: screen))
        let size = Self.windowSize
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
