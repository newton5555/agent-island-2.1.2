import SwiftUI

/// Three-page horizontal carousel: live usage (page 0), cost (page 1), and
/// history overview (page 2). Each page renders at the full content width;
/// the HStack slides via `.offset` based on
/// `ScreenPref.screen`. Horizontal movement gets its own drawer-style curve
/// so page navigation does not inherit the island shape's spring bounce.
///
/// Only the data row swipes — `PanelHeader` and `PanelFooter` are mounted
/// outside this view so they stay fixed across page changes.
///
/// First-encounter peek: on every expand until the user has swiped at
/// least once (`ScreenPref.hasSwipedScreen`), the data row slides ~28pt
/// left to reveal the cost screen's edge, then settles back. Subtle and
/// time-bounded so it stops nagging once they've discovered the gesture.
struct PagedContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var screenPref = ScreenPref.shared
    @ObservedObject private var costPanelVisibility = CostPanelVisibilityStore.shared
    @State private var peekOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    /// Resist dragging past the first/last page so the carousel feels bounded
    /// instead of sliding into blank space.
    private func rubberBanded(_ raw: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let index = screenPref.visiblePageIndex
        let lastIndex = screenPref.visibleScreens.count - 1
        let atStart = index == 0 && raw > 0
        let atEnd = index == lastIndex && raw < 0
        return (atStart || atEnd) ? raw * 0.3 : raw
    }

    var body: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            HStack(spacing: 0) {
                UsageView()
                    .offset(y: compactPageYOffset)
                    .frame(width: pageWidth)
                if costPanelVisibility.showInTopPanel {
                    CostView()
                        .offset(y: compactPageYOffset)
                        .frame(width: pageWidth)
                }
                OverviewView(model: model)
                    .frame(width: pageWidth)
            }
            .frame(width: pageWidth, height: geo.size.height, alignment: .topLeading)
            .offset(x: (-pageWidth * CGFloat(screenPref.visiblePageIndex)) + peekOffset + dragOffset)
            .animation(.pageSwipe, value: screenPref.screen)
            .animation(.pageSwipe, value: costPanelVisibility.showInTopPanel)
            .clipped()
            .contentShape(Rectangle())
            // Left-click-drag paging, for people on a plain mouse (the
            // trackpad two-finger swipe and Shift+wheel already work). The
            // 12pt activation distance lets taps on tiles/buttons through;
            // the card follows the cursor and snaps on release.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Horizontal intent only — vertical drags belong to
                        // any nested scroll content.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragOffset = rubberBanded(value.translation.width, pageWidth: pageWidth)
                    }
                    .onEnded { value in
                        let width = value.translation.width
                        let threshold = pageWidth * 0.22
                        withAnimation(.pageSwipe) { dragOffset = 0 }
                        guard abs(width) > abs(value.translation.height) else { return }
                        if width <= -threshold {
                            model.advanceScreen()
                        } else if width >= threshold {
                            model.rewindScreen()
                        }
                    }
            )
            .onAppear {
                screenPref.ensureVisibleScreen()
                // Discoverability cue, not decorative motion — fires even
                // when @Environment(\.accessibilityReduceMotion) is on,
                // because without it reduce-motion users have no path to
                // learn the second screen exists. The motion is brief
                // (~1s total) and slow-eased.
                guard !screenPref.hasSwipedScreen,
                      screenPref.screen == .usage
                else { return }
                schedulePeek()
            }
            .onChange(of: screenPref.hasSwipedScreen) { swiped in
                // User swiped mid-peek: collapse the peek smoothly so the
                // composite offset doesn't jump when the real screen
                // transition fires alongside it.
                if swiped, peekOffset != 0 {
                    withAnimation(.pageSwipe) { peekOffset = 0 }
                }
            }
            .onChange(of: costPanelVisibility.showInTopPanel) { _ in
                screenPref.ensureVisibleScreen()
            }
        }
    }

    private let compactPageYOffset: CGFloat = -28

    private func schedulePeek() {
        // 0.40s lets the panel's openMorph + content fade-in settle
        // (~0.42s + ~0.28s) before the peek begins, so the discoverability
        // beat is its own gesture instead of competing with the entrance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            guard !screenPref.hasSwipedScreen else { return }
            // This is horizontal navigation affordance, so use the same
            // page curve as real swipes. It feels connected to the carousel
            // instead of to the panel's physical resize.
            withAnimation(.pageSwipe) { peekOffset = -46 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
                guard !screenPref.hasSwipedScreen else { return }
                withAnimation(.pageSwipe) { peekOffset = 0 }
            }
        }
    }
}
