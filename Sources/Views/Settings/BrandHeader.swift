import SwiftUI
import AppKit

/// The Settings window's brand row. Replaces the empty traffic-light
/// gutter and the duplicate "NOW" stats from the previous design.
///
/// Three elements left to right: the AgentIsland brand mark (the curly-
/// brace island glyph that ships in `Resources/agentisland_logo.png`,
/// rendered from a transparent template image), the
/// app name + tagline, and a version pill on the right.
struct BrandHeader: View {
    let version: String
    @State private var versionHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            mark

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Island")
                    .font(Typography.brand)
                    .tracking(-0.15)
                    .foregroundStyle(.white.opacity(0.92))
                // Locked positioning (owner call, 2026-08-08): category
                // line, never a provider roll call — it survives every new
                // agent the roster gains.
                Text(L10n.tr("A status companion for your AI coding agents"))
                    .font(SettingsType.data)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 8)

            // The version pill opens this version's release notes (owner
            // call, 1.7.2: clicking or hovering the version should explain
            // what it is).
            Button {
                WhatsNewWindowController.shared.show()
            } label: {
                Text("v\(version)")
                    .font(Typography.bodyNumber)
                    .foregroundStyle(.white.opacity(versionHovered ? 0.75 : 0.34))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(.white.opacity(versionHovered ? 0.09 : 0.04))
                    )
            }
            .buttonStyle(TactileButtonStyle())
            .onHover { versionHovered = $0 }
            .help(L10n.tr("What's new in this version"))
            .animation(.easeOut(duration: 0.12), value: versionHovered)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    private var mark: some View {
        // Bare transparent mark — the boxed tile read as an app icon
        // (owner review, 2026-08-09).
        BrandMark(side: 30)
    }
}
