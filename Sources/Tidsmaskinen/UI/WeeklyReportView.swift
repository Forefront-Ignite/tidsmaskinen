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
    /// Derived per-(customer, project) per-day grid rows, recomputed only when
    /// the report reloads (the source for the "Hours by project & day" table).
    @State private var gridGroups: [GridGroup] = []
    /// The review backlog for this week — the actionable items the Review screen
    /// would show. Drives the hero's "things worth reviewing" indicator so it
    /// only nags when there's genuine work (not for ambient app/sub-threshold
    /// time, which is tracked but not reviewable).
    @State private var backlogCount: Int = 0
    @State private var backlogHours: Double = 0
    /// Review's open backlog per day of the week (count, hours) — the day
    /// headers link into Review scoped to that day.
    @State private var openCountPerDay: [Int] = Array(repeating: 0, count: 7)
    @State private var openHoursPerDay: [Double] = Array(repeating: 0, count: 7)
    @State private var reported: ReportedWeek?
    @State private var hasExpandedInitialCustomer = false
    @AppStorage(SettingsKey.reportRounding) private var roundingRaw: String = ReportRounding.nearest.rawValue

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
                        // A failed refresh keeps the last good report on screen
                        // but must say so — the numbers may be stale.
                        if loadError != nil { loadErrorBanner }
                        calendarBanner
                        heroRow(report)
                        projectGridPanel(report)
                    }
                    .padding(28)
                }
            } else if loadError != nil {
                Spacer()
                loadErrorBanner.frame(maxWidth: 520).frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onAppear { reload(immediate: true) }
        .onDisappear { reloadTask?.cancel() }
        .onChange(of: weekStart) { _, _ in reload(immediate: true) }
        .onChange(of: roundingRaw) { _, _ in reload(immediate: true) }
        .onChange(of: state.sampleCount) { _, _ in reload(immediate: false) }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload(immediate: true) }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in reload(immediate: true) }
    }

    /// Load failure with a retry; without it a failed load was an endless spinner.
    private var loadErrorBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't load the report").font(.system(size: 14, weight: .semibold))
                Text(loadError ?? "").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Retry") { reload(immediate: true) }
        }
        .padding(14)
        .glassCard(radius: 14)
    }

    /// Hands Review the week on screen, so "Review unattributed" lands on the
    /// week whose number the user is looking at rather than Review's own default.
    private func openReviewForThisWeek() {
        state.reviewTargetWeekStart = weekStart
        state.selectedSection = .review
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week \(weekNumber)")
                    .font(.system(size: 24, weight: .bold))
                Text(weekSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Round", selection: $roundingRaw) {
                ForEach(ReportRounding.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .fixedSize()
            .help("How each cell rounds to a quarter hour. Day totals always keep their true sum.")
            if report != nil {
                reportedButton
                Button {
                    if let report { copyTSV(report) }
                } label: {
                    Label(copied ? "Copied!" : "Copy for Forefront", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the grid as TSV (⇧⌘C)")
            }
            DateNavigator(
                title: isCurrentWeek ? "This week" : weekTitle,
                nowLabel: "This week",
                prevHelp: "Previous week (⌘←)",
                nextHelp: "Next week (⌘→)",
                titleMinWidth: 150,
                nextDisabled: weekStart >= calendar.currentWeekInterval().start,
                nowDisabled: isCurrentWeek,
                prevShortcut: KeyboardShortcut(.leftArrow, modifiers: .command),
                nextShortcut: KeyboardShortcut(.rightArrow, modifiers: .command),
                onPrev: { weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart },
                onNext: { weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart },
                onNow: { weekStart = calendar.currentWeekInterval().start }
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var isCurrentWeek: Bool { weekStart == calendar.currentWeekInterval().start }
    private var weekNumber: Int { calendar.component(.weekOfYear, from: weekStart) }
    private var rounding: ReportRounding { ReportRounding(rawValue: roundingRaw) ?? .nearest }

    private var weekTitle: String {
        let endDate = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(DateFormatting.dayMonth.string(from: weekStart)) – \(DateFormatting.dayMonth.string(from: endDate)) \(DateFormatting.year.string(from: weekStart))"
    }

    /// "Mon 14 Sep – Sun 20 Sep 2026 · through today" for the running week.
    private var weekSubtitle: String {
        let endDate = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let range = "\(DateFormatting.weekdayDayShortMonth.string(from: weekStart)) – \(DateFormatting.weekdayDayShortMonth.string(from: endDate)) \(DateFormatting.year.string(from: weekStart))"
        return isCurrentWeek ? range + " · through today" : range
    }

    /// Remember the week's total so a later sync that changes it is flagged
    /// instead of silently rewriting a figure already filed.
    @ViewBuilder
    private var reportedButton: some View {
        if let reported {
            Button {
                run { try state.database.clearReported(weekStart: weekStart) }
            } label: {
                Label("Reported", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.bordered).tint(TM.positive)
            .help("Reported \(hLabel(reported.totalHours)) on \(reported.reportedAt.formatted(date: .abbreviated, time: .shortened)). Click to unmark.")
        } else {
            Button("Mark reported") {
                if let report { run { try state.database.markReported(weekStart: weekStart, totalHours: report.grandTotal) } }
            }
            .buttonStyle(.bordered)
            .help("Remember this week's total, so a later sync that changes it is flagged here.")
        }
    }

    /// A stale or signed-out calendar silently drops meetings from the grid.
    @ViewBuilder
    private var calendarBanner: some View {
        let st = state.health.status(.calendar)
        if st.level == .warn || st.level == .fail {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Calendar: \(st.detail). Meetings may be missing from this week.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if st.level == .fail {
                    Button("Sign in") { state.showSignIn = true }.controlSize(.small)
                } else {
                    Button("Sync now") { Task { await state.calendarSync.syncNow(); state.health.probe() } }.controlSize(.small)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroRow(_ report: WeeklyReport) -> some View {
        let grand = report.grandTotal
        // The same open figure the grid sums, so the two never disagree.
        let open = openHoursPerDay.reduce(0, +)
        let tracked = grand + open
        let share = tracked > 0 ? Int((grand / tracked * 100).rounded()) : 100

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isCurrentWeek ? "TRACKED THIS WEEK" : "TRACKED")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(gridNum(tracked))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("h").font(.system(size: 22, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text("\(oneDecimal(report.activeHours)) h at the keyboard · \(oneDecimal(max(0, grand - report.activeHours))) h in parallel")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    .help("Keyboard time counts every minute once. Parallel time is meetings and work reported to two customers in the same minute, so the tracked total can exceed the clock.")
                Text("Same point last week: \(oneDecimal(lastWeekTotal)) h")
                    .font(.caption).foregroundStyle(.secondary)
                if let reported { reportedStatus(reported, current: grand) }
            }
            .padding(22)
            .frame(width: 270, alignment: .leading)
            .glassCard()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Attributed").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(gridNum(grand)) h · \(share)%").font(.system(size: 15, weight: .bold)).monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(TM.accent).frame(width: geo.size.width * (tracked > 0 ? grand / tracked : 1))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    if backlogCount > 0 {
                        Text("\(gridNum(open)) h open · \(backlogCount) item\(backlogCount == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                        Button {
                            openReviewForThisWeek()
                        } label: {
                            Label("Review week \(weekNumber)", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Label("All reviewed — nothing left to attribute", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(TM.positive).font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                }
                Text("\(rounding.label); day totals keep their true sum. Hover a cell for its raw value.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private func reportedStatus(_ r: ReportedWeek, current: Double) -> some View {
        let changed = abs(current - r.totalHours) >= 0.01
        let when = r.reportedAt.formatted(date: .abbreviated, time: .shortened)
        return Label(changed ? "Reported \(hLabel(r.totalHours)) on \(when) — now \(hLabel(current))"
                             : "Reported \(hLabel(r.totalHours)) on \(when)",
                     systemImage: changed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
            .font(.caption).foregroundStyle(changed ? Color.orange : TM.positive)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Hours by customer, project & day

    /// The one table: collapsible customer rows with their projects, one
    /// column per weekday (with that day's open backlog linking into Review),
    /// then Attributed, Unattributed → Review and Tracked. Its on-screen twin
    /// is the TSV that "Copy for Forefront" produces.
    @ViewBuilder
    private func projectGridPanel(_ report: WeeklyReport) -> some View {
        let groups = self.gridGroups
        let dayWidth: CGFloat = 56
        let totalWidth: CGFloat = 60
        // The grid's own open figure is the sum of its day cells, so rows and
        // columns agree (the hero's figure comes from the week-wide backlog).
        let open = openHoursPerDay.reduce(0, +)

        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty && backlogCount == 0 {
                Text("Nothing tracked this week yet.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(22)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        Text("CUSTOMER · PROJECT")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridColumnAlignment(.leading)
                        ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                            VStack(spacing: 2) {
                                Text(DateFormatting.weekdayShort.string(from: day))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(dayNumber(day))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                if openHoursPerDay[i] > 0 {
                                    Button {
                                        state.reviewTargetDay = day
                                        state.selectedSection = .review
                                    } label: {
                                        Text("\(gridNum(openHoursPerDay[i])) open")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(TM.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(openCountPerDay[i]) open item\(openCountPerDay[i] == 1 ? "" : "s") — open Review on this day")
                                }
                            }
                            .frame(width: dayWidth)
                            .gridColumnAlignment(.center)
                        }
                        Text("TOTAL")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: totalWidth, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                    }
                    .padding(.bottom, 8)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(groups) { g in
                        let isOpen = expandedCustomerID == g.id
                        GridRow {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { expandedCustomerID = isOpen ? nil : g.id }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                                    ColorDot(color: g.color, size: 11, square: true)
                                    Text(g.name).font(.system(size: 13.5, weight: .semibold))
                                    Text("\(g.projects.count) project\(g.projects.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .gridColumnAlignment(.leading)
                            .accessibilityLabel("\(g.name), \(gridNum(g.total)) hours, \(isOpen ? "expanded" : "collapsed")")
                            ForEach(Array(g.perDay.enumerated()), id: \.offset) { i, h in
                                dayCell(h, raw: nil, day: days[i], width: dayWidth, weight: .semibold)
                            }
                            Text(gridNum(g.total))
                                .font(.system(size: 13, weight: .bold)).monospacedDigit()
                                .frame(width: totalWidth, alignment: .trailing)
                        }
                        .padding(.top, 10).padding(.bottom, 3)
                        .help(contributorsHelp(for: g, in: report))

                        if isOpen {
                            ForEach(g.projects) { p in
                                GridRow {
                                    Text(p.name)
                                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 26)
                                    ForEach(Array(p.perDay.enumerated()), id: \.offset) { i, h in
                                        dayCell(h, raw: p.rawPerDay.indices.contains(i) ? p.rawPerDay[i] : nil,
                                                day: days[i], width: dayWidth, weight: .regular)
                                    }
                                    Text(gridNum(p.total))
                                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                        .frame(width: totalWidth, alignment: .trailing)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }

                    Divider().gridCellUnsizedAxes(.horizontal).padding(.top, 9)

                    summaryRow("Attributed", report.dayTotals, total: report.grandTotal, weight: .bold, width: dayWidth, totalWidth: totalWidth)

                    if backlogCount > 0 {
                        GridRow {
                            Button { openReviewForThisWeek() } label: {
                                HStack(spacing: 6) {
                                    Text("Unattributed").font(.system(size: 13, weight: .semibold)).foregroundStyle(TM.accent)
                                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(TM.accent)
                                    Text("Review").font(.system(size: 13, weight: .semibold)).foregroundStyle(TM.accent)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .gridColumnAlignment(.leading)
                            ForEach(Array(openHoursPerDay.enumerated()), id: \.offset) { i, h in
                                Text(h > 0 ? gridNum(h) : "·")
                                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(h > 0 ? TM.accent : Color(.quaternaryLabelColor))
                                    .frame(width: dayWidth, alignment: .trailing)
                            }
                            Text(gridNum(open))
                                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(TM.accent)
                                .frame(width: totalWidth, alignment: .trailing)
                        }
                        .padding(.top, 8)
                    }

                    summaryRow("Tracked", zip(report.dayTotals, openHoursPerDay).map(+), total: report.grandTotal + open,
                               weight: .heavy, width: dayWidth, totalWidth: totalWidth)
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)

                Text("Click a cell to open that day in My day. Hover a customer for what contributed. Hover a cell for its raw value.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 16)
            }
        }
        .glassCard()
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ perDay: [Double], total: Double, weight: Font.Weight,
                            width: CGFloat, totalWidth: CGFloat) -> some View {
        GridRow {
            Text(label).font(.system(size: 13, weight: weight))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(perDay.enumerated()), id: \.offset) { _, h in
                Text(h > 0 ? gridNum(h) : "·")
                    .font(.system(size: 12.5, weight: weight))
                    .foregroundStyle(h > 0 ? Color.primary : Color(.quaternaryLabelColor))
                    .monospacedDigit()
                    .frame(width: width, alignment: .trailing)
            }
            Text(gridNum(total))
                .font(.system(size: 13, weight: weight)).monospacedDigit()
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    /// A cell: click opens that day in My day; hover shows the raw value.
    private func dayCell(_ h: Double, raw: Double?, day: Date, width: CGFloat, weight: Font.Weight) -> some View {
        Button {
            state.timelineTargetDay = day
            state.selectedSection = .timeline
        } label: {
            Group {
                if h > 0 {
                    Text(gridNum(h)).font(.system(size: 12.5, weight: weight)).monospacedDigit()
                } else {
                    Text("·").font(.system(size: 12.5)).foregroundStyle(Color(.quaternaryLabelColor))
                }
            }
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(raw.map { String(format: "%.2f h before rounding — click to open this day in My day", $0) }
              ?? "Open this day in My day")
    }

    private func dayNumber(_ day: Date) -> String {
        String(calendar.component(.day, from: day))
    }

    /// What made up a customer's week: the top contributors across its rows.
    private func contributorsHelp(for g: GridGroup, in report: WeeklyReport) -> String {
        var seconds: [String: Double] = [:]
        for p in g.projects {
            for c in report.breakdownsByRowID[p.id]?.topContributors ?? [] {
                seconds[c.label, default: 0] += c.seconds
            }
        }
        let top = seconds.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key) \(hLabel($0.value / 3600))" }
        return top.isEmpty ? g.name : "\(g.name): " + top.joined(separator: " · ")
    }

    // MARK: - Derived per-(customer, project) grid

    struct GridProject: Identifiable {
        let id: String          // the report row id (customerID or customerID/projectID)
        let name: String
        let perDay: [Double]    // 7 entries, Mon..Sun, rounded
        let rawPerDay: [Double] // the same before rounding, for hover
        var total: Double { perDay.reduce(0, +) }
    }

    struct GridGroup: Identifiable {
        let id: String          // customerID
        let name: String
        let color: Color
        var perDay: [Double]    // 7 entries, customer subtotal
        var projects: [GridProject]
        var total: Double { perDay.reduce(0, +) }
    }

    /// Group the report's `(customer, project)` rows by customer, preserving each
    /// row's per-day hours so the grid can show a project's daily breakdown.
    /// Mirrors `computeCustomerSummaries`' grouping but keeps the day dimension.
    private func computeGridGroups(_ report: WeeklyReport) -> [GridGroup] {
        let customersByID = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var perDay: [String: [Double]] = [:]
        var projectsByCustomer: [String: [GridProject]] = [:]
        var name: [String: String] = [:]
        var color: [String: Color] = [:]
        var order: [String] = []

        for row in report.rows {
            let parts = row.id.split(separator: "/", maxSplits: 1).map(String.init)
            let cid = parts[0]
            let projectID = parts.count > 1 ? parts[1] : nil
            if perDay[cid] == nil {
                let cust = customersByID[cid]
                name[cid] = cust?.name ?? row.label.components(separatedBy: " · ").first ?? cid
                color[cid] = Color(hex: cust?.displayColor ?? row.color) ?? .blue
                perDay[cid] = Array(repeating: 0, count: 7)
                projectsByCustomer[cid] = []
                order.append(cid)
            }
            for d in 0..<7 { perDay[cid]![d] += row.perDayHours[d] }
            // The report labels rows "Customer · Project" from every project it
            // knows, archived ones included, so a retired project keeps its name.
            let labelledProject = row.label.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            let projName = projectID.flatMap { projectsByID[$0]?.name }
                ?? (labelledProject.isEmpty ? "No project" : labelledProject)
            projectsByCustomer[cid]!.append(GridProject(id: row.id, name: projName, perDay: row.perDayHours, rawPerDay: row.rawPerDayHours))
        }

        return order.map { cid in
            GridGroup(
                id: cid,
                name: name[cid] ?? cid,
                color: color[cid] ?? .blue,
                perDay: perDay[cid] ?? Array(repeating: 0, count: 7),
                projects: (projectsByCustomer[cid] ?? []).sorted { $0.total > $1.total }
            )
        }
        .sorted { $0.total > $1.total }
    }

    // MARK: - Formatting

    private func oneDecimal(_ h: Double) -> String { String(format: "%.1f", h) }

    /// Compact bare number for grid cells/totals: "2", "1.5", "2.25". Values are
    /// already quarter-rounded upstream (`WeeklyReport.roundedQuarter`), so this
    /// only trims trailing zeros — no "h" suffix, unlike `hLabel`.
    private func gridNum(_ h: Double) -> String {
        let r = (h * 4).rounded() / 4
        if r <= 0 { return "0" }
        var s = String(format: "%.2f", r)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    /// Compact hours label: trims a trailing ".0" (e.g. "12h", "12.5h").
    private func hLabel(_ h: Double) -> String {
        let r = (h * 10).rounded() / 10
        if r == r.rounded() { return String(format: "%.0fh", r) }
        return String(format: "%.1fh", r)
    }

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
        let rounding = self.rounding
        let weekDays = self.days
        // Like-for-like: on the running week compare last week through the
        // same weekday, not a full week against a partial one.
        let todayIndex = isCurrentWeek ? min(6, max(0, calendar.dateComponents([.day], from: weekStart, to: Date()).day ?? 6)) : 6
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
                        let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions, matcher: matcher)
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
                            sampleIntervalSeconds: sampleInterval,
                            rounding: rounding
                        )
                    }

                    let report = try computeWeek(weekValue)
                    let prev = try computeWeek(prevWeek)
                    let customers = try database.allCustomersIncludingArchived()   // retired projects keep their names
                    let projects = try database.allProjectsIncludingArchived()
                    // Actionable review backlog for this week — same pool the
                    // Review screen surfaces, so the hero stays in lockstep.
                    let backlog = try ReviewQueue.build(
                        database: database,
                        interval: weekValue,
                        sampleIntervalSeconds: sampleInterval,
                        idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                        minMinutes: reviewMinMinutes
                    )
                    var openCount = Array(repeating: 0, count: 7)
                    var openHours = Array(repeating: 0.0, count: 7)
                    for (i, day) in weekDays.enumerated() {
                        let dayInterval = DateInterval(start: day, end: Calendar.weekStartingMonday().date(byAdding: .day, value: 1, to: day) ?? day)
                        let units = try ReviewQueue.build(
                            database: database, interval: dayInterval,
                            sampleIntervalSeconds: sampleInterval,
                            idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                            minMinutes: reviewMinMinutes)
                        openCount[i] = units.count
                        openHours[i] = rounding.round(units.reduce(0) { $0 + $1.totalSeconds } / 3600.0)
                    }
                    return ReloadPayload(report: report,
                                         lastWeekTotal: prev.dayTotals.prefix(todayIndex + 1).reduce(0, +),
                                         customers: customers, projects: projects,
                                         backlogCount: backlog.count,
                                         backlogHours: backlog.reduce(0) { $0 + $1.totalSeconds } / 3600.0,
                                         openCountPerDay: openCount, openHoursPerDay: openHours,
                                         reported: try database.reportedWeek(start: weekValue.start))
                }.value
                if Task.isCancelled { return }
                self.report = computed.report
                self.lastWeekTotal = computed.lastWeekTotal
                self.customers = computed.customers
                self.projects = computed.projects
                self.backlogCount = computed.backlogCount
                self.backlogHours = computed.backlogHours
                self.openCountPerDay = computed.openCountPerDay
                self.openHoursPerDay = computed.openHoursPerDay
                self.reported = computed.reported
                self.gridGroups = computeGridGroups(computed.report)
                // Open the largest customer once; after that a collapse sticks.
                if let first = gridGroups.first,
                   !hasExpandedInitialCustomer || expandedCustomerID.map({ id in !gridGroups.contains { $0.id == id } }) == true {
                    expandedCustomerID = first.id
                    hasExpandedInitialCustomer = true
                }
                self.loadError = nil
            } catch {
                if Task.isCancelled { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Run a small write, then refresh; errors show in the banner.
    private func run(_ body: () throws -> Void) {
        do { try body(); reload(immediate: true) } catch { loadError = error.localizedDescription }
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
    let openCountPerDay: [Int]
    let openHoursPerDay: [Double]
    let reported: ReportedWeek?
}
