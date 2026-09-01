import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@discardableResult
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws -> Bool {
    guard condition() else { throw TestFailure.assertion(message) }
    return true
}

private let cal: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    return cal
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    guard let d = cal.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    )) else { fatalError("bad test date \(year)-\(month)-\(day)") }
    return d
}

private func event(_ timestamp: Date, model: String,
                   input: Int = 0, output: Int = 0,
                   cacheCreate: Int = 0, cacheRead: Int = 0) -> TokenEvent {
    TokenEvent(
        provider: .claude, timestamp: timestamp, model: model,
        inputTokens: input, outputTokens: output,
        cacheCreationTokens: cacheCreate, cacheReadTokens: cacheRead
    )
}

private func approxEqual(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-9
}

// Expected dollars are always derived through Pricing.cost so the tests
// stay green across price-table refreshes — they check the slicing, not
// the rates.
private func testCrossMonthWeekSlice() throws {
    let opus = "claude-opus-4-5"
    let sonnet = "claude-sonnet-5"

    let before = event(date(2026, 4, 27, 23), model: opus, input: 999, output: 999)
    let atStart = event(date(2026, 4, 28, 0), model: opus, input: 100, output: 50, cacheRead: 1_000)
    let april30 = event(date(2026, 4, 30, 12), model: opus, input: 2_000, output: 1_000, cacheCreate: 500)
    let may2 = event(date(2026, 5, 2, 8), model: sonnet, input: 300, output: 700, cacheRead: 4_000)
    let may4 = event(date(2026, 5, 4, 23, 59), model: opus, input: 50, output: 25)
    let atEnd = event(date(2026, 5, 5, 0), model: sonnet, input: 888, output: 888)

    let interval = DateInterval(start: date(2026, 4, 28), end: date(2026, 5, 5))
    let slice = CostSummary.reportSlice(
        events: [before, atStart, april30, may2, may4, atEnd],
        interval: interval
    )

    try expect(slice.dailyTokens.count == 7, "cross-month week must produce 7 daily buckets, got \(slice.dailyTokens.count)")
    try expect(cal.isDate(slice.dailyTokens[0].dayStart, inSameDayAs: date(2026, 4, 28)),
               "first bucket must be Apr 28")
    try expect(cal.isDate(slice.dailyTokens[6].dayStart, inSameDayAs: date(2026, 5, 4)),
               "last bucket must be May 4")

    // Interval bounds: start inclusive, end exclusive.
    try expect(slice.dailyTokens[0].tokens == 100 + 50 + 1_000,
               "start-boundary event must be included in day 0")
    try expect(slice.dailyTokens[0].billableTokens == 150,
               "billable excludes cache reads")
    try expect(slice.dailyTokens[2].tokens == 2_000 + 1_000 + 500, "Apr 30 lands in bucket 2")
    try expect(slice.dailyTokens[3].tokens == 0, "May 1 has no events")
    try expect(slice.dailyTokens[4].tokens == 300 + 700 + 4_000, "May 2 lands in bucket 4")
    try expect(slice.dailyTokens[6].tokens == 75, "May 4 lands in bucket 6")

    let expectedDollars = [atStart, april30, may2, may4].reduce(0.0) { $0 + Pricing.cost(for: $1) }
    try expect(approxEqual(slice.dollars, expectedDollars),
               "dollars must sum exactly the in-interval events (got \(slice.dollars), want \(expectedDollars))")
    try expect(expectedDollars > 0, "sanity: priced models should cost more than $0")

    // Per-model split across the month boundary.
    guard let opusRow = slice.byModel.first(where: { $0.model == opus }),
          let sonnetRow = slice.byModel.first(where: { $0.model == sonnet }) else {
        throw TestFailure.assertion("both models must appear in byModel rows")
    }
    try expect(opusRow.tokens == 150 + 3_000 + 75, "opus billable across the boundary")
    try expect(opusRow.wireTokens == 1_150 + 3_500 + 75, "opus wire tokens include cache")
    try expect(sonnetRow.tokens == 1_000, "sonnet billable")
    try expect(sonnetRow.wireTokens == 5_000, "sonnet wire tokens")
    let expectedOpusDollars = [atStart, april30, may4].reduce(0.0) { $0 + Pricing.cost(for: $1) }
    try expect(approxEqual(opusRow.dollars, expectedOpusDollars),
               "opus dollars must sum its in-interval events")
    try expect(approxEqual(sonnetRow.dollars, Pricing.cost(for: may2)),
               "sonnet dollars must be the single May 2 event")
    try expect(approxEqual(opusRow.dollars + sonnetRow.dollars, slice.dollars),
               "per-model dollars must sum to the slice total")
    try expect(slice.byModel.first?.model == opus,
               "rows sort by billable tokens descending")
    try expect(approxEqual(opusRow.percent, Double(opusRow.tokens) / Double(opusRow.tokens + sonnetRow.tokens)),
               "percent is share of the slice's billable tokens")
}

