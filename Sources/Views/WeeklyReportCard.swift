import SwiftUI
import AppKit
import CoreImage

/// The shareable weekly report — a fixed-size portrait card rendered from
/// LOCAL data only (CostStore's log scan + UsageStore quota). Users copy or
/// save it as a PNG and post it themselves; nothing is ever uploaded, which
/// is what lets this exist at all under the no-telemetry promise.
///
/// v4 (2026-08-09): flat near-black coat — NO gradients (external design
/// review: 底色渐变删掉, and gradients band badly under social-app
/// compression) — brand mark joins the wordmark up top, the API-value line
/// rides beside the hero number, the faction duel replaces the bare split
/// bar, and the model table closes on the TOP-3. The v3 rank block (酋长
/// 段位) is gone — owner cut the feature outright.
struct WeeklyReportData {
    struct ModelShare: Identifiable {
        let id = UUID()
        let name: String
        let tokens: Int       // wire or billable per TokenCountMode
        let dollars: Double   // API value this week (0 for providers with no price)
        let percent: Double   // 0...1 of the period's token universe
        let provider: DisplayProvider
        let color: Color
    }

    let rangeText: String
    let totalTokens: Int
    let totalDollars: Double
    let matchup: ReportMatchup   // TOP-2 duel / solo / none for the period
    let dailyTokens: [Int]    // oldest → today, exactly 7
    let dayLetters: [String]
    let topModels: [ModelShare]

