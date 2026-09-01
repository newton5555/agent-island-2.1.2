import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage

/// The monthly share card — the weekly card's big sibling. v4 (2026-08-09):
/// the 24-week heatmap is gone (owner's cut — it competed with the model
/// table and duplicated the panel's own year view), and so is the rank
/// block; the month reads hero → faction duel → top-3 models. Same
/// no-upload rules: rendered from local logs only.
struct MonthlyReportData {
    let monthText: String          // "2026年7月" / "July 2026"
    let totalTokens: Int           // calendar month to date, wire
    let totalDollars: Double
    let matchup: ReportMatchup     // TOP-2 duel / solo / none for the month
    let topModels: [WeeklyReportData.ModelShare]

    @MainActor
    static func current() -> MonthlyReportData {
        let cost = CostStore.shared
        let mode = TokenCountModeStore.shared.mode
        let today = Calendar.current.startOfDay(for: Date())
        let zh = L10n.locale.identifier.hasPrefix("zh")

        func monthTokens(_ p: DisplayProvider) -> Int {
            let w = cost.cost(for: p).month
            return mode == .all ? w.tokens : w.billableTokens
        }
        var monthByProvider: [DisplayProvider: Int] = [:]
        for p in DisplayProvider.allCases { monthByProvider[p] = monthTokens(p) }
        let totalTokens = monthByProvider.values.reduce(0, +)
        let totalDollars = DisplayProvider.allCases.reduce(0.0) { $0 + cost.cost(for: $1).month.dollars }

        var monthRows: [DisplayProvider: [ModelUsageRow]] = [:]
        for p in DisplayProvider.allCases { monthRows[p] = cost.cost(for: p).monthByModel }
        let models = WeeklyReportData.rankedModels(rowsByProvider: monthRows, mode: mode)

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "yyyy年M月" : "MMMM yyyy"

        return MonthlyReportData(
            monthText: df.string(from: today),
            totalTokens: totalTokens,
            totalDollars: totalDollars,
            matchup: .from(totals: monthByProvider),
            topModels: models
        )
    }

    /// Assembles a PAST calendar month from interval slices (offset ≠ 0 —
    /// the current month keeps `current()`). Same accounting as the live
    /// month window, sourced from one full-scan slice.
    @MainActor
    static func forInterval(_ interval: DateInterval, slices: PeriodSlices) -> MonthlyReportData {
        let mode = TokenCountModeStore.shared.mode
        let zh = L10n.locale.identifier.hasPrefix("zh")

        func total(_ buckets: [DailyTokenBucket]) -> Int {
            buckets.reduce(0) { $0 + (mode == .all ? $1.tokens : $1.billableTokens) }
        }
        var monthByProvider: [DisplayProvider: Int] = [:]
        for p in DisplayProvider.allCases { monthByProvider[p] = total(slices[p].dailyTokens) }
        let totalTokens = monthByProvider.values.reduce(0, +)
        let totalDollars = DisplayProvider.allCases.reduce(0.0) { $0 + slices[$1].dollars }

        var monthRows: [DisplayProvider: [ModelUsageRow]] = [:]
        for p in DisplayProvider.allCases { monthRows[p] = slices[p].byModel }
        let models = WeeklyReportData.rankedModels(rowsByProvider: monthRows, mode: mode)

        let df = DateFormatter()
        df.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        df.dateFormat = zh ? "yyyy年M月" : "MMMM yyyy"

        return MonthlyReportData(
            monthText: df.string(from: interval.start),
            totalTokens: totalTokens,
            totalDollars: totalDollars,
            matchup: .from(totals: monthByProvider),
            topModels: models
        )
    }

    /// Back-compat overload paralleling `WeeklyReportData.forInterval`. No
    /// current caller uses it (this file's sheet uses the `slices:` form), but
    /// it keeps the two `forInterval` shapes symmetric for any external caller.
    @MainActor
    static func forInterval(_ interval: DateInterval,
                            claudeSlice: CostSummary.ReportSlice,
                            codexSlice: CostSummary.ReportSlice) -> MonthlyReportData {
        forInterval(interval, slices: PeriodSlices(byProvider: [
            .claude: claudeSlice, .codex: codexSlice,
        ]))
    }
}

