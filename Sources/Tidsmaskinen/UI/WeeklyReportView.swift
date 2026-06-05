import SwiftUI
import AppKit

struct WeeklyReportView: View {
    @EnvironmentObject private var state: AppState
    @State private var weekStart: Date = Calendar.weekStartingMonday().currentWeekInterval().start
    // Tracks which week was "current" the last time we computed the report.
    // If the wall clock rolls into a new week while the window is open AND the
    // user hasn't manually navigated, we snap weekStart forward.
    @State private var lastKnownCurrentWeekStart: Date = Calendar.weekStartingMonday().currentWeekInterval().start
    @State private var report: WeeklyReport?
    @State private var lastWeekTotal: Double = 0
    @State private var loadError: String?
    @State private var copied: Bool = false
    @State private var expandedCustomerID: String?
    @State private var reloadTask: Task<Void, Never>?
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    /// Derived per-customer rollups, recomputed only when the report reloads
    /// (not on every body evaluation).
    @State private var summaries: [CustomerSummary] = []
    /// The review backlog for this week — the actionable items the Review screen
    /// would show. Drives the hero's "things worth reviewing" indicator so it
    /// only nags when there's genuine work (not for ambient app/sub-threshold
    /// time, which is tracked but not reviewable).
    @State private var backlogCount: Int = 0
    @State private var backlogHours: Double = 0

    private let calendar = Calendar.weekStartingMonday()

    private var week: DateInterval {
        DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
    }