    /// Assembles the last 7 calendar days from CostStore. All local.
    @MainActor
    static func current() -> WeeklyReportData {
        let cost = CostStore.shared
        let cal = Calendar.current
        let mode = TokenCountModeStore.shared.mode
        // Anchor the 7-day window to the freshest SCANNED day, not the wall
        // clock. Right after launch (or during a long first scan) the store
        // can still hold yesterday's snapshot; a wall-clock window then
        // shears against weekByModel — whose window is scan-anchored — and
        // a single model row can exceed the hero total (field report: a
        // 125亿 row on a 114亿 card). Anchoring every series to the
        // snapshot's own day keeps the whole card on one window.
        let today = cal.startOfDay(for: Date())
        let scanAnchor = DisplayProvider.allCases
            .compactMap { cost.cost(for: $0).dailyTokens.last?.dayStart }
            .max() ?? .distantPast
        let anchor = scanAnchor > .distantPast ? min(scanAnchor, today) : today
        let days: [Date] = (0..<7).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: anchor)
        }

        func bucketTotal(_ buckets: [DailyTokenBucket], _ day: Date) -> Int {
            guard let b = buckets.first(where: { cal.isDate($0.dayStart, inSameDayAs: day) }) else { return 0 }
            return mode == .all ? b.tokens : b.billableTokens
        }
        // Per-provider daily series, summed into the card's day bars and each
        // provider's own weekly total (which drives the duel matchup).
        var perProviderDaily: [DisplayProvider: [Int]] = [:]
        for provider in DisplayProvider.allCases {
            let buckets = cost.cost(for: provider).dailyTokens
            perProviderDaily[provider] = days.map { bucketTotal(buckets, $0) }
        }
        let daily = days.indices.map { i in
            perProviderDaily.values.reduce(0) { $0 + $1[i] }
        }
        let weekByProvider = perProviderDaily.mapValues { $0.reduce(0, +) }
        let total = weekByProvider.values.reduce(0, +)

        let dollars = DisplayProvider.allCases.reduce(0.0) { sum, p in
            sum + cost.cost(for: p).weekByModel.reduce(0.0) { $0 + $1.dollars }
        }

        let zh = L10n.locale.identifier.hasPrefix("zh")
        var weekRows: [DisplayProvider: [ModelUsageRow]] = [:]
        for p in DisplayProvider.allCases { weekRows[p] = cost.cost(for: p).weekByModel }
        let models = Self.rankedModels(rowsByProvider: weekRows, mode: mode)

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "M月d日" : "MMM d"
        let range = "\(df.string(from: days.first ?? anchor)) – \(df.string(from: anchor))"

        let letters: [String]
        if zh {
            let zhDays = ["日", "一", "二", "三", "四", "五", "六"]
            letters = days.map { zhDays[cal.component(.weekday, from: $0) - 1] }
        } else {
            let letterFmt = DateFormatter()
            letterFmt.locale = Locale(identifier: "en_US_POSIX")
            letterFmt.dateFormat = "EEEEE"
            letters = days.map { letterFmt.string(from: $0) }
        }

        return WeeklyReportData(
            rangeText: range,
            totalTokens: total,
            totalDollars: dollars,
            matchup: .from(totals: weekByProvider),
            dailyTokens: daily,
            dayLetters: letters,
            topModels: models
        )
    }

    /// Assembles a PAST page of the report pager from interval slices
    /// (offset ≠ 0 — the current page keeps `current()`). Mirrors
    /// `current()` in shape; daily bars, totals, and per-model rows come
    /// from one full-scan slice instead of the live store windows, so the
    /// whole card sits on a single consistent window by construction.
    @MainActor
    static func forInterval(_ interval: DateInterval, slices: PeriodSlices) -> WeeklyReportData {
        let cal = Calendar.current
        let mode = TokenCountModeStore.shared.mode
        let zh = L10n.locale.identifier.hasPrefix("zh")

        let firstDay = cal.startOfDay(for: interval.start)
        let days: [Date] = (0..<7).compactMap {
            cal.date(byAdding: .day, value: $0, to: firstDay)
        }

        func bucketValue(_ b: DailyTokenBucket) -> Int {
            mode == .all ? b.tokens : b.billableTokens
        }
        var perProviderDaily: [DisplayProvider: [Int]] = [:]
        for p in DisplayProvider.allCases {
            perProviderDaily[p] = slices[p].dailyTokens.map(bucketValue)
        }
        let daily = (0..<days.count).map { i in
            perProviderDaily.values.reduce(0) { $0 + (i < $1.count ? $1[i] : 0) }
        }
        let weekByProvider = perProviderDaily.mapValues { $0.reduce(0, +) }
        let total = weekByProvider.values.reduce(0, +)
        let dollars = DisplayProvider.allCases.reduce(0.0) { $0 + slices[$1].dollars }

        var weekRows: [DisplayProvider: [ModelUsageRow]] = [:]
        for p in DisplayProvider.allCases { weekRows[p] = slices[p].byModel }
        let models = Self.rankedModels(rowsByProvider: weekRows, mode: mode)

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "M月d日" : "MMM d"
        let lastDay = days.last ?? firstDay
        let range = "\(df.string(from: firstDay)) – \(df.string(from: lastDay))"

        let letters: [String]
        if zh {
            let zhDays = ["日", "一", "二", "三", "四", "五", "六"]
            letters = days.map { zhDays[cal.component(.weekday, from: $0) - 1] }
        } else {
            let letterFmt = DateFormatter()
            letterFmt.locale = Locale(identifier: "en_US_POSIX")
            letterFmt.dateFormat = "EEEEE"
            letters = days.map { letterFmt.string(from: $0) }
        }

        return WeeklyReportData(
            rangeText: range,
            totalTokens: total,
            totalDollars: dollars,
            matchup: .from(totals: weekByProvider),
            dailyTokens: daily,
            dayLetters: letters,
            topModels: models
        )
    }

    /// Back-compat overload for the weekly report window controller (a file
    /// outside this task's ownership), which still passes the Claude+Codex
    /// pair. It builds a two-provider `PeriodSlices` and forwards — so past
    /// weekly pages show those two until that controller is switched to the
    /// five-provider `slices:` path. Every other entry point already passes
    /// the full five.
    @MainActor
    static func forInterval(_ interval: DateInterval,
                            claudeSlice: CostSummary.ReportSlice,
                            codexSlice: CostSummary.ReportSlice) -> WeeklyReportData {
        forInterval(interval, slices: PeriodSlices(byProvider: [
            .claude: claudeSlice, .codex: codexSlice,
        ]))
    }

    /// TOP-3 models across ALL FIVE providers (owner call, 2026-08-09: 只要写
    /// 前三的模型就够了 — the full list buried the card in rows). The donut's
    /// uncovered arc is everything below the cut, so the ring still tells the
    /// truth about the long tail. A Grok-and-Gemini-only week still ranks.
    ///
    /// Segment SIZE and sorting are by TOKEN share, the one metric every
    /// provider defines: Cursor ships tokens with no price, Gemini nothing —
    /// dollar-ranking (the old two-provider behavior) would filter a
    /// Cursor-only week to an empty donut. The dollar figure still rides each
    /// row where the provider can price it.
    ///
    /// Colors are the PROVIDER's brand hue (the 2026-08-08 five-provider spec
    /// supersedes the 2026-07-14 categorical palette). Same-provider neighbors
    /// get a mild opacity step so two Claude models don't merge into one arc
    /// while the terracotta family stays legible.
    static func rankedModels(
        rowsByProvider: [DisplayProvider: [ModelUsageRow]],
        mode: TokenCountMode = .all
    ) -> [ModelShare] {
        let tokenOf: (ModelUsageRow) -> Int = { mode == .all ? $0.wireTokens : $0.tokens }
        let flat: [(provider: DisplayProvider, row: ModelUsageRow)] =
            rowsByProvider.flatMap { provider, rows in rows.map { (provider, $0) } }
        let universe = max(1, flat.reduce(0) { $0 + tokenOf($1.row) })

        let ranked = flat
            .map { entry -> (provider: DisplayProvider, name: String, tokens: Int, dollars: Double, percent: Double) in
                let tokens = tokenOf(entry.row)
                return (entry.provider, entry.row.displayName, tokens, entry.row.dollars,
                        Double(tokens) / Double(universe))
            }
            .filter { $0.percent >= 0.005 }
            .sorted { $0.percent > $1.percent }
            .prefix(3)

        var seenPerProvider: [DisplayProvider: Int] = [:]
        return ranked.map { m in
            let step = seenPerProvider[m.provider, default: 0]
            seenPerProvider[m.provider] = step + 1
            let dim = max(0.5, 1.0 - Double(step) * 0.2)
            return ModelShare(name: m.name, tokens: m.tokens, dollars: m.dollars,
                              percent: m.percent, provider: m.provider,
                              color: m.provider.brandColor.opacity(dim))
        }
    }
}