struct MonthlyReportCard: View {
    let data: MonthlyReportData
    var rounded: Bool = true

    static let size = CGSize(width: 420, height: 560)

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 0) {
                ReportCardHeader(kind: "MONTHLY", periodText: data.monthText)
                Spacer(minLength: 18)
                hero
                Spacer(minLength: 18)
                ReportDuel(matchup: data.matchup)
                Spacer(minLength: 22)
                ReportModelTable(models: data.topModels)
                Spacer(minLength: 22)
            }
            .padding(28)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous))
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .fill(WeeklyReportCard.baseCoat)
            RoundedRectangle(cornerRadius: rounded ? CardWindow.cornerRadius : 0, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var hero: some View {
        let zh = L10n.locale.identifier.hasPrefix("zh")
        let parts = WeeklyReportCard.compactParts(data.totalTokens, zh: zh)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("tokens this month"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.5))
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
                    Text(L10n.tr("≈ $%@ API value", WeeklyReportCard.money(data.totalDollars)))
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(IslandColor.chrome)
                }
            }
        }
    }
}

// MARK: - Renderer + window (mirrors the weekly pair)

@MainActor
enum MonthlyReportRenderer {
    private static var cachedImage: NSImage?
    private static var cachedPNG: Data?
    /// Which period the cache holds — see WeeklyReportRenderer.cachedKey.
    private static var cachedKey: String?

    static func invalidateCache() {
        cachedImage = nil
        cachedPNG = nil
        cachedKey = nil
    }

    /// No-arg variants serve the live current month (window-open warm and
    /// the headless snapshot hook).
    static func warmCache() { warmCache(data: .current(), key: "current") }

    static func warmCache(data: MonthlyReportData, key: String) {
        _ = pngData(data: data, key: key)
    }

    static func image() -> NSImage? { image(data: .current(), key: "current") }

    static func image(data: MonthlyReportData, key: String) -> NSImage? {
        if cachedKey == key, let cachedImage { return cachedImage }
        let renderer = ImageRenderer(content: MonthlyReportCard(data: data, rounded: false))
        renderer.scale = 3
        renderer.isOpaque = true
        cachedImage = renderer.nsImage
        cachedPNG = nil
        cachedKey = key
        return cachedImage
    }

    static func pngData() -> Data? { pngData(data: .current(), key: "current") }

    static func pngData(data: MonthlyReportData, key: String) -> Data? {
        if cachedKey == key, let cachedPNG { return cachedPNG }
        guard let image = image(data: data, key: key),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        cachedPNG = rep.representation(using: .png, properties: [:])
        return cachedPNG
    }

    static func writePNG(to path: String) {
        guard let data = pngData() else {
            NSLog("AgentIsland monthly report: render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

private final class MonthlyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class MonthlyReportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MonthlyReportWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        MonthlyReportRenderer.invalidateCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MonthlyReportRenderer.warmCache()
        }
        if window == nil {
            let panel = MonthlyPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 472, height: 710)),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self
            window = panel
        }
        // Rebuilt EVERY show — a cached SwiftUI tree kept serving stale data
        // and the pre-switch language (the "English UI, Chinese poster" bug).
        window?.contentView = NSHostingView(rootView: MonthlyReportSheet())
        mountCloseButton()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func mountCloseButton() {
        guard let contentView = window?.contentView,
              let close = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])
        else { return }
        close.target = window
        close.action = #selector(NSWindow.close)
        contentView.addSubview(close)
        let inset: CGFloat = 12
        // Card top = 22pt padding + 26pt pager row + 14pt spacing.
        let yFromTop: CGFloat = 22 + 26 + 14 + inset
        let y = contentView.isFlipped
            ? yFromTop
            : contentView.bounds.height - yFromTop - close.frame.height
        close.setFrameOrigin(NSPoint(x: 26 + inset, y: y))
    }
}

