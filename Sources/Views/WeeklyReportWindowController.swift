import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the weekly report card to a crisp PNG (3x) and hosts the share
/// window. Sharing is always the USER posting an image — nothing leaves
/// the machine on its own.
@MainActor
enum WeeklyReportRenderer {
    /// The EXPORT version is the card itself, full-bleed with SQUARE outer
    /// corners and no backdrop margin: social apps flatten transparency to
    /// white (ugly corner nicks) and a margin frame read as a gray box
    /// around the card. Edge-to-edge card = clean everywhere.
    private static func exportView(data: WeeklyReportData) -> some View {
        WeeklyReportCard(data: data, rounded: false)
    }

    // The 3x render of the full card (QR included) costs seconds — doing it
    // on every click made copy/share feel broken. Render once per window
    // open, serve every action from the cache.
    private static var cachedImage: NSImage?
    private static var cachedPNG: Data?
    /// Which period the cache holds ("current" or the pager's page key).
    /// The pager invalidates on every flip; the key additionally refuses to
    /// serve a stale period even if an invalidate was ever missed — the
    /// same defense the tokenMode invalidation relies on.
    private static var cachedKey: String?

    static func invalidateCache() {
        cachedImage = nil
        cachedPNG = nil
        cachedKey = nil
    }

    /// Pre-render off the click path (fired right after the window shows).
    /// No-arg variants serve the live current week (window-open warm and
    /// the headless snapshot hook).
    static func warmCache() { warmCache(data: .current(), key: "current") }

    static func warmCache(data: WeeklyReportData, key: String) {
        _ = pngData(data: data, key: key)
    }

    static func image() -> NSImage? { image(data: .current(), key: "current") }

    static func image(data: WeeklyReportData, key: String) -> NSImage? {
        if cachedKey == key, let cachedImage { return cachedImage }
        let renderer = ImageRenderer(content: exportView(data: data))
        renderer.scale = 3
        renderer.isOpaque = true
        cachedImage = renderer.nsImage
        cachedPNG = nil
        cachedKey = key
        return cachedImage
    }

    static func pngData() -> Data? { pngData(data: .current(), key: "current") }

    static func pngData(data: WeeklyReportData, key: String) -> Data? {
        if cachedKey == key, let cachedPNG { return cachedPNG }
        guard let image = image(data: data, key: key),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        cachedPNG = rep.representation(using: .png, properties: [:])
        return cachedPNG
    }

    /// Headless snapshot for tooling/screenshots:
    /// AGENTISLAND_REPORT_SNAPSHOT=/path.png renders and exits.
    static func writePNG(to path: String) {
        guard let data = pngData() else {
            NSLog("AgentIsland report: render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// The window IS the card — fully borderless, because on macOS 26 a titled
/// window brings a liquid-glass slab behind the content (the "虚无缥缈的
/// 背景"). The genuine traffic-light close button is mounted manually
/// instead: NSWindow.standardWindowButton(...) gives the real AppKit
/// control (hover ✕ included), placed on the card's top-left corner.
/// Esc also closes; drag anywhere to move.
private final class ReportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class WeeklyReportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WeeklyReportWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // Fresh data per open; the warm render below makes every button
        // instant afterwards.
        WeeklyReportRenderer.invalidateCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            WeeklyReportRenderer.warmCache()
        }
        if window == nil {
            let panel = ReportPanel(
                // Hugs the content exactly (pager row + card 420 + 26pt
                // margins; buttons below) — a window wider than its content
                // reads as a ghost slab around the card.
                contentRect: NSRect(origin: .zero, size: NSSize(width: 472, height: 710)),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false // the card paints its own shadow
            panel.isMovableByWindowBackground = true
            // Screenshot tools (⇧⌘4/5) deactivate the app; panels hide on
            // deactivate by default, which made the card "jump away" the
            // moment the user tried to capture it.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self
            window = panel
        }
        // Rebuilt EVERY show — a cached SwiftUI tree kept serving stale data
        // and the pre-switch language ("English UI, Chinese poster").
        window?.contentView = NSHostingView(rootView: WeeklyReportSheet())
        mountCloseButton()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The REAL red traffic light (hover ✕ and all), mounted onto the card's
    /// top-left like a normal window — without the titled style that drags
    /// the macOS 26 glass slab along. Re-mounted whenever contentView is
    /// replaced (the old button dies with the old view).
    private func mountCloseButton() {
        guard let contentView = window?.contentView,
              let close = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])
        else { return }
        close.target = window
        close.action = #selector(NSWindow.close)
        contentView.addSubview(close)
        // Card sits at (26, 22 + pager row 26 + spacing 14) from the
        // top-left of the content; native windows inset the light ~12pt
        // into the corner. NSHostingView is FLIPPED (y grows downward) —
        // measuring from the bottom edge parked the light at the bottom.
        let inset: CGFloat = 12
        let yFromTop: CGFloat = 22 + 26 + 14 + inset
        let y = contentView.isFlipped
            ? yFromTop
            : contentView.bounds.height - yFromTop - close.frame.height
        close.setFrameOrigin(NSPoint(x: 26 + inset, y: y))
    }
}

@MainActor
private struct WeeklyReportSheet: View {
    // Observing the store keeps the card live: opening the window kicks a
    // rescan, and when it commits the card re-renders on the fresh window
    // instead of freezing whatever snapshot launch restored (the "one model
    // row bigger than the weekly total" screenshots were day-old snapshots).
    @ObservedObject private var cost = CostStore.shared
    @ObservedObject private var tokenMode = TokenCountModeStore.shared
    @State private var copied = false
    @State private var settle = 0
    @State private var coach: String?
    @State private var shareAnchor: NSView?
    // NSSharingServicePicker dies if released while on screen — park it.
    @State private var pickerHolder = PickerHolder()
    // Period pager: 0 = the current week (live store), N = N weeks back
    // (assembled from a full-year rescan). Copy/save/share always export
    // exactly the page on screen.
    @State private var pageOffset = 0
    @State private var pagedData: WeeklyReportData?
    @State private var pageLoading = false
    /// Pick any start date → the card shows that day plus the following six
    /// (owner ask, 2026-08-08). Arrow paging clears the anchor.
    @State private var anchorDate: Date?
    @State private var datePopoverShown = false
    @State private var anchoredData: WeeklyReportData?
    /// The live page, reassembled from ONE anchored interval slice when the
    /// scan anchor trails the wall clock. `current()` mixes two windows —
    /// bars anchored to the freshest scanned day, model rows and dollars to
    /// the store's wall-clock week — and on a machine whose logs stopped
    /// days ago the hero reads rich while the donut sits empty.
    @State private var alignedCurrent: WeeklyReportData?

