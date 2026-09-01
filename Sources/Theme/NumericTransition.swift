import SwiftUI

/// Content-replacement language for live values (2026-07-18, studied
/// frame-by-frame from the owner's Cadence app): values BLUR-DISSOLVE
/// between states — old and new glyphs melt through each other. No
/// odometer rolling (Cadence deliberately avoids `.numericText`'s
/// digit-scroll). macOS 14 gets the real blur replace; Ventura falls back
/// to a plain crossfade.
extension View {
    @ViewBuilder
    func numericTransition(value: Double) -> some View {
        if #available(macOS 14.0, *) {
            self.id(value)
                .transition(.blurReplace)
        } else {
            self.id(value)
                .transition(.opacity)
        }
    }
}
