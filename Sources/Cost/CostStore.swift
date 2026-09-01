import Foundation
import Combine

/// Singleton equivalent of `UsageStore` for the cost screen. Reads local
/// session logs (Claude Code, Codex CLI, Grok, Cursor, Gemini), aggregates
/// today + month-to-date spend plus overview token history per provider, and
/// publishes the result for SwiftUI consumers.
///
/// Per-provider loading flags drive parallel scans that commit independently
/// — Codex (small) appears within ~50ms while Claude (often 20k+ events)
/// continues to scan in the background. Last-known totals are cached to
/// UserDefaults so the first hover after launch shows yesterday's snapshot
/// instantly rather than zeros.
@MainActor
final class CostStore: ObservableObject {
    static let shared = CostStore()

    /// Per-provider cost summary, keyed by display identity. Absent keys read
    /// as `.empty` through `cost(for:)`, so a provider with no local ledger
    /// (Gemini today) never fabricates a row.
    @Published private(set) var costs: [DisplayProvider: ProviderCost] = [:]
    /// Per-provider scan-in-flight flags. Absent keys read as `false`.
    @Published private(set) var loadingByProvider: [DisplayProvider: Bool] = [:]
    @Published var lastUpdated: Date?

    // MARK: - Accessors

    func cost(for provider: DisplayProvider) -> ProviderCost {
        costs[provider] ?? .empty
    }

    func isLoading(_ provider: DisplayProvider) -> Bool {
        loadingByProvider[provider] ?? false
    }

    /// Legacy fixed-provider accessors kept so existing call sites (overview,
    /// weekly/monthly report cards, report pager) compile unchanged.
    var claude: ProviderCost { cost(for: .claude) }
    var codex: ProviderCost { cost(for: .codex) }
    var claudeLoading: Bool { isLoading(.claude) }
    var codexLoading: Bool { isLoading(.codex) }

    var loading: Bool { loadingByProvider.values.contains(true) }

    private static let cacheKey = "AgentIsland.costCache.v8"
    private static let cacheEncoder = JSONEncoder()
    private static let cacheDecoder = JSONDecoder()
    /// A gate older than this is presumed WEDGED (see `scanProvider`).
    private static let wedgeAge: TimeInterval = 600
    private var pollTimer: Timer?
    private var intervalCancellable: AnyCancellable?
    /// Wedge detection for the per-provider scan gates (see `scanProvider`).
    private var scanStartedAt: [DisplayProvider: Date] = [:]

    private var pollInterval: TimeInterval {
        TimeInterval(RefreshIntervalStore.shared.seconds)
    }

    private init() {
        if AppEnvironment.isDemo {
            loadDemoData()
            return
        }
        restoreFromCache()
    }

    func refresh() {
        // Demo mode: skip log scanning, inject hand-tuned numbers that
        // tell a "user extracts more value than the $200 subscription"
        // story. Never persists, so real cache is preserved.
        if AppEnvironment.isDemo {
            loadDemoData()
            return
        }
        // Every provider scans on its own gate — a slow Claude scan never
        // blocks a fast Codex one, and each commits the moment its own log
        // walk finishes. Gemini/Grok/Cursor ride the same machinery even
        // though most contribute little (Gemini none today).
        scanProvider(.claude) { ClaudeLogReader.scan(lookbackDays: $0) }
        scanProvider(.codex) { CodexLogReader.scan(lookbackDays: $0) }
        scanProvider(.grok) { GrokLogReader.scan(lookbackDays: $0) }
        scanProvider(.cursor) { CursorLogReader.scan(lookbackDays: $0) }
        scanProvider(.antigravity) { AntigravityLogReader.scan(lookbackDays: $0) }
    }

    /// Per-provider gate so a slow scan doesn't block a fast one on the next
    /// tick. A gate older than 10 minutes is presumed WEDGED (a scan that
    /// will never commit) and falls through to a fresh scan — one stuck task
    /// must not freeze cost data for the rest of the process lifetime
    /// (2026-07-17 incident: parse cache and panel numbers frozen for six
    /// hours behind exactly this latch).
    private func scanProvider(
        _ provider: DisplayProvider,
        _ scan: @escaping @Sendable (Int) -> [TokenEvent]
    ) {
        let wedged = scanStartedAt[provider]
            .map { Date().timeIntervalSince($0) > Self.wedgeAge } ?? false
        guard !isLoading(provider) || wedged else { return }
        loadingByProvider[provider] = true
        scanStartedAt[provider] = Date()
        let days = CostSummary.yearHistoryDays()
        Task.detached(priority: .userInitiated) { [weak self] in
            let events = scan(days)
            let cost = CostSummary.summarize(events: events)
            await self?.commit(provider, cost)
        }
    }

