import SwiftUI
import AppKit

/// Menu-bar tray popover: the week in one line with a live capture status,
/// banners for anything broken (with a fix), what is being recorded right now
/// and where it lands, a health stripe, and the three destinations. Every
/// status is verified by `CaptureHealth`, never read from a cached grant.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var report: WeeklyReport?
    @State private var loadError: String?
    /// Review backlog across the current week *and* recent previous weeks, so
    /// the glance never claims "all reviewed" while an older week still has
    /// open items. Cached on `AppState`; see `ReviewQueue.rolling`.
    @State private var backlog = ReviewQueue.Rolling()
    @State private var reloadTask: Task<Void, Never>?
    @State private var nowCard: NowCard?

    /// What the sampler is recording right now and where the report puts it.
    struct NowCard: Equatable {
        let title: String
        let app: String
        let since: Date
        let attribution: String?
        let idle: Bool
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            ForEach(alerts, id: \.0) { check, status in
                banner(check: check, status: status)
            }
            if let err = state.lastError {
                bannerRow(tint: .red, systemImage: "xmark.octagon.fill", text: "Capture error: \(err)", action: nil, actionLabel: "")
            }
            if let loadError {
                Text("Unable to refresh: \(loadError)").font(.caption).foregroundStyle(.red)
            }
            nowSection
            healthStripe
            shortcutGrid
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { state.health.probe(); loadGlance() }
        .onDisappear { reloadTask?.cancel() }
        .onChange(of: state.sampleCount) { _, _ in loadGlance() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in loadGlance() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppMark.badge(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tidsmaskinen").font(.system(size: 15, weight: .bold))
                Text(weekLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(captureTint).frame(width: 7, height: 7)
                Text(state.health.captureLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var weekLine: String {
        let week = Calendar.weekStartingMonday().component(.weekOfYear, from: Date())
        guard let report else { return "Week \(week) · loading…" }
        // Earlier weeks' count lives on the Review tile.
        return "Week \(week) · \(oneDecimal(report.grandTotal)) h · \(oneDecimal(backlog.currentWeekSeconds / 3600)) h open"
    }

    private var captureTint: Color {
        state.health.captureLabel == "Capturing" ? TM.positive : .orange
    }

    // MARK: - Banners

    /// Failed checks, plus a stale or failed calendar and missing customers
    /// (which has no badge in the stripe): the things that cost hours if they
    /// go unnoticed.
    private var alerts: [(CaptureHealth.Check, CaptureHealth.Status)] {
        CaptureHealth.Check.allCases.compactMap { check in
            let st = state.health.status(check)
            if st.level == .fail || ((check == .calendar || check == .customers) && st.level == .warn) { return (check, st) }
            return nil
        }
    }

    @ViewBuilder
    private func banner(check: CaptureHealth.Check, status: CaptureHealth.Status) -> some View {
        let failed = status.level == .fail
        bannerRow(tint: failed ? .red : .orange,
                  systemImage: failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                  text: "\(check.label): \(status.detail).",
                  action: { fix(check) },
                  actionLabel: check == .calendar && !state.isSignedIn ? "Sign in" : "Fix")
    }

    private func bannerRow(tint: Color, systemImage: String, text: String,
                           action: (() -> Void)?, actionLabel: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.system(size: 12)).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(actionLabel, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    /// Where each check gets fixed: the Setup pane for anything the app can
    /// walk you through, sign-in for the calendar.
    private func fix(_ check: CaptureHealth.Check) {
        if check == .calendar, !state.isSignedIn {
            open(.settings)
            state.showSignIn = true
            return
        }
        state.settingsTarget = .setup
        open(.settings)
    }

    // MARK: - Now

    @ViewBuilder
    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("NOW").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                if let now = nowCard {
                    Text("· since \(now.since.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if let now = nowCard {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(now.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(now.idle ? "idle" : "\(now.title == now.app ? "" : "\(now.app) ")→ \(now.attribution ?? "unattributed")")
                            .font(.system(size: 11, weight: now.attribution == nil && !now.idle ? .semibold : .regular))
                            .foregroundStyle(now.attribution == nil && !now.idle ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !now.idle {
                        Button(now.attribution == nil ? "Attribute" : "Not this?") { open(.timeline) }
                            .controlSize(.small)
                    }
                }
            } else {
                Text("Nothing being recorded right now").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    // MARK: - Health stripe

    /// Six fixed badges, each carrying its own status colour; two rows so the
    /// labels stay readable at the tray's width.
    private var healthStripe: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach([CaptureHealth.Check.accessibility, .chrome, .microphone, .calendar, .hooks, .menuBar]) { check in
                let st = state.health.status(check)
                Button {
                    state.settingsTarget = .setup
                    open(.settings)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(levelTint(st.level)).frame(width: 6, height: 6)
                        Text(check.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(levelTint(st.level).opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(check.label): \(st.detail)")
                .accessibilityLabel("\(check.label): \(st.detail)")
            }
        }
    }

    private func levelTint(_ level: CaptureHealth.Level) -> Color {
        switch level {
        case .ok:   return TM.positive
        case .off:  return .secondary
        case .warn: return .orange
        case .fail: return .red
        }
    }

    // MARK: - Shortcuts

    private var shortcutGrid: some View {
        HStack(spacing: 8) {
            shortcut(.review, label: backlog.totalCount > 0 ? "Review · \(backlog.totalCount)" : "Review")
            shortcut(.weeklyReport, label: "Report")
            shortcut(.timeline, label: "My day")
        }
    }

    private func shortcut(_ item: SidebarItem, label: String) -> some View {
        Button {
            if item == .review { openReview() } else { open(item) }
        } label: {
            VStack(spacing: 8) {
                if let icon = item.designIcon {
                    DesignIcon(name: icon, size: 20, color: .secondary)
                } else {
                    Image(systemName: item.systemImage).font(.system(size: 18)).foregroundStyle(.secondary)
                }
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            footerIcon("Settings", systemImage: "gearshape.fill") { open(.settings) }
            if hasUpdateFeed {
                footerIcon("Check for Updates", systemImage: "arrow.down.circle") {
                    state.updaterController.checkForUpdates(nil)
                }
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                    Text("Quit").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(.secondary)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 2).padding(.top, 2)
    }

    private func footerIcon(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }

    // MARK: - Helpers

    private var hasUpdateFeed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private func oneDecimal(_ h: Double) -> String { String(format: "%.1f", h) }

    /// Open Review, landing on the oldest week that still has open items so you
    /// clear the tail first instead of starting on a clean current week.
    private func openReview() {
        state.reviewTargetWeekStart = backlog.oldestOpenWeekStart
        open(.review)
    }

    private func open(_ section: SidebarItem) {
        state.selectedSection = section
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadGlance() {
        reloadTask?.cancel()
        let db = state.database
        let cal = Calendar.weekStartingMonday()
        let week = cal.currentWeekInterval()
        let sampleInterval = AppSettings.sampleIntervalSeconds
        let idleMinutes = AppSettings.claudeIdleThresholdMinutes
        let rounding = AppSettings.reportRounding
        reloadTask = Task { @MainActor in
            do {
                let (report, now) = try await Task.detached(priority: .utility) { () -> (WeeklyReport, NowCard?) in
                    let samples = try db.samples(in: week)
                    let rawEvents = try db.calendarEvents(in: week)
                    let micSessions = try db.micSessions(in: week)
                    let matcher = try RuleMatcher.load(from: db)
                    let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions, matcher: matcher)
                    let sessions = try db.sessions(in: week)
                    let deltas = try db.claudeActiveDeltas(in: week)
                    let report = WeeklyReport.compute(
                        week: week, samples: samples, events: events, sessions: sessions,
                        claudeDeltas: deltas, micSessions: micSessions,
                        idleThresholdSeconds: TimeInterval(idleMinutes * 60),
                        matcher: matcher, sampleIntervalSeconds: sampleInterval, rounding: rounding)
                    return (report, Self.nowCard(recent: try db.recentSamples(limit: 120), matcher: matcher))
                }.value
                if Task.isCancelled { return }
                self.report = report
                self.nowCard = now
                // Served from the cache while fresh, so a new sample every
                // 15 s doesn't re-resolve five weeks of history.
                self.backlog = try await state.currentReviewBacklog()
                if Task.isCancelled { return }
                self.loadError = nil
            } catch {
                if Task.isCancelled { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    /// The current foreground stretch: walk back from the newest sample while
    /// the app, site and repo stay the same, so "since" is when it started.
    nonisolated private static func nowCard(recent: [ActivitySample], matcher: RuleMatcher, now: Date = Date()) -> NowCard? {
        let sorted = recent.sorted { $0.capturedAt > $1.capturedAt }
        let maxGap = TimeInterval(AppSettings.sampleIntervalSeconds * 3)   // sleep or a lock leaves no samples
        // A sample older than that is history, not "now".
        guard let latest = sorted.first, now.timeIntervalSince(latest.capturedAt) <= maxGap else { return nil }
        var since = latest.capturedAt
        for s in sorted.dropFirst() {
            guard since.timeIntervalSince(s.capturedAt) <= maxGap,
                  s.appBundleID == latest.appBundleID, s.chromeHost == latest.chromeHost,
                  s.gitRepoPath == latest.gitRepoPath, s.isIdle == latest.isIdle else { break }
            since = s.capturedAt
        }
        let title = latest.gitRemoteURL.flatMap { RuleMatcher.gitSlug(fromRemote: $0) }
            ?? latest.chromeHost
            ?? latest.windowTitle
            ?? latest.appName
            ?? "—"
        let attribution = matcher.attribute(latest)
        let label = attribution.customer.map { c in attribution.project.map { "\(c.name) · \($0.name)" } ?? c.name }
        return NowCard(title: title, app: latest.appName ?? latest.appBundleID ?? "app",
                       since: since, attribution: label, idle: latest.isIdle)
    }
}

// MARK: - Button styles

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileLabel(configuration: configuration)
    }

    private struct TileLabel: View {
        let configuration: TileButtonStyle.Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.12)
                                : (hover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                        )
                )
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: IconButtonStyle.Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.14)
                                : (hover ? Color.primary.opacity(0.09) : Color.clear)
                        )
                )
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}
