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
        .tmWallpaper()
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
                title: "This week",
                nowLabel: "This week",
                prevHelp: "Previous week",
                nextHelp: "Next week",
                titleMinWidth: 120,
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
        let attr = report.grandTotal
        let un = report.unattributedTotal
        let total = grand + un
        let attrPct = total > 0 ? attr / total * 100 : 0
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
            }
            .padding(22)
            .frame(width: 240, alignment: .leading)
            .glassCard()

            // Attribution
            VStack(alignment: .leading, spacing: 0) {
                Text("ATTRIBUTION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                (Text(hLabel(attr)).foregroundStyle(TM.accent).bold()
                    + Text(" attributed · \(hLabel(un)) to go"))
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 6)

                attributionMeter(report, total: total)
                    .padding(.top, 16)

                HStack(spacing: 16) {
                    legendDot(TM.accent, "\(Int(attrPct.rounded()))% attributed")
                    legendDot(Color.secondary.opacity(0.4), "\(Int((100 - attrPct).rounded()))% unattributed")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

                Spacer(minLength: 14)

                HStack(spacing: 12) {
                    if un > 0 {
                        Button {
                            state.selectedSection = .review
                        } label: {
                            Label("Review unattributed", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Attribute open time to fill the gap")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("All attributed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(TM.positive).font(.system(size: 13, weight: .semibold))
                        Text("Nothing left to review this week ✨")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    @ViewBuilder
    private func attributionMeter(_ report: WeeklyReport, total: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(customerSummaries(report)) { c in
                    Rectangle()
                        .fill(c.color)
                        .frame(width: total > 0 ? geo.size.width * (c.total / total) : 0)
                }
                Rectangle()
                    .fill(hatch)
                    .frame(width: total > 0 ? geo.size.width * (report.unattributedTotal / total) : 0)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    // MARK: - Day bars

    @ViewBuilder
    private func dayBarsPanel(_ report: WeeklyReport) -> some View {
        let summaries = customerSummaries(report)
        let grandPerDay = (0..<7).map { report.dayTotals[$0] + report.unattributedPerDay[$0] }
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
                                        if report.unattributedPerDay[i] > 0 {
                                            Rectangle().fill(hatch)
                                                .frame(height: geo.size.height * (tot / maxDay) * (report.unattributedPerDay[i] / tot))
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
        let summaries = customerSummaries(report)
        let grand = report.grandTotal + report.unattributedTotal

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

            if report.unattributedTotal > 0 {
                unattributedRow(report, grand: grand)
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

    @ViewBuilder
    private func unattributedRow(_ report: WeeklyReport, grand: Double) -> some View {
        let un = report.unattributedTotal
        let share = grand > 0 ? Int((un / grand * 100).rounded()) : 0
        Button {
            state.selectedSection = .review
        } label: {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 4).fill(hatch).frame(width: 13, height: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unattributed").font(.system(size: 14.5, weight: .semibold))
                    Text("Review to fill the gap").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(hLabel(un)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .frame(width: 66, alignment: .trailing)
                Text("\(share)%").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
                Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(TM.accent)
                    .frame(width: 24)
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

    private func customerSummaries(_ report: WeeklyReport) -> [CustomerSummary] {
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
                            idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                            matcher: matcher,
                            sampleIntervalSeconds: sampleInterval
                        )
                    }

                    let report = try computeWeek(weekValue)
                    let prev = try computeWeek(prevWeek)
                    let customers = try database.allCustomers()
                    let projects = try database.allProjects()
                    return ReloadPayload(report: report, lastWeekTotal: prev.grandTotal,
                                         customers: customers, projects: projects)
                }.value
                if Task.isCancelled { return }
                self.report = computed.report
                self.lastWeekTotal = computed.lastWeekTotal
                self.customers = computed.customers
                self.projects = computed.projects
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
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
