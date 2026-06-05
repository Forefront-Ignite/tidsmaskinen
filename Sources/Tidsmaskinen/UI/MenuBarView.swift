import SwiftUI
import AppKit

/// Menu-bar tray popover. Matches the Liquid Glass design: AppMark header, a
/// week glance with the attribution meter + Review button, three shortcuts, and
/// a footer. Microsoft 365 sign-in and the permission prompt live in Settings
/// (reachable via the gear).
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var report: WeeklyReport?
    @State private var customers: [Customer] = []
    /// Review backlog across the current week *and* recent previous weeks, so
    /// the glance never claims "all reviewed" while an older week still has
    /// open items. See `ReviewQueue.rolling`.
    @State private var backlog = ReviewQueue.Rolling()
    @State private var reloadTask: Task<Void, Never>?

    /// How many weeks back the glance scans for residual backlog.
    private let backlogWeeksBack = ReviewQueue.defaultBacklogWeeksBack

    var body: some View {
        VStack(spacing: 12) {
            header
            glanceCard
            shortcutGrid
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { loadGlance() }
        .onChange(of: state.sampleCount) { _, _ in loadGlance() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in loadGlance() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppMark.badge(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tidsmaskinen").font(.system(size: 15, weight: .bold))
                Text("Tracking since \(state.startedAt.formatted(date: .omitted, time: .shortened)) · \(state.sampleCount) samples")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Week glance

    private var glanceCard: some View {
        let grand = report?.grandTotal ?? 0
        let active = report?.activeHours ?? 0
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(oneDecimal(grand))\(Text("h").foregroundStyle(.secondary))")
                    .font(.system(size: 25, weight: .bold))
                Text("tracked this week").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            if active > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("\(oneDecimal(active))h actual")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .help("Distinct working time — parallel work on multiple customers collapsed onto one timeline, each minute counted once.")
            }
            meter
            HStack(spacing: 11) {
                Button { openReview() } label: {
                    Label("Review", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Text(backlogLabel)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var meter: some View {
        // Attributed time only, matching the "tracked this week" total above.
        let total = report?.grandTotal ?? 0
        GeometryReader { geo in
            HStack(spacing: 0) {
                if total > 0, let rows = report?.rows {
                    ForEach(rows) { row in
                        Rectangle()
                            .fill(Color(hex: row.color) ?? .blue)
                            .frame(width: geo.size.width * (row.totalHours / total))
                    }
                }
            }
        }
        .frame(height: 9)
        .clipShape(Capsule())
        .background(Color.secondary.opacity(0.14), in: Capsule())
    }

    // MARK: - Shortcuts

    private var shortcutGrid: some View {
        HStack(spacing: 8) {
            shortcut(.weeklyReport, label: "Report")
            shortcut(.review, label: "Review")
            shortcut(.timeline, label: "My day")
        }
    }

    private func shortcut(_ item: SidebarItem, label: String) -> some View {
        Button { open(item) } label: {
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

    /// "all reviewed" only when the whole window is clean; otherwise break out
    /// how much of the backlog is older than this week so it doesn't surprise
    /// you when you navigate back.
    private var backlogLabel: String {
        if backlog.totalCount == 0 { return "all reviewed" }
        if backlog.earlierCount > 0 && backlog.currentWeekCount > 0 {
            return "\(backlog.currentWeekCount) this week · \(backlog.earlierCount) earlier"
        }
        if backlog.earlierCount > 0 {
            return "\(backlog.earlierCount) in earlier weeks"
        }
        return "\(backlog.totalCount) to review"
    }

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
        let reviewMinMinutes = AppSettings.reviewMinMinutes
        let weeksBack = backlogWeeksBack
        let now = Date()
        reloadTask = Task { @MainActor in
            let result = try? await Task.detached(priority: .utility) { () -> (WeeklyReport, [Customer], ReviewQueue.Rolling) in
                let samples = try db.samples(in: week)
                let rawEvents = try db.calendarEvents(in: week)
                let micSessions = try db.micSessions(in: week)
                let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions)
                let sessions = try db.sessions(in: week)
                let deltas = try db.claudeActiveDeltas(in: week)
                let matcher = try RuleMatcher.load(from: db)
                let report = WeeklyReport.compute(
                    week: week, samples: samples, events: events, sessions: sessions,
                    claudeDeltas: deltas, micSessions: micSessions,
                    idleThresholdSeconds: TimeInterval(idleMinutes * 60),
                    matcher: matcher, sampleIntervalSeconds: sampleInterval)
                let backlog = (try? ReviewQueue.rolling(
                    database: db, now: now, weeksBack: weeksBack,
                    sampleIntervalSeconds: sampleInterval,
                    idleThresholdSeconds: TimeInterval(idleMinutes * 60),
                    minMinutes: reviewMinMinutes)) ?? ReviewQueue.Rolling()
                return (report, try db.allCustomers(), backlog)
            }.value
            if Task.isCancelled { return }
            if let result {
                self.report = result.0
                self.customers = result.1
                self.backlog = result.2
            }
        }
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
