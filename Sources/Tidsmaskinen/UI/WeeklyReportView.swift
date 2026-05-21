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
    @State private var loadError: String?
    @State private var copied: Bool = false
    @State private var expandedRowID: String?
    @State private var reloadTask: Task<Void, Never>?

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
                gridTable(report: report)
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

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 14) {
            Button {
                weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.left")
            }
            Text(weekTitle)
                .font(.title3.bold())
                .frame(minWidth: 220, alignment: .leading)
            Button {
                weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.right")
            }
            Button("This week") {
                weekStart = calendar.currentWeekInterval().start
            }
            Spacer()
            if let report {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total: \(WeeklyReport.formatHours(report.grandTotal).ifEmpty("0.00")) h")
                        .foregroundStyle(.secondary)
                    if report.unattributedTotal > 0 {
                        Text("+ \(WeeklyReport.formatHours(report.unattributedTotal)) h unattributed")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    copyTSV(report)
                } label: {
                    Label(copied ? "Copied!" : "Copy as TSV", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var weekTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        let endDate = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let yearF = DateFormatter()
        yearF.dateFormat = "yyyy"
        return "\(f.string(from: weekStart)) – \(f.string(from: endDate)) \(yearF.string(from: weekStart))"
    }

    // Hand-rolled column layout. Conditional `GridRow`s inside `ForEach`
    // inside `Grid` caused hit-test indexing to drift — tapping visual row 2
    // could fire the gesture attached to row 3, and the "Show more" button
    // inside the conditional detail row swallowed clicks. HStacks with fixed
    // column widths give predictable hit testing and a single tap target per
    // row.
    private static let dateColumnWidth: CGFloat = 72
    private static let totalColumnWidth: CGFloat = 76
    private static let cellHPadding: CGFloat = 9
    private static let cellVPadding: CGFloat = 4

    @ViewBuilder
    private func gridTable(report: WeeklyReport) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider().padding(.vertical, 4)

                if report.rows.isEmpty {
                    Text("No activity this week.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Self.cellHPadding)
                        .padding(.vertical, Self.cellVPadding)
                }

                ForEach(report.rows) { row in
                    dataRow(row)
                    if expandedRowID == row.id, let breakdown = report.breakdownsByRowID[row.id] {
                        WeeklyReportRowDetailView(
                            breakdown: breakdown,
                            weekDays: days,
                            rowColor: Color(hex: row.color) ?? .blue
                        )
                        .padding(.bottom, 6)
                    }
                }

                Divider().padding(.vertical, 4)
                totalRow(report: report)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Customer")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.cellHPadding)
                .padding(.vertical, Self.cellVPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                Text(dayHeader(day))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.cellHPadding)
                    .padding(.vertical, Self.cellVPadding)
                    .frame(width: Self.dateColumnWidth, alignment: .trailing)
            }
            Text("Total")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.cellHPadding)
                .padding(.vertical, Self.cellVPadding)
                .frame(width: Self.totalColumnWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func dataRow(_ row: WeeklyReport.Row) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: expandedRowID == row.id ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Circle()
                    .fill(Color(hex: row.color) ?? .blue)
                    .frame(width: 10, height: 10)
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.cellHPadding)
            .padding(.vertical, Self.cellVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(0..<7, id: \.self) { i in
                Text(WeeklyReport.formatHours(row.perDayHours[i]))
                    .monospacedDigit()
                    .foregroundStyle(row.perDayHours[i] == 0 ? Color.secondary : Color.primary)
                    .padding(.horizontal, Self.cellHPadding)
                    .padding(.vertical, Self.cellVPadding)
                    .frame(width: Self.dateColumnWidth, alignment: .trailing)
            }
            Text(WeeklyReport.formatHours(row.totalHours))
                .monospacedDigit()
                .bold()
                .padding(.horizontal, Self.cellHPadding)
                .padding(.vertical, Self.cellVPadding)
                .frame(width: Self.totalColumnWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleExpansion(row.id) }
    }

    @ViewBuilder
    private func totalRow(report: WeeklyReport) -> some View {
        HStack(spacing: 0) {
            Text("Total")
                .bold()
                .padding(.horizontal, Self.cellHPadding)
                .padding(.vertical, Self.cellVPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<7, id: \.self) { i in
                Text(WeeklyReport.formatHours(report.dayTotals[i]))
                    .monospacedDigit()
                    .bold()
                    .padding(.horizontal, Self.cellHPadding)
                    .padding(.vertical, Self.cellVPadding)
                    .frame(width: Self.dateColumnWidth, alignment: .trailing)
            }
            Text(WeeklyReport.formatHours(report.grandTotal))
                .monospacedDigit()
                .bold()
                .padding(.horizontal, Self.cellHPadding)
                .padding(.vertical, Self.cellVPadding)
                .frame(width: Self.totalColumnWidth, alignment: .trailing)
        }
    }

    private func dayHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d/M"
        return f.string(from: date)
    }

    /// Schedule a reload. `immediate` reloads run as soon as possible (week
    /// navigation, calendar sync). Non-immediate reloads are debounced so the
    /// 15s sample-count tick doesn't re-query and re-dedup the entire week
    /// every time a single sample lands.
    private func reload(immediate: Bool) {
        // Snap the displayed week forward if the wall clock rolled into a new
        // week while the window was open AND the user hasn't navigated away
        // from the previously-current week.
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
        let sampleInterval = AppSettings.sampleIntervalSeconds
        let idleThresholdMinutes = AppSettings.claudeIdleThresholdMinutes
        let debounceNs: UInt64 = immediate ? 0 : 1_500_000_000

        reloadTask = Task { @MainActor in
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
                if Task.isCancelled { return }
            }
            do {
                let computed = try await Task.detached(priority: .userInitiated) {
                    let samples = try database.samples(in: weekValue)
                    let events = try database.calendarEvents(in: weekValue)
                    let sessions = try database.sessions(in: weekValue)
                    let claudeDeltas = try database.claudeActiveDeltas(in: weekValue)
                    let matcher = try RuleMatcher.load(from: database)
                    return WeeklyReport.compute(
                        week: weekValue,
                        samples: samples,
                        events: events,
                        sessions: sessions,
                        claudeDeltas: claudeDeltas,
                        idleThresholdSeconds: TimeInterval(idleThresholdMinutes * 60),
                        matcher: matcher,
                        sampleIntervalSeconds: sampleInterval
                    )
                }.value
                if Task.isCancelled { return }
                self.report = computed
                self.loadError = nil
            } catch {
                if Task.isCancelled { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    private func toggleExpansion(_ rowID: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedRowID = expandedRowID == rowID ? nil : rowID
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

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
