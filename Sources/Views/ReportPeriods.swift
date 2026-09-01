import SwiftUI

/// Period math + slice loading shared by the weekly and monthly report
/// sheets' ← → pagers. Offset 0 is the current period (the live card);
/// positive offsets step back in time. The right paging bound is the
/// current period; the left bound is the earliest day with any scanned
/// token activity.
enum ReportPeriods {
    /// Earliest day with any recorded token activity across ALL providers.
    /// nil when no history has been scanned yet (paging stays disabled).
    /// Also nil in demo mode: past pages assemble from a REAL log scan, and
    /// demo exists precisely to keep real usage off screen recordings —
    /// the ← arrow simply stays disabled there.
    @MainActor
    static func earliestDataDay() -> Date? {
        guard !AppEnvironment.isDemo else { return nil }
        let cost = CostStore.shared
        return DisplayProvider.allCases
            .flatMap { cost.cost(for: $0).dailyTokens }
            .filter { $0.tokens > 0 }
            .map(\.dayStart)
            .min()
    }

    /// The 7-day block `offset` weeks behind the current card, half-open
    /// [start, end). Offset 0 reproduces the live card's window — anchored
    /// to the freshest SCANNED day, same as `WeeklyReportData.current()` —
    /// so older pages tile exactly against what the current card shows.
    @MainActor
    static func weekInterval(offset: Int) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let cost = CostStore.shared
        let today = cal.startOfDay(for: Date())
        let scanAnchor = DisplayProvider.allCases
            .compactMap { cost.cost(for: $0).dailyTokens.last?.dayStart }
            .max() ?? .distantPast
        let anchor = scanAnchor > .distantPast ? min(scanAnchor, today) : today
        let endDay = cal.startOfDay(for: cal.date(byAdding: .day, value: -7 * offset, to: anchor) ?? anchor)
        let startDay = cal.date(byAdding: .day, value: -6, to: endDay) ?? endDay
        let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: startDay, end: end)
    }

    /// The calendar month `offset` months behind the current one, half-open
    /// [monthStart, nextMonthStart). The current month (offset 0) naturally
    /// reads month-to-date — future days simply hold no events yet.
    static func monthInterval(offset: Int, now: Date = Date()) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let start = cal.date(byAdding: .month, value: -offset, to: thisMonthStart) ?? thisMonthStart
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Whether one page older than `interval` still overlaps recorded
    /// history — the ← button's enablement. Weekly and monthly pages both
    /// tile contiguously, so the older page's exclusive end equals
    /// `interval.start`: anything recorded before that instant means the
    /// older page has data to show.
    static func hasData(before interval: DateInterval, earliestDataDay: Date?) -> Bool {
        guard let earliestDataDay else { return false }
        return interval.start > earliestDataDay
    }

    /// Full-year rescan → per-provider slices for `interval`, off the main
    /// thread. The readers memoize per file, so the steady-state cost is a
    /// cache walk + dedup pass, not a re-parse — cheap enough to run per
    /// page flip. Never touches CostStore. Scans ALL five providers so a
    /// Grok-or-Cursor-only past period still fills the report card.
    static func slices(for interval: DateInterval) async -> PeriodSlices {
        let lookback = CostSummary.yearHistoryDays()
        return await Task.detached(priority: .userInitiated) {
            func slice(_ events: [TokenEvent]) -> CostSummary.ReportSlice {
                CostSummary.reportSlice(events: events, interval: interval)
            }
            return PeriodSlices(byProvider: [
                .claude: slice(ClaudeLogReader.scan(lookbackDays: lookback)),
                .codex: slice(CodexLogReader.scan(lookbackDays: lookback)),
                .grok: slice(GrokLogReader.scan(lookbackDays: lookback)),
                .cursor: slice(CursorLogReader.scan(lookbackDays: lookback)),
                .antigravity: slice(AntigravityLogReader.scan(lookbackDays: lookback)),
            ])
        }.value
    }
}

/// Per-provider report slices for one period, keyed by display identity — the
/// generalization of the old `(claude:, codex:)` tuple. A struct rather than a
/// bare dictionary so a missing provider degrades to an empty slice (never a
/// nil unwrap) and the legacy `.claude` / `.codex` call sites keep reading
/// naturally.
struct PeriodSlices {
    let byProvider: [DisplayProvider: CostSummary.ReportSlice]

    static let emptySlice = CostSummary.ReportSlice(dailyTokens: [], dollars: 0, byModel: [])

    subscript(_ provider: DisplayProvider) -> CostSummary.ReportSlice {
        byProvider[provider] ?? Self.emptySlice
    }

    /// Legacy fixed-provider accessors so the weekly report window controller
    /// (a separate file) compiles unchanged while it still passes the two-slice
    /// pair; new callers use `forInterval(_:slices:)` for the full five.
    var claude: CostSummary.ReportSlice { self[.claude] }
    var codex: CostSummary.ReportSlice { self[.codex] }
}

/// ← / → pill for the report sheets' period pager row.
struct ReportPagerArrow: View {
    let systemName: String
    let enabled: Bool
    let accessibilityKey: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.22))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(enabled ? 0.10 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(L10n.tr(accessibilityKey))
    }
}