private func testUnpricedModelKeepsTokensAtZeroDollars() throws {
    let mystery = event(date(2026, 7, 10, 9), model: "mystery-model", input: 400, output: 100)
    let interval = DateInterval(start: date(2026, 7, 6), end: date(2026, 7, 13))
    let slice = CostSummary.reportSlice(events: [mystery], interval: interval)

    try expect(approxEqual(slice.dollars, 0), "unknown model prices to $0 (ccusage parity)")
    guard let row = slice.byModel.first else {
        throw TestFailure.assertion("unpriced model must still produce a token row")
    }
    try expect(row.tokens == 500 && approxEqual(row.dollars, 0),
               "row keeps tokens while dollars stay 0")
    try expect(slice.dailyTokens.reduce(0) { $0 + $1.tokens } == 500,
               "daily buckets carry the tokens")
}

private func testSliceAgreesWithSummarizeMonthWindow() throws {
    // A full calendar-month slice must reproduce summarize's month window —
    // same dollars, same per-model rows — proving both paths share one
    // accounting.
    let events = [
        event(date(2026, 6, 3, 10), model: "claude-opus-4-5", input: 5_000, output: 2_000, cacheRead: 90_000),
        event(date(2026, 6, 15, 14), model: "claude-sonnet-5", input: 1_200, output: 3_400, cacheCreate: 7_000),
        event(date(2026, 6, 28, 22), model: "claude-opus-4-5", input: 600, output: 250),
        event(date(2026, 5, 31, 23), model: "claude-opus-4-5", input: 9_999, output: 9_999),
    ]
    let now = date(2026, 6, 29, 12)
    let live = CostSummary.summarize(events: events, now: now)
    let slice = CostSummary.reportSlice(
        events: events,
        interval: DateInterval(start: date(2026, 6, 1), end: date(2026, 7, 1))
    )

    try expect(approxEqual(slice.dollars, live.month.dollars),
               "slice dollars must equal summarize's month window (\(slice.dollars) vs \(live.month.dollars))")
    try expect(slice.dailyTokens.reduce(0) { $0 + $1.tokens } == live.month.tokens,
               "slice bucket total must equal summarize's month tokens")
    try expect(slice.byModel.count == live.monthByModel.count, "same model row count")
    for (a, b) in zip(slice.byModel, live.monthByModel) {
        try expect(a.model == b.model && a.tokens == b.tokens
                    && a.wireTokens == b.wireTokens && approxEqual(a.dollars, b.dollars),
                   "per-model row \(a.model) must match summarize's month row")
    }
}

private func testSingleDayInterval() throws {
    let e = event(date(2026, 8, 1, 13), model: "claude-opus-4-5", input: 10, output: 20)
    let slice = CostSummary.reportSlice(
        events: [e],
        interval: DateInterval(start: date(2026, 8, 1), end: date(2026, 8, 2))
    )
    try expect(slice.dailyTokens.count == 1, "single-day interval yields one bucket")
    try expect(slice.dailyTokens[0].tokens == 30, "the day's tokens land in it")
}

@main
private enum CostReportSliceTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("cross-month week slice", testCrossMonthWeekSlice),
            ("unpriced model keeps tokens at zero dollars", testUnpricedModelKeepsTokensAtZeroDollars),
            ("full-month slice agrees with summarize", testSliceAgreesWithSummarizeMonthWindow),
            ("single-day interval", testSingleDayInterval),
        ]

        do {
            for (name, test) in tests {
                try test()
                print("PASS \(name)")
            }
            print("CostReportSliceTests GREEN")
        } catch {
            fputs("CostReportSliceTests RED: \(error)\n", stderr)
            exit(1)
        }
    }
}
