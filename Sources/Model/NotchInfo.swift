import AppKit

struct NotchInfo {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    /// On a notched screen the silhouette must match the PHYSICAL notch, so
    /// `safeAreaInsets.top` is the height source there. The visible menu bar
    /// is NOT a safe proxy: macOS sizes it on its own grid and it can run
    /// taller than the housing (33pt menu bar vs 32pt notch measured on an
    /// M5 14"; larger deltas on other machines), and a menu-bar-height pill
    /// hangs below the hardware as a grey chin under the real notch —
    /// exactly the "taller than my notch" report from the first external
    /// design review. Upstream codex-island shipped the same fix (#57).
    ///
    /// In "Scaled to avoid the notch" mode `safeAreaInsets.top` is 0, so we
    /// fall through to the visible-menu-bar path (≈24pt bar below the dead
    /// notch strip) — no notch blending applies there.
    ///
    /// auxiliaryTopLeftArea / auxiliaryTopRightArea give the menu-bar regions
    /// on either side of the notch; the notch's own width is
    /// (screen width - left - right).
    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(width: IslandSpacingStore.compactWidth, height: menuBarFallback(), hasNotch: false)
        }
        let safeTop = screen.safeAreaInsets.top

        if safeTop > 0 {
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            let width: CGFloat = (leftW > 0 && rightW > 0)
                ? screen.frame.width - leftW - rightW
                : 200
            return NotchInfo(width: width, height: safeTop, hasNotch: true)
        }
        return NotchInfo(width: IslandSpacingStore.compactWidth, height: visibleMenuBarHeight(of: screen), hasNotch: false)
    }

    private static func visibleMenuBarHeight(of screen: NSScreen) -> CGFloat {
        let fromVisibleFrame = screen.frame.maxY - screen.visibleFrame.maxY
        if fromVisibleFrame > 0 { return fromVisibleFrame }
        // Auto-hide menu bar — visibleFrame == frame, so derive from the
        // physical notch (if present) or the system status bar thickness.
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return menuBarFallback()
    }

    private static func menuBarFallback() -> CGFloat {
        let t = NSStatusBar.system.thickness
        return t > 0 ? t : 24
    }
}
