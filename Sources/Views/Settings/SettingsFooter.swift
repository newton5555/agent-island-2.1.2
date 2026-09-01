import SwiftUI
import AppKit

/// Bottom footer for the Settings window. GitHub / License as dotted-
/// underline links, Quit pill flush right. Version lives in the brand
/// header at the top of the window.
struct SettingsFooter: View {
    @State private var quitHovered = false

    private static let githubURL = URL(string: "https://github.com/tristan666666/agent-island")!

    var body: some View {
        // GitHub + the guide on the left; the share CTAs right. Quit lives
        // in the sidebar next to the version pill now (owner call, 2.1.1).
        HStack(alignment: .center, spacing: 14) {
            link("GitHub", url: Self.githubURL)

            // The footer guide is the GLOBAL product tour, not one release's
            // notes (owner call, 1.7.2).
            DottedLink(title: "Guide", arrow: false) {
                GuideWindowController.shared.show()
            }
            .help(L10n.tr("How Agent Island works"))

            Spacer()

            // Short labels — the full 'Share weekly report' pair overflowed
            // the 480pt window in English and crushed Quit into a vertical
            // letter-stack. Hover help carries the full wording.
            sharePill(L10n.tr("Weekly"), help: L10n.tr("Share weekly report")) {
                WeeklyReportWindowController.shared.show()
            }
            sharePill(L10n.tr("Monthly"), help: L10n.tr("Share monthly report")) {
                MonthlyReportWindowController.shared.show()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func sharePill(_ title: String, help: String,
                           action: @escaping () -> Void) -> some View {
        SharePillButton(title: title, help: help, action: action)
    }

    @ViewBuilder
    private func link(_ title: String, url: URL) -> some View {
        DottedLink(title: title) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SharePillButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(SettingsType.data.weight(.bold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(hovered ? 1.0 : 0.92))
            }
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovered = $0 }
        .help(help)
        .animation(.strongEaseOut, value: hovered)
    }
}

private struct DottedLink: View {
    let title: String
    var arrow = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(L10n.tr(title))
                    .font(SettingsType.data)
                    .foregroundStyle(.white.opacity(hovered ? 0.92 : 0.55))
                if arrow {
                    Text("↗")
                        .font(SettingsType.data)
                        .foregroundStyle(.white.opacity(hovered ? 0.6 : 0.3))
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(hovered ? 0.32 : 0.18))
                    .frame(height: 0.5)
                    .offset(y: 1)
                    .mask(
                        // Dotted via repeating gradient
                        LinearGradient(
                            colors: [.black, .clear, .black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.bottom, 2)
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.10), value: hovered)
    }
}