    private var displayData: WeeklyReportData {
        if let anchoredData { return anchoredData }
        if pageOffset == 0 { return alignedCurrent ?? .current() }
        return pagedData ?? .current()
    }

    private var renderKey: String {
        if let anchorDate {
            return "anchor-\(Int(anchorDate.timeIntervalSince1970))"
        }
        return pageOffset == 0 ? "current" : "week-\(pageOffset)"
    }

    private var canPageBack: Bool {
        guard !pageLoading else { return false }
        return ReportPeriods.hasData(
            before: ReportPeriods.weekInterval(offset: pageOffset),
            earliestDataDay: ReportPeriods.earliestDataDay()
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            pager

            WeeklyReportCard(data: displayData)
                // A tight, grounded shadow — the old radius-34/0.6 halo was
                // the "floating on fog" feel, not any system glass.
                .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                // Cadence D12-4: the card dips once when an action commits.
                // (The 3D tilt was tried and cut — it fought the fixed
                // close button and read as gimmick; owner call 2026-07-18.)
                .modifier(SettlePulse(trigger: settle))

            // Cadence-style action rail: one centered row of icon pills —
            // copy / save / share — each answering with an impact haptic
            // when the action lands (owner spec, 2026-07-18).
            HStack(spacing: 10) {
                actionButton(copied ? L10n.tr("Copied") : L10n.tr("Copy"),
                             icon: copied ? "checkmark" : "square.on.square",
                             prominent: true) {
                    if copyImage() {
                        Haptics.impact()
                        settle += 1
                        copied = true
                        showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                }
                actionButton(L10n.tr("Save"), icon: "arrow.down.to.line", prominent: true) {
                    if savePNG() {
                        Haptics.impact()
                        settle += 1
                        showCoach(L10n.tr("Saved as PNG"))
                    }
                }
                actionButton(L10n.tr("Share…"), icon: "square.and.arrow.up", prominent: true) {
                    showCoach(L10n.tr("Tip: AirDrop it to your iPhone — it lands in Photos, ready to post 📲"))
                    openSharePicker()
                }
                .background(
                    // Invisible AppKit anchor the picker popover attaches
                    // to — keeps the visible control a pixel-identical
                    // SwiftUI pill (a real NSButton never matched).
                    ShareAnchorView { shareAnchor = $0 }
                        .frame(width: 1, height: 1)
                )
            }
            .frame(maxWidth: .infinity)
            // While a past page is still assembling, the card shows the
            // previous period — exporting would ship the wrong week.
            .disabled(pageLoading)
            .opacity(pageLoading ? 0.5 : 1)

            // Fixed one-line slot so the window never reflows.
            Text(coach ?? " ")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
                .lineLimit(1)
                .opacity(coach == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: coach == nil)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .onAppear {
            // A fresh scan self-heals a stale launch snapshot within seconds;
            // the observed store re-renders the card when it commits.
            CostStore.shared.refresh()
            alignCurrentWeek()
        }
        .onReceive(cost.objectWillChange) { _ in
            WeeklyReportRenderer.invalidateCache()
            // Re-warm off the click path once the new values have landed.
            DispatchQueue.main.async {
                WeeklyReportRenderer.warmCache(data: displayData, key: renderKey)
                alignCurrentWeek()
            }
        }
        .onReceive(tokenMode.objectWillChange) { _ in
            WeeklyReportRenderer.invalidateCache()
            DispatchQueue.main.async {
                // A paged card baked its totals with the previous mode —
                // rebuild it (memoized rescan, cheap); the current card
                // recomputes on its own.
                if pageOffset > 0 {
                    loadPage(pageOffset)
                } else {
                    WeeklyReportRenderer.warmCache()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandDemoCommand)) { note in
            // Recording rig: replay the copy interaction on cue.
            if (note.userInfo?["cmd"] as? String) == "report:copy", copyImage() {
                copied = true
                showCoach(L10n.tr("Copied! Post it and bring a friend to the island 🏝️ Thanks for spreading the word"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
        }
    }

    /// ← period label → row above the card. The right edge is the current
    /// week; the left edge is the earliest day with scanned data.
    private var pager: some View {
        HStack(spacing: 10) {
            ReportPagerArrow(systemName: "chevron.left",
                             enabled: canPageBack,
                             accessibilityKey: "Previous week") {
                flip(to: anchorDate == nil ? pageOffset + 1 : 1)
            }
            // Solid white when live — the 0.7 ghost read as disabled next
            // to the arrows (owner, 2026-08-09: 不能用透明的).
            Text(displayData.rangeText)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(pageLoading ? 0.45 : 1))
                .frame(minWidth: 150)
            ReportPagerArrow(systemName: "chevron.right",
                             enabled: (pageOffset > 0 || anchorDate != nil) && !pageLoading,
                             accessibilityKey: "Next week") {
                flip(to: anchorDate == nil ? pageOffset - 1 : 0)
            }
            // Any-date anchor: the window becomes [picked day, +7d).
            // A real month calendar in a popover — click any day and the
            // window becomes [that day, +7d). The field-style picker read
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
        WeeklyReportRenderer.invalidateCache()
        let interval = DateInterval(
            start: start,
            end: cal.date(byAdding: .day, value: 7, to: start) ?? start
        )
        Task {
            let slices = await ReportPeriods.slices(for: interval)
            guard anchorDate == start else { return }
            anchoredData = WeeklyReportData.forInterval(
                interval, claudeSlice: slices.claude, codexSlice: slices.codex
            )
            pageLoading = false
            WeeklyReportRenderer.invalidateCache()
            WeeklyReportRenderer.warmCache(data: displayData, key: renderKey)
        }
    }

    private func flip(to target: Int) {
        // Arrow paging leaves anchored mode and resumes calendar tiling.
        if anchorDate != nil {
            anchorDate = nil
            anchoredData = nil
        }
        guard target >= 0, target != pageOffset || target <= 1 else { return }
        pageOffset = target
        WeeklyReportRenderer.invalidateCache()
        guard target > 0 else {
            pagedData = nil
            pageLoading = false
            DispatchQueue.main.async { WeeklyReportRenderer.warmCache() }
            alignCurrentWeek()
            return
        }
        loadPage(target)
    }

    /// When the scan anchor trails the wall clock, rebuild the live page
    /// from one interval slice so bars, totals, model rows, and dollars all
    /// share that window by construction. On a daily-driven machine the
    /// anchored week IS the wall-clock week and this stays a no-op.
    private func alignCurrentWeek() {
        guard !AppEnvironment.isDemo else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let interval = ReportPeriods.weekInterval(offset: 0)
        guard interval.end <= cal.startOfDay(for: Date()) else {
            alignedCurrent = nil
            return
        }
        Task {
            let slices = await ReportPeriods.slices(for: interval)
            guard pageOffset == 0, anchorDate == nil else { return }
            alignedCurrent = WeeklyReportData.forInterval(interval, slices: slices)
            WeeklyReportRenderer.invalidateCache()
            WeeklyReportRenderer.warmCache(data: displayData, key: renderKey)
        }
    }

    private func loadPage(_ target: Int) {
        pageLoading = true
        let interval = ReportPeriods.weekInterval(offset: target)
        Task {
            let slices = await ReportPeriods.slices(for: interval)
            // The user may have flipped again while the scan ran.
            guard pageOffset == target else { return }
            pagedData = WeeklyReportData.forInterval(
                interval, claudeSlice: slices.claude, codexSlice: slices.codex
            )
            pageLoading = false
            WeeklyReportRenderer.invalidateCache()
            WeeklyReportRenderer.warmCache(data: displayData, key: renderKey)
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
        guard let image = WeeklyReportRenderer.image(data: displayData, key: renderKey),
              let anchor = shareAnchor else { return }
        let picker = NSSharingServicePicker(items: [image])
        pickerHolder.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @discardableResult
    private func copyImage() -> Bool {
        guard let image = WeeklyReportRenderer.image(data: displayData, key: renderKey) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        return true
    }

    private func actionButton(_ title: String, icon: String? = nil,
                              prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(prominent ? .black : .white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
        }
        .buttonStyle(TactileButtonStyle())
    }

    /// Cadence's third rail: write the rendered card straight to disk.
    private func savePNG() -> Bool {
        guard let data = WeeklyReportRenderer.pngData(data: displayData, key: renderKey) else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "agent-island-weekly.png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

/// Zero-size AppKit view used purely as the NSSharingServicePicker anchor.
private struct ShareAnchorView: NSViewRepresentable {
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
private final class PickerHolder {
    var picker: NSSharingServicePicker?
}