@MainActor
private struct MonthlyReportSheet: View {
    // Same live-store treatment as the weekly sheet: kick a rescan on open,
    // re-render when it commits, never freeze a stale launch snapshot.
    @ObservedObject private var cost = CostStore.shared
    @ObservedObject private var tokenMode = TokenCountModeStore.shared
    @State private var copied = false
    @State private var settle = 0
    @State private var coach: String?
    @State private var shareAnchor: NSView?
    @State private var pickerHolder = MonthlyPickerHolder()
    // Period pager: 0 = the current month (live store), N = N calendar
    // months back (assembled from a full-year rescan). Copy/save/share
    // always export exactly the page on screen.
    @State private var pageOffset = 0
    @State private var pagedData: MonthlyReportData?
    @State private var pageLoading = false
    /// Pick any start date → the card covers that day plus the following 29
    /// (owner ask, 2026-08-08). Arrow paging clears the anchor.
    @State private var anchorDate: Date?
    @State private var datePopoverShown = false
    @State private var anchoredData: MonthlyReportData?

    private var displayData: MonthlyReportData {
        if let anchoredData { return anchoredData }
        return pageOffset == 0 ? .current() : (pagedData ?? .current())
    }

    private var renderKey: String {
        if let anchorDate {
            return "anchor-\(Int(anchorDate.timeIntervalSince1970))"
        }
        return pageOffset == 0 ? "current" : "month-\(pageOffset)"
    }

    private var canPageBack: Bool {
        guard !pageLoading else { return false }
        return ReportPeriods.hasData(
            before: ReportPeriods.monthInterval(offset: pageOffset),
            earliestDataDay: ReportPeriods.earliestDataDay()
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            pager

            MonthlyReportCard(data: displayData)
                .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                .modifier(SettlePulse(trigger: settle))

            HStack(spacing: 10) {
                pill(copied ? L10n.tr("Copied") : L10n.tr("Copy"),
                     icon: copied ? "checkmark" : "square.on.square") {
                    if let image = MonthlyReportRenderer.image(data: displayData, key: renderKey) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                        Haptics.impact()
                        settle += 1
                        copied = true
                        showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                }
                pill(L10n.tr("Save"), icon: "arrow.down.to.line") {
                    if let data = MonthlyReportRenderer.pngData(data: displayData, key: renderKey) {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.png]
                        panel.nameFieldStringValue = "agent-island-monthly.png"
                        if panel.runModal() == .OK, let url = panel.url,
                           (try? data.write(to: url)) != nil {
                            Haptics.impact()
                            settle += 1
                            showCoach(L10n.tr("Saved as PNG"))
                        }
                    }
                }
                pill(L10n.tr("Share…"), icon: "square.and.arrow.up") {
                    showCoach(L10n.tr("Tip: AirDrop it to your iPhone — it lands in Photos, ready to post 📲"))
                    openSharePicker()
                }
                .background(
                    MonthlyShareAnchorView { shareAnchor = $0 }
                        .frame(width: 1, height: 1)
                )
            }
            // While a past page is still assembling, the card shows the
            // previous period — exporting would ship the wrong month.
            .disabled(pageLoading)
            .opacity(pageLoading ? 0.5 : 1)

            Text(coach ?? " ")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(IslandColor.liveTeal)
                .lineLimit(1)
                .opacity(coach == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: coach == nil)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .onAppear {
            CostStore.shared.refresh()
        }
        .onReceive(cost.objectWillChange) { _ in
            MonthlyReportRenderer.invalidateCache()
            DispatchQueue.main.async {
                MonthlyReportRenderer.warmCache(data: displayData, key: renderKey)
            }
        }
        .onReceive(tokenMode.objectWillChange) { _ in
            MonthlyReportRenderer.invalidateCache()
            DispatchQueue.main.async {
                // A paged card baked its totals with the previous mode —
                // rebuild it (memoized rescan, cheap); the current card
                // recomputes on its own.
                if pageOffset > 0 {
                    loadPage(pageOffset)
                } else {
                    MonthlyReportRenderer.warmCache()
                }
            }
        }
    }