private extension DisplayProvider {
    /// Whether the app can attach a dollar figure to this provider's models.
    /// Mirrors CostView's per-provider face split: Claude/Codex priced from the
    /// embedded table, Grok self-reports its cost; Cursor is tokens-only (no
    /// model → no price) and Gemini has no local ledger. The honesty rule: a
    /// cost the app can't compute reads "—", never a guessed $0.
    var reportShowsDollars: Bool {
        switch self {
        case .claude, .codex, .grok: return true
        case .cursor, .antigravity: return false
        }
    }
}

struct WeeklyReportCard: View {
    let data: WeeklyReportData
    /// The in-window card is rounded; the EXPORTED card is square-cornered
    /// and full-bleed — social apps flatten transparency to white, so any
    /// rounded transparent corner pastes as ugly white nicks.
    var rounded: Bool = true

    static let size = CGSize(width: 420, height: 560)

    /// v3 base coat — one flat near-black. Deliberately NOT a gradient.
    static let baseCoat = Color(red: 0.051, green: 0.059, blue: 0.075)

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 0) {
                ReportCardHeader(kind: "WEEKLY", periodText: data.rangeText)
                Spacer(minLength: 14)
                hero
                Spacer(minLength: 12)
                ReportDuel(matchup: data.matchup)
                Spacer(minLength: 14)
                weekBars
                Spacer(minLength: 14)
                ReportModelTable(models: data.topModels)
                Spacer(minLength: 14)
            }
            .padding(28)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous))
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .fill(Self.baseCoat)
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var hero: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let parts = Self.compactParts(data.totalTokens, zh: zh)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("tokens this week"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.5))
            // Money line RIDES the number's baseline (owner, 2026-07-17) —
            // the freed height goes to the duel above the beam.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts.0)
                        .font(.system(size: 50, weight: .heavy))
                    if !parts.1.isEmpty {
                        Text(parts.1)
                            .font(.system(size: zh ? 24 : 50, weight: .heavy))
                    }
                }
                .foregroundStyle(Color(red: 0.95, green: 0.96, blue: 0.97))
                // The number NEVER wraps or truncates — it wins the row,
                // and the money line shrinks instead (420pt card, zh money
                // string is long; unguarded this wrapped mid-number).
                .fixedSize()
                .layoutPriority(2)
                if data.totalDollars >= 1 {
                    Text(L10n.tr("≈ $%@ API value", Self.money(data.totalDollars)))
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(IslandColor.chrome)
                }
            }
        }
    }

    private var weekBars: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let peak = max(data.dailyTokens.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(data.dailyTokens.enumerated()), id: \.offset) { i, tokens in
                let isPeak = tokens == peak && tokens > 0
                VStack(spacing: 5) {
                    Text(isPeak ? Self.compactString(tokens, zh: zh) : " ")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(IslandColor.chrome)
                        .opacity(isPeak ? 1 : 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isPeak
                              ? AnyShapeStyle(IslandColor.chrome)
                              : AnyShapeStyle(Color.white.opacity(tokens > 0 ? 0.16 : 0.07)))
                        .frame(height: max(5, 58 * CGFloat(tokens) / CGFloat(peak)))
                    Text(data.dayLetters.indices.contains(i) ? data.dayLetters[i] : "")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isPeak ? IslandColor.chrome : .white.opacity(0.32))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 88, alignment: .bottom)
    }

    // MARK: - Formatting

    static func compactString(_ n: Int, zh: Bool) -> String {
        let parts = compactParts(n, zh: zh)
        return parts.0 + parts.1
    }

    /// (value, unit). Chinese counts in 亿/万 — the way the number is
    /// actually said — English in B/M/K.
    static func compactParts(_ n: Int, zh: Bool) -> (String, String) {
        let v = Double(n)
        if zh {
            if v >= 100_000_000 { return (trim(v / 100_000_000), "亿") }
            if v >= 10_000 { return (trim(v / 10_000), "万") }
            return ("\(n)", "")
        }
        switch v {
        case 1_000_000_000...: return (trim(v / 1_000_000_000), "B")
        case 1_000_000...:     return (trim(v / 1_000_000), "M")
        case 1_000...:         return (trim(v / 1_000), "K")
        default:               return ("\(n)", "")
        }
    }

    private static func trim(_ v: Double) -> String {
        // No trailing zeros — "99.5亿", never "99.50亿".
        var s = v >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
    }
}

