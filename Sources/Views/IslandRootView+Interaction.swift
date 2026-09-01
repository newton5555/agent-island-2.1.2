import AppKit
import SwiftUI

extension IslandRootView {
    func handleTap() {
        if NSEvent.modifierFlags.contains(.command) {
            switch ScreenPref.shared.screen {
            case .usage: StylePref.shared.cycle()
            // Cost style no longer cycles by gesture — picked in Settings
            // only (owner call, 1.7.2 planning: the hidden gesture and its
            // hint added noise for zero discoverability).
            case .cost, .overview: return
            }
            return
        }
        guard model.state == .peek || model.state == .compact else { return }
        // Opening the full panel is a "show me the current numbers" moment —
        // pull fresh data if what we have is already past its interval. Capped
        // by refreshIfStale so it never out-paces the rate-limited endpoint.
        UsageStore.shared.refreshIfStale()
        withAnimation(.openMorph) {
            model.setState(.expanded)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard model.state == .expanded else { return }
            withAnimation(.strongEaseOut) {
                contentVisible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeIn(duration: 0.18)) {
                pillsVisible = false
            }
        }
    }

    func handleProviderTap(_ provider: DisplayProvider) {
        model.showScreen(.usage)
        guard model.state != .expanded else { return }
        handleTap()
    }

    func handleHover(_ isHovering: Bool) {
        hovering = isHovering
        isHovering ? enterPeekFromHover() : exitPeekFromHover()
    }

    func handleAppear() {
        if alwaysShow.enabled && model.state == .compact {
            model.setState(.peek)
            pillsVisible = true
        }
    }

    func handleAlwaysShowChange(_ enabled: Bool) {
        guard !hovering, model.state != .expanded else { return }
        if enabled {
            enterPeekForAlwaysShow()
        } else {
            exitPeekForAlwaysShow()
        }
    }

    func handlePulse(_ event: AlertEngine.PulseEvent) {
        guard model.state != .expanded else { return }

        if model.state == .compact {
            withAnimation(.openMorph) {
                model.setState(.peek)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard model.state == .peek else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    pillsVisible = true
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                pillsVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
                withAnimation(.closeMorph) {
                    model.setState(.compact)
                }
            }
        }
    }

    var restState: IslandModel.State {
        alwaysShow.enabled ? .peek : .compact
    }

    var accessibilityHintForState: String {
        switch model.state {
        case .compact:
            return alwaysShow.enabled
                ? L10n.tr("Click to expand. Command-click to cycle visualization.")
                : L10n.tr("Hover to peek usage. Click to expand. Command-click to cycle visualization.")
        case .peek:
            return L10n.tr("Click to expand. Command-click to cycle visualization.")
        case .expanded:
            return ScreenPref.shared.screen == .overview
                ? L10n.tr("Swipe to change pages.")
                : L10n.tr("Command-click to cycle visualization.")
        }
    }

    func logoEdgePadding(for provider: DisplayProvider) -> CGFloat {
        // 9pt from the silhouette BODY edge; the frame is topCurl wider per
        // side (the flare region), which holds no body to align against.
        switch model.state {
        case .compact, .expanded: return 9 + IslandShape.topCurl
        case .peek:
            // Solo: this provider's number crossed to the opposite flank,
            // so its logo takes the freed outboard slot and hugs the corner
            // with the same 14pt breath the pill uses — otherwise the logo
            // floats mid-island with a dead slot beside it.
            if soloProvider == provider { return 14 + IslandShape.topCurl }
            return model.pillSlotWidth + 9 + IslandShape.topCurl
        }
    }

    private func enterPeekFromHover() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard model.state == .compact else { return }
        withAnimation(.openMorph) {
            model.setState(.peek)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard model.state == .peek else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                pillsVisible = true
            }
        }
    }

    private func exitPeekFromHover() {
        // An EXPANDED panel rides out hover flicker: .onHover drops false for
        // a frame when the pointer crosses child views (scrubbable video, the
        // pager, pickers), and the old immediate-hide + 0.10s collapse made
        // the open panel vanish under the cursor (owner report, 1.7.2). A
        // real leave still closes it — after a grace window with the cursor
        // genuinely gone. Peek keeps its snappy exit.
        if model.state == .expanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard !hovering, model.state == .expanded else { return }
                withAnimation(.easeOut(duration: 0.10)) {
                    contentVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    guard !hovering, model.state == .expanded else { return }
                    withAnimation(.closeMorph) {
                        model.setState(restState)
                    }
                    if alwaysShow.enabled {
                        withAnimation(.easeOut(duration: 0.18)) {
                            pillsVisible = true
                        }
                    }
                }
            }
            return
        }

        if !alwaysShow.enabled {
            withAnimation(.easeOut(duration: 0.08)) {
                pillsVisible = false
            }
        }
        withAnimation(.easeOut(duration: 0.10)) {
            contentVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard !hovering else { return }
            let target = restState
            if model.state != target {
                withAnimation(.closeMorph) {
                    model.setState(target)
                }
            }
            if alwaysShow.enabled && !pillsVisible {
                withAnimation(.easeOut(duration: 0.18)) {
                    pillsVisible = true
                }
            }
        }
    }

    private func enterPeekForAlwaysShow() {
        guard model.state == .compact else { return }
        withAnimation(.openMorph) {
            model.setState(.peek)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard model.state == .peek, !hovering else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                pillsVisible = true
            }
        }
    }

    // MARK: - Demo driver (AGENTISLAND_UI_SCRIPT)

    /// Recording-rig commands. Each one replays the same choreography the
    /// real hover/tap handlers run, so scripted footage is indistinguishable
    /// from a human driving the island — minus the cursor in frame.
    func handleDemoCommand(_ cmd: String) {
        switch cmd {
        case "peek":
            enterPeekFromHover()
        case "expand":
            guard model.state == .peek || model.state == .compact else { return }
            withAnimation(.openMorph) {
                model.setState(.expanded)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard model.state == .expanded else { return }
                withAnimation(.strongEaseOut) {
                    contentVisible = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeIn(duration: 0.18)) {
                    pillsVisible = false
                }
            }
        case "collapse":
            withAnimation(.easeOut(duration: 0.10)) {
                contentVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                withAnimation(.closeMorph) {
                    model.setState(.compact)
                }
            }
        case "page:usage":
            withAnimation(.pageSwipe) { model.showScreen(.usage) }
        case "page:cost":
            withAnimation(.pageSwipe) { model.showScreen(.cost) }
        case "page:overview":
            withAnimation(.pageSwipe) { model.showScreen(.overview) }
        default:
            break
        }
    }

    private func exitPeekForAlwaysShow() {
        guard model.state == .peek else { return }
        withAnimation(.easeOut(duration: 0.08)) {
            pillsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
            withAnimation(.closeMorph) {
                model.setState(.compact)
            }
        }
    }
}