    /// ← period label → row above the card. The right edge is the current
    /// month; the left edge is the earliest day with scanned data.
    private var pager: some View {
        HStack(spacing: 10) {
            ReportPagerArrow(systemName: "chevron.left",
                             enabled: canPageBack,
                             accessibilityKey: "Previous month") {
                flip(to: anchorDate == nil ? pageOffset + 1 : 1)
            }
            // Solid white when live — matches the weekly pager (owner,
            // 2026-08-09: 不能用透明的).
            Text(displayData.monthText)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(pageLoading ? 0.45 : 1))
                .frame(minWidth: 150)
            ReportPagerArrow(systemName: "chevron.right",
                             enabled: (pageOffset > 0 || anchorDate != nil) && !pageLoading,
                             accessibilityKey: "Next month") {
                flip(to: anchorDate == nil ? pageOffset - 1 : 0)
            }
            // Any-date anchor: the window becomes [picked day, +30d).
            // A real month calendar in a popover — click any day and the
            // window becomes [that day, +30d). The field-style picker read
            // as an inert text box (owner report, 2026-08-08).
            Button {
                datePopoverShown.toggle()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(anchorDate == nil
                        ? .white.opacity(0.6)
                        : IslandColor.chrome.opacity(0.95))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(pageLoading || AppEnvironment.isDemo)
            .accessibilityLabel(L10n.tr("Report start date"))
            .popover(isPresented: $datePopoverShown, arrowEdge: .bottom) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { anchorDate ?? Date() },
                        set: { date in
                            setAnchor(date)
                            datePopoverShown = false
                        }
                    ),
                    in: (ReportPeriods.earliestDataDay() ?? .distantPast)...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(width: 260)
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func setAnchor(_ date: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: date)
        anchorDate = start
        pageLoading = true
        MonthlyReportRenderer.invalidateCache()
        let interval = DateInterval(
            start: start,
            end: cal.date(byAdding: .day, value: 30, to: start) ?? start
        )
        Task {
            let slices = await ReportPeriods.slices(for: interval)
            guard anchorDate == start else { return }
            anchoredData = MonthlyReportData.forInterval(interval, slices: slices)
            pageLoading = false
            MonthlyReportRenderer.invalidateCache()
            MonthlyReportRenderer.warmCache(data: displayData, key: renderKey)
        }
    }

    private func flip(to target: Int) {
        if anchorDate != nil {
            anchorDate = nil
            anchoredData = nil
        }
        guard target >= 0, target != pageOffset || target <= 1 else { return }
        pageOffset = target
        MonthlyReportRenderer.invalidateCache()
        guard target > 0 else {
            pagedData = nil
            pageLoading = false
            DispatchQueue.main.async { MonthlyReportRenderer.warmCache() }
            return
        }
        loadPage(target)
    }

    private func loadPage(_ target: Int) {
        pageLoading = true
        let interval = ReportPeriods.monthInterval(offset: target)
        Task {
            let slices = await ReportPeriods.slices(for: interval)
            // The user may have flipped again while the scan ran.
            guard pageOffset == target else { return }
            pagedData = MonthlyReportData.forInterval(interval, slices: slices)
            pageLoading = false
            MonthlyReportRenderer.invalidateCache()
            MonthlyReportRenderer.warmCache(data: displayData, key: renderKey)
        }
    }

    private func showCoach(_ text: String) {
        coach = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if coach == text { coach = nil }
        }
    }

    @MainActor
    private func openSharePicker() {
        guard let image = MonthlyReportRenderer.image(data: displayData, key: renderKey),
              let anchor = shareAnchor else { return }
        let picker = NSSharingServicePicker(items: [image])
        pickerHolder.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func pill(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(TactileButtonStyle())
    }
}

private struct MonthlyShareAnchorView: NSViewRepresentable {
    let onReady: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Plain retain box (no actor isolation): @MainActor here broke CI —
// a @State default value is initialized in a nonisolated context, and
// newer compilers reject the implicit hop. The picker itself is only
// ever touched from the view body (main thread) anyway.
private final class MonthlyPickerHolder {
    var picker: NSSharingServicePicker?
}