    private var days: [Date] {
        calendar.days(in: week)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        heroRow(report)
                        dayBarsPanel(report)
                        customerList(report)
                    }
                    .padding(28)
                }
            } else {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onAppear { reload(immediate: true) }
        .onDisappear { reloadTask?.cancel() }
        .onChange(of: weekStart) { _, _ in reload(immediate: true) }
        .onChange(of: state.sampleCount) { _, _ in reload(immediate: false) }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload(immediate: true) }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly report")
                    .font(.system(size: 24, weight: .bold))
                Text(weekTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if report != nil {
                Button {
                    if let report { copyTSV(report) }
                } label: {
                    Label(copied ? "Copied!" : "Copy as TSV", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            DateNavigator(
                title: weekStart == calendar.currentWeekInterval().start ? "This week" : weekTitle,
                nowLabel: "This week",
                prevHelp: "Previous week",
                nextHelp: "Next week",
                titleMinWidth: 150,
                nowDisabled: weekStart == calendar.currentWeekInterval().start,
                onPrev: { weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart },
                onNext: { weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart },
                onNow: { weekStart = calendar.currentWeekInterval().start }
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var weekTitle: String {
        let endDate = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(DateFormatting.dayMonth.string(from: weekStart)) – \(DateFormatting.dayMonth.string(from: endDate)) \(DateFormatting.year.string(from: weekStart))"
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroRow(_ report: WeeklyReport) -> some View {
        let grand = report.grandTotal
        let delta = grand - lastWeekTotal

        HStack(alignment: .top, spacing: 18) {
            // Tracked this week
            VStack(alignment: .leading, spacing: 8) {
                Text("TRACKED THIS WEEK")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(oneDecimal(grand))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("h").font(.system(size: 22, weight: .bold)).foregroundStyle(.tertiary)
                }
                Label {
                    Text("\(delta >= 0 ? "+" : "")\(oneDecimal(delta))h vs last week")
                } icon: {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(delta >= 0 ? TM.positive : Color.secondary)

                Divider().padding(.vertical, 2)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("\(oneDecimal(report.activeHours))h actual")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                .help("Distinct working time: your parallel work laid on a single timeline — each minute counted once, so it never double-counts time you reported to two customers at once.")
            }
            .padding(22)
            .frame(width: 240, alignment: .leading)
            .glassCard()

            // Review backlog — only flags genuinely actionable items (the same
            // pool the Review screen shows). Ambient app/sub-threshold time is
            // tracked but not a review to-do, so it never appears here.
            VStack(alignment: .leading, spacing: 0) {
                Text("ATTRIBUTION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if backlogCount > 0 {
                    Text("\(Text("\(backlogCount)").foregroundStyle(TM.accent).bold()) \(backlogCount == 1 ? "thing" : "things") worth reviewing · \(hLabel(backlogHours))")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 6)

                    Spacer(minLength: 14)

                    HStack(spacing: 12) {
                        Button {
                            state.selectedSection = .review
                        } label: {
                            Label("Review unattributed", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Attribute open time so it lands in the report")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Everything captured has a home")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 6)

                    Spacer(minLength: 14)

                    Label("All reviewed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(TM.positive).font(.system(size: 13, weight: .semibold))
                    Text("Nothing left to attribute. Your report is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    // MARK: - Day bars

    @ViewBuilder
    private func dayBarsPanel(_ report: WeeklyReport) -> some View {
        let summaries = self.summaries
        // Attributed time only, matching the hero's "tracked this week" total.
        // Ambient, non-attributable app time isn't charted here; open backlog is
        // surfaced as its own row in the customer list instead.
        let grandPerDay = report.dayTotals
        let maxDay = max(grandPerDay.max() ?? 1, 0.0001)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hours by day").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("stacked by customer").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 8)

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    let tot = grandPerDay[i]
                    VStack(spacing: 8) {
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                VStack(spacing: 0) {
                                    if tot > 0 {
                                        ForEach(summaries) { c in
                                            if c.perDay[i] > 0 {
                                                Rectangle().fill(c.color)
                                                    .frame(height: geo.size.height * (tot / maxDay) * (c.perDay[i] / tot))
                                            }
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                        }
                        .frame(maxWidth: 46)
                        Text(DateFormatting.weekdayShort.string(from: day))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(tot > 0 ? oneDecimal(tot) : "–")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 210)
            .padding(.horizontal, 22).padding(.bottom, 16)
        }
        .glassCard()
    }

    // MARK: - Customer list

    @ViewBuilder
    private func customerList(_ report: WeeklyReport) -> some View {
        let summaries = self.summaries
        // Share is computed against attributed time only, so the customer rows
        // sum to ~100%. Open backlog is shown below as its own actionable row
        // (the same pool Review surfaces) rather than diluting every share with
        // ambient, non-attributable app time.
        let grand = report.grandTotal

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                Text("CUSTOMER").frame(maxWidth: .infinity, alignment: .leading)
                Text("THIS WEEK").frame(width: 120, alignment: .leading)
                Text("HOURS").frame(width: 66, alignment: .trailing)
                Text("SHARE").frame(width: 60, alignment: .trailing)
                Spacer().frame(width: 24)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)

            ForEach(summaries) { c in
                customerRow(c, grand: grand)
            }

            if backlogCount > 0 {
                backlogRow()
            }
        }
    }

    @ViewBuilder
    private func customerRow(_ c: CustomerSummary, grand: Double) -> some View {
        let isOpen = expandedCustomerID == c.id
        let share = grand > 0 ? Int((c.total / grand * 100).rounded()) : 0
        let maxDay = max(c.perDay.max() ?? 1, 0.0001)

        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedCustomerID = isOpen ? nil : c.id
                }
            } label: {
                HStack(spacing: 15) {
                    ColorDot(color: c.color, size: 13, square: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 14.5, weight: .semibold))
                        Text("\(c.projects.count) \(c.projects.count == 1 ? "project" : "projects")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // sparkline
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(c.color.opacity(c.perDay[i] > 0 ? 0.92 : 0.18))
                                .frame(width: 7, height: max(3, 30 * (c.perDay[i] / maxDay)))
                        }
                    }
                    .frame(height: 30)
                    Text(hLabel(c.total)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                    Text("\(share)%").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 24)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(c.projects.enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 12) {
                            Text(p.name).font(.system(size: 13)).foregroundStyle(.secondary)
                            GeometryReader { geo in
                                Capsule().fill(c.color)
                                    .frame(width: c.total > 0 ? geo.size.width * (p.hours / c.total) : 0, height: 6)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 6)
                            Text(hLabel(p.hours)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                        .padding(.leading, 46).padding(.trailing, 18).padding(.vertical, 9)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .glassCard(radius: 16)
    }

    /// Open backlog for the week — the *same* actionable pool the Review screen
    /// and the hero surface (via `ReviewQueue`), not the dedup engine's raw
    /// leftover. Keeping the two in lockstep means this row vanishes exactly
    /// when the hero says "all reviewed", instead of contradicting it with
    /// ambient, non-attributable app time.
    @ViewBuilder
    private func backlogRow() -> some View {
        Button {
            state.selectedSection = .review
        } label: {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 4).fill(hatch).frame(width: 13, height: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uncategorized").font(.system(size: 14.5, weight: .semibold))
                    Text("\(backlogCount) \(backlogCount == 1 ? "item" : "items") worth reviewing — attribute so it lands in the report")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(hLabel(backlogHours)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .frame(width: 66, alignment: .trailing)
                Label("Review", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(TM.accent)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.tertiary))
    }

    // MARK: - Derived per-customer summaries

    struct CustomerSummary: Identifiable {
        let id: String          // customerID
        let name: String
        let color: Color
        var perDay: [Double]
        var projects: [(name: String, hours: Double)]
        var total: Double { perDay.reduce(0, +) }
    }

    private func computeCustomerSummaries(_ report: WeeklyReport) -> [CustomerSummary] {
        let customersByID = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var byCustomer: [String: CustomerSummary] = [:]
        var order: [String] = []

        for row in report.rows {
            let parts = row.id.split(separator: "/", maxSplits: 1).map(String.init)
            let cid = parts[0]
            let projectID = parts.count > 1 ? parts[1] : nil
            if byCustomer[cid] == nil {
                let cust = customersByID[cid]
                byCustomer[cid] = CustomerSummary(
                    id: cid,
                    name: cust?.name ?? row.label.components(separatedBy: " · ").first ?? cid,
                    color: Color(hex: cust?.displayColor ?? row.color) ?? .blue,
                    perDay: Array(repeating: 0, count: 7),
                    projects: []
                )
                order.append(cid)
            }
            for d in 0..<7 { byCustomer[cid]!.perDay[d] += row.perDayHours[d] }
            let projName = projectID.flatMap { projectsByID[$0]?.name } ?? "No project"
            byCustomer[cid]!.projects.append((projName, row.totalHours))
        }

        for cid in order {
            byCustomer[cid]!.projects.sort { $0.hours > $1.hours }
        }
        return order.map { byCustomer[$0]! }.sorted { $0.total > $1.total }
    }

    // MARK: - Formatting

    private func oneDecimal(_ h: Double) -> String { String(format: "%.1f", h) }

    /// Compact hours label: trims a trailing ".0" (e.g. "12h", "12.5h").
    private func hLabel(_ h: Double) -> String {
        let r = (h * 10).rounded() / 10
        if r == r.rounded() { return String(format: "%.0fh", r) }
        return String(format: "%.1fh", r)
    }

    private var hatch: Color { Color.secondary.opacity(0.28) }

    // MARK: - Reload

    /// Schedule a reload. `immediate` reloads run as soon as possible (week
    /// navigation, calendar sync). Non-immediate reloads are debounced so the
    /// 15s sample-count tick doesn't re-query and re-dedup the entire week
    /// every time a single sample lands.
    private func reload(immediate: Bool) {
        let currentWeek = calendar.currentWeekInterval().start
        if currentWeek != lastKnownCurrentWeekStart {
            if weekStart == lastKnownCurrentWeekStart {
                weekStart = currentWeek
            }
            lastKnownCurrentWeekStart = currentWeek
        }

        reloadTask?.cancel()
        let database = state.database
        let weekValue = week
        let prevWeek = DateInterval(
            start: calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart,
            end: weekStart
        )
        let sampleInterval = AppSettings.sampleIntervalSeconds
        let idleThresholdMinutes = AppSettings.claudeIdleThresholdMinutes
        let reviewMinMinutes = AppSettings.reviewMinMinutes
        let debounceNs: UInt64 = immediate ? 0 : 1_500_000_000

        reloadTask = Task { @MainActor in
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
                if Task.isCancelled { return }
            }
            do {
                let computed = try await Task.detached(priority: .userInitiated) { () -> ReloadPayload in
                    let matcher = try RuleMatcher.load(from: database)

                    func computeWeek(_ interval: DateInterval) throws -> WeeklyReport {
                        let samples = try database.samples(in: interval)
                        let rawEvents = try database.calendarEvents(in: interval)
                        let micSessions = try database.micSessions(in: interval)
                        let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions)
                        let sessions = try database.sessions(in: interval)
                        let claudeDeltas = try database.claudeActiveDeltas(in: interval)
                        return WeeklyReport.compute(
                            week: interval,
                            samples: samples,
                            events: events,
                            sessions: sessions,
                            claudeDeltas: claudeDeltas,
                            micSessions: micSessions,
                            idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                            matcher: matcher,
                            sampleIntervalSeconds: sampleInterval
                        )
                    }

                    let report = try computeWeek(weekValue)
                    let prev = try computeWeek(prevWeek)
                    let customers = try database.allCustomers()
                    let projects = try database.allProjects()
                    // Actionable review backlog for this week — same pool the
                    // Review screen surfaces, so the hero stays in lockstep.
                    let backlog = (try? ReviewQueue.build(
                        database: database,
                        interval: weekValue,
                        sampleIntervalSeconds: sampleInterval,
                        idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                        minMinutes: reviewMinMinutes
                    )) ?? []
                    return ReloadPayload(report: report, lastWeekTotal: prev.grandTotal,
                                         customers: customers, projects: projects,
                                         backlogCount: backlog.count,
                                         backlogHours: backlog.reduce(0) { $0 + $1.totalSeconds } / 3600.0)
                }.value
                if Task.isCancelled { return }
                self.report = computed.report
                self.lastWeekTotal = computed.lastWeekTotal
                self.customers = computed.customers
                self.projects = computed.projects
                self.backlogCount = computed.backlogCount
                self.backlogHours = computed.backlogHours
                self.summaries = computeCustomerSummaries(computed.report)
                self.loadError = nil
            } catch {
                if Task.isCancelled { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    private func copyTSV(_ report: WeeklyReport) {
        let tsv = report.tsv(weekDays: days)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

private struct ReloadPayload {
    let report: WeeklyReport
    let lastWeekTotal: Double
    let customers: [Customer]
    let projects: [Project]
    let backlogCount: Int
    let backlogHours: Double
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