    private func commit(_ provider: DisplayProvider, _ cost: ProviderCost) {
        costs[provider] = cost
        loadingByProvider[provider] = false
        scanStartedAt[provider] = nil
        lastUpdated = Date()
        persist()
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        armTimer()
        intervalCancellable = RefreshIntervalStore.shared.$seconds
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.armTimer() }
            }
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        intervalCancellable?.cancel()
        intervalCancellable = nil
    }

    private func armTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    /// Demo data for screen recordings, derived from the maintainer's real
    /// April 2026 logs aggregated via /tmp/april_dump.py. "Today" mirrors
    /// April 29 (a balanced active day across both providers); monthly
    /// totals + cumulative series are the actual full-April aggregates.
    /// Month label hardcoded to "April" so the data and the header agree
    /// even when the real system clock has rolled into May.
    private func loadDemoData() {
        // Claude: morning-warrior pattern — early start, big morning push,
        // lunch plateau, afternoon resurge, tapering evening. Multi-peak.
        // Monthly is the real April aggregate (already bursty/stepped).
        // Demo billable tokens are ~10% of total — the typical ratio when
        // cache reads dominate Claude Code workflows.
        costs[.claude] = ProviderCost(
            today: CostWindow(
                dollars: 146.61, tokens: 211_240_000, billableTokens: 21_124_000,
                series: [0, 0, 0, 0, 0, 0, 0.8, 4.5, 18.2, 38.7, 58.3, 71.4, 73.8, 76.5, 87.2, 102.8, 117.4, 128.6, 135.2, 140.7, 144.5, 146.0, 146.4, 146.61],
                label: "Today", error: nil, unknownModels: []
            ),
            month: CostWindow(
                dollars: 1510.80, tokens: 2_170_970_947, billableTokens: 217_097_094,
                series: [4.32, 11.52, 41.47, 47.80, 67.99, 88.68, 208.14, 249.74, 327.76, 406.09, 438.15, 462.90, 477.83, 576.16, 618.03, 689.91, 710.34, 805.93, 851.29, 866.94, 866.94, 902.46, 951.91, 1010.17, 1073.80, 1128.92, 1182.69, 1219.69, 1366.31, 1510.80],
                label: "April", error: nil, unknownModels: []
            ),
            recentByModel: Self.demoModelRows([
                ("claude-fable-5", "Fable 5", 12_000_000, 120_000_000, 88.00),
                ("claude-opus-4-8", "Opus 4.8", 9_124_000, 91_240_000, 58.61),
            ]),
            weekByModel: Self.demoModelRows([
                ("claude-fable-5", "Fable 5", 64_000_000, 640_000_000, 210.00),
                ("claude-opus-4-8", "Opus 4.8", 44_800_000, 448_000_000, 125.00),
            ]),
            monthByModel: Self.demoModelRows([
                ("claude-fable-5", "Fable 5", 125_000_000, 1_250_000_000, 900.40),
                ("claude-opus-4-8", "Opus 4.8", 92_097_094, 920_970_947, 610.40),
            ]),
            dailyTokens: Self.demoDailyBuckets([
                24, 31, 128, 44, 82, 76, 310, 122, 218, 236,
                98, 64, 47, 286, 140, 205, 59, 276, 119, 48,
                0, 86, 136, 154, 168, 148, 132, 94, 402, 211,
            ], millionScale: 1_000_000)
        )
        // Codex: evening-person pattern — flat all morning, light midday,
        // explodes 6pm-11pm. Single big surge contrasts Claude's two-peak day.
        // Monthly is a smooth accelerating curve (linearly-rising daily
        // deltas, $12 → $77/day) — visually opposite to Claude's stepped jumps.
        costs[.codex] = ProviderCost(
            today: CostWindow(
                dollars: 136.50, tokens: 164_120_000, billableTokens: 32_824_000,
                series: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2.4, 6.8, 11.5, 17.2, 22.8, 28.4, 38.5, 51.7, 67.4, 84.6, 102.3, 118.8, 130.4, 136.50],
                label: "Today", error: nil, unknownModels: []
            ),
            month: CostWindow(
                dollars: 1342.60, tokens: 1_614_300_000, billableTokens: 322_860_000,
                series: [12.20, 26.70, 43.50, 62.40, 83.70, 107.10, 132.80, 160.70, 190.90, 223.30, 257.90, 294.80, 333.90, 375.30, 418.90, 464.70, 512.80, 563.10, 615.70, 670.50, 727.50, 786.80, 848.30, 912.00, 978.00, 1046.20, 1116.70, 1189.40, 1264.30, 1342.60],
                label: "April", error: nil, unknownModels: []
            ),
            recentByModel: Self.demoModelRows([
                ("gpt-5.6-sol", "GPT-5.6-sol", 32_824_000, 164_120_000, 136.50),
            ]),
            weekByModel: Self.demoModelRows([
                ("gpt-5.6-sol", "GPT-5.6-sol", 35_800_000, 358_000_000, 244.00),
            ]),
            monthByModel: Self.demoModelRows([
                ("gpt-5.6-sol", "GPT-5.6-sol", 322_860_000, 1_614_300_000, 1_342.60),
            ]),
            dailyTokens: Self.demoDailyBuckets([
                12, 18, 24, 29, 37, 42, 51, 59, 66, 74,
                83, 90, 99, 108, 117, 124, 136, 145, 157, 166,
                175, 188, 201, 214, 228, 239, 254, 268, 282, 164,
            ], millionScale: 1_000_000)
        )
        self.lastUpdated = Date()
    }

    private static func demoModelRows(
        _ rows: [(model: String, displayName: String, billableTokens: Int,
                  wireTokens: Int, dollars: Double)]
    ) -> [ModelUsageRow] {
        let billableTotal = max(1, rows.reduce(0) { $0 + $1.billableTokens })
        let dollarTotal = max(0.01, rows.reduce(0.0) { $0 + $1.dollars })
        return rows.map { row in
            ModelUsageRow(
                model: row.model,
                displayName: row.displayName,
                tokens: row.billableTokens,
                wireTokens: row.wireTokens,
                dollars: row.dollars,
                percent: Double(row.billableTokens) / Double(billableTotal),
                dollarPercent: row.dollars / dollarTotal
            )
        }
    }

    private static func demoDailyBuckets(
        _ values: [Int],
        millionScale: Int
    ) -> [DailyTokenBucket] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let days = CostSummary.yearHistoryDays()
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return (0..<days).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: start) ?? start
            let value = values[offset % values.count]
            let tokens = value * millionScale
            return DailyTokenBucket(dayStart: day, tokens: tokens, billableTokens: tokens / 10)
        }
    }

    // MARK: - Cache

    /// One provider's persisted slice. Only the fields the panel reads on a
    /// cold start are kept — per-model rows are recomputed on first scan.
    /// `unknownModels` defaults to empty so a snapshot that pre-dates the
    /// field still decodes.
    private struct ProviderCacheEntry: Codable {
        var todayDollars: Double
        var monthDollars: Double
        var todayTokens: Int
        var monthTokens: Int
        var todayBillable: Int = 0
        var monthBillable: Int = 0
        var todaySeries: [Double]
        var monthSeries: [Double]
        var todayUnknown: [String] = []
        var monthUnknown: [String] = []
        var dailyTokens: [DailyTokenBucket]
    }

    /// Full snapshot keyed by provider raw value. Replaces the fixed
    /// claude/codex field layout so a fourth or fifth provider persists
    /// without another key bump. Unknown keys drop on decode.
    private struct CacheSnapshot: Codable {
        var providers: [String: ProviderCacheEntry]
        var lastUpdated: Date?
    }

    /// Encodes the full snapshot as a single Data value — one write per
    /// refresh cycle rather than a key per provider field.
    private func persist() {
        var entries: [String: ProviderCacheEntry] = [:]
        for (provider, cost) in costs {
            entries[provider.rawValue] = ProviderCacheEntry(
                todayDollars: cost.today.dollars,
                monthDollars: cost.month.dollars,
                todayTokens: cost.today.tokens,
                monthTokens: cost.month.tokens,
                todayBillable: cost.today.billableTokens,
                monthBillable: cost.month.billableTokens,
                todaySeries: cost.today.series,
                monthSeries: cost.month.series,
                todayUnknown: cost.today.unknownModels,
                monthUnknown: cost.month.unknownModels,
                dailyTokens: cost.dailyTokens
            )
        }
        let snap = CacheSnapshot(providers: entries, lastUpdated: lastUpdated)
        if let data = try? Self.cacheEncoder.encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func restoreFromCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let snap = try? Self.cacheDecoder.decode(CacheSnapshot.self, from: data)
        else { return }

        for (raw, entry) in snap.providers {
            guard let provider = DisplayProvider(rawValue: raw) else { continue }
            costs[provider] = ProviderCost(
                today: CostWindow(dollars: entry.todayDollars, tokens: entry.todayTokens,
                                  billableTokens: entry.todayBillable,
                                  series: entry.todaySeries, label: "Today", error: nil,
                                  unknownModels: entry.todayUnknown),
                month: CostWindow(dollars: entry.monthDollars, tokens: entry.monthTokens,
                                  billableTokens: entry.monthBillable,
                                  series: entry.monthSeries,
                                  label: CostBucketing.currentMonthLabel(), error: nil,
                                  unknownModels: entry.monthUnknown),
                dailyTokens: entry.dailyTokens
            )
        }
        self.lastUpdated = snap.lastUpdated
    }
}