// MARK: - v3 shared sections (weekly + monthly)

/// Brand mark + wordmark left, period right. The bare transparent mark —
/// neither the app icon (a near-black plate that vanished into the card's
/// near-black coat) nor the boxed tile (owner review ×2, 2026-08-09).
struct ReportCardHeader: View {
    let kind: String        // "WEEKLY" / "MONTHLY"
    let periodText: String

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            BrandMark(side: 22)
            (Text("AGENT ISLAND ")
                .foregroundColor(.white.opacity(0.88))
             + Text(kind)
                .foregroundColor(IslandColor.chrome))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(3.0)
            Spacer()
            // Solid white — the 0.42 ghost text was unfindable on the card
            // (owner, 2026-08-09: 要用白色的，不能用透明的).
            Text(periodText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}

/// Donut + rows, TOP-N. Every model carries all three numbers (tokens,
/// dollars, share); the donut's uncovered arc is the long tail.
struct ReportModelTable: View {
    let models: [WeeklyReportData.ModelShare]

    var body: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.07), lineWidth: 13)
                ForEach(segments, id: \.0.id) { row, from, to in
                    Circle()
                        .trim(from: CGFloat(from), to: CGFloat(to))
                        .stroke(row.color, style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                }
            }
            .rotationEffect(.degrees(-90))
            .overlay {
                Text(L10n.tr("MODELS"))
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(models) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(row.color)
                            .frame(width: 7, height: 7)
                        Text(row.name)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(WeeklyReportCard.compactString(row.tokens, zh: zh))
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                        // A dollar figure only where the provider can be priced;
                        // Cursor/Gemini rows read "—", never a guessed $0.
                        Text(row.provider.reportShowsDollars ? "$\(WeeklyReportCard.money(row.dollars))" : "—")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62).opacity(0.9))
                        Text("\(Int((row.percent * 100).rounded()))%")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Cumulative (row, from, to) sweep per model, with a hairline gap
    /// between segments so same-hue neighbors stay separable.
    private var segments: [(WeeklyReportData.ModelShare, Double, Double)] {
        var cum = 0.0
        return models.map { row in
            let start = cum
            cum += row.percent
            let gap = row.percent > 0.03 ? 0.006 : 0.0
            return (row, start + gap, max(start + gap, cum - gap))
        }
    }
}
