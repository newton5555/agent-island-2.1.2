import SwiftUI
import AppKit

/// One-row Cursor readout under the provider tiles on the usage page: the
/// billing-period included-usage meter (the number Cursor's own status bar
/// budgets around) with its cycle-end countdown. A strip, not a tile —
/// Cursor meters one pool, not a 5h/weekly pair.
struct CursorUsageStrip: View {
    @ObservedObject private var store = CursorUsageStore.shared
    @ObservedObject private var quotaMode = QuotaDisplayModeStore.shared
    @State private var hovered = false

    private static let dashboardURL = URL(string: "https://cursor.com/dashboard")

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(IslandColor.cursor)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text("Cursor")
                    .font(Typography.providerTitle)
                    .foregroundStyle(.white.opacity(0.88))
                Text(L10n.tr("cycle"))
                    .font(Typography.micro)
                    .foregroundStyle(.white.opacity(0.40))
            }

            if let snapshot = store.snapshot {
                let value = quotaMode.displayValue(usedPercent: snapshot.usedPercent)
                meter(fraction: value / 100)
                Text("\(Int(value.rounded()))%")
                    .font(Typography.bodyNumber)
                    .foregroundStyle(.white.opacity(0.88))
                Text(caption(for: snapshot))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(store.errorCaption == nil ? 0.45 : 0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
            } else if let caption = store.errorCaption {
                Text(caption)
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
            } else {
                Text(L10n.tr("Syncing…"))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.36))
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(hovered ? 0.055 : 0))
        )
        .overlay(alignment: .bottomLeading) {
            if hovered {
                hoverCard
                    .offset(x: 8, y: -36)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .onTapGesture {
            guard let url = Self.dashboardURL else { return }
            NSWorkspace.shared.open(url)
        }
        .help(detailTooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(L10n.tr("Open Cursor dashboard"))
        .zIndex(hovered ? 20 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var hoverCard: some View {
        Text(detailTooltip)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(2)
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.035, green: 0.038, blue: 0.048).opacity(0.98))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
            )
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            .allowsHitTesting(false)
    }

    private func meter(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule()
                    .fill(IslandColor.cursor.opacity(0.85))
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(width: 150, height: 5)
    }

    /// Errors replace the reset countdown; an elapsed cycle boundary shows
    /// nothing rather than a frozen "resets in 0s".
    private func caption(for snapshot: CursorUsageSnapshot) -> String {
        if let error = store.errorCaption { return error }
        guard let end = snapshot.periodEnd,
              end.timeIntervalSinceNow > 0 else { return "" }
        return L10n.tr("resets in %@", Duration.compact(end.timeIntervalSinceNow))
    }

    private var accessibilitySummary: String {
        guard let snapshot = store.snapshot else {
            return store.errorCaption ?? L10n.tr("Cursor included usage")
        }
        let percent = Int((snapshot.usedPercent * 100).rounded())
        return L10n.tr("%@: %d percent of billing period used", L10n.tr("Cursor included usage"), percent)
    }

    private var detailTooltip: String {
        var lines = [L10n.tr("Cursor included usage this billing period")]
        if let email = store.accountEmail { lines.append(email) }
        if let error = store.errorCaption { lines.append("⚠ \(error)") }
        if let snapshot = store.snapshot {
            let value = Int(quotaMode.displayValue(usedPercent: snapshot.usedPercent).rounded())
            var line = L10n.tr("Included pool: %d%%", value)
            if let plan = snapshot.planName { line += " · \(plan.capitalized)" }
            lines.append(line)
        }
        lines.append(L10n.tr("Click to open Cursor dashboard"))
        return lines.joined(separator: "\n")
    }
}
