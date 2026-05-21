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

    // Grid spacing is collapsed into per-cell padding so the visual gap
    // between cells is absorbed into each cell's tap target — the 18pt
    // horizontal gap and 8pt vertical gap were dead zones that swallowed
    // taps and made rows feel unresponsive.
    private static let cellHPadding: CGFloat = 9
    private static let cellVPadding: CGFloat = 4

    @ViewBuilder
    private func gridTable(report: WeeklyReport) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    headerCell { Text("Customer") }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        headerCell(minWidth: 56, trailing: true) { Text(dayHeader(day)) }
                    }
                    headerCell(minWidth: 60, trailing: true) { Text("Total") }
                }
                Divider().gridCellColumns(9).padding(.vertical, 4)

                if report.rows.isEmpty {
                    GridRow {
                        Text("No activity this week.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Self.cellHPadding)
                            .padding(.vertical, Self.cellVPadding)
                    }
                }

                ForEach(report.rows) { row in
                    GridRow {
                        rowCell(rowID: row.id) {
                            HStack(spacing: 6) {
                                Image(systemName: expandedRowID == row.id ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                Circle()
                                    .fill(Color(hex: row.color) ?? .blue)
                                    .frame(width: 10, height: 10)
                                Text(row.label)
                                Spacer(minLength: 0)
                            }
                        }
                        ForEach(0..<7, id: \.self) { i in
                            rowCell(rowID: row.id, minWidth: 56, trailing: true) {
                                Text(WeeklyReport.formatHours(row.perDayHours[i]))
                                    .monospacedDigit()
                                    .foregroundStyle(row.perDayHours[i] == 0 ? Color.secondary : Color.primary)
                            }
                        }
                        rowCell(rowID: row.id, minWidth: 60, trailing: true) {
                            Text(WeeklyReport.formatHours(row.totalHours))
                                .monospacedDigit()
                                .bold()
                        }
                    }
                    if expandedRowID == row.id, let breakdown = report.breakdownsByRowID[row.id] {
                        GridRow {
                            WeeklyReportRowDetailView(
                                breakdown: breakdown,
                                weekDays: days,
                                rowColor: Color(hex: row.color) ?? .blue
                            )
                            .gridCellColumns(9)
                        }
                    }
                }

                Divider().gridCellColumns(9).padding(.vertical, 4)
                GridRow {
                    headerCell { Text("Total").bold().foregroundStyle(.primary) }
                    ForEach(0..<7, id: \.self) { i in
                        headerCell(minWidth: 56, trailing: true) {
                            Text(WeeklyReport.formatHours(report.dayTotals[i]))
                                .monospacedDigit()
                                .bold()
                                .foregroundStyle(.primary)
                        }
                    }
                    headerCell(minWidth: 60, trailing: true) {
                        Text(WeeklyReport.formatHours(report.grandTotal))
                            .monospacedDigit()
                            .bold()
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func headerCell<Content: View>(
        minWidth: CGFloat? = nil,
        trailing: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(minWidth: minWidth, alignment: trailing ? .trailing : .leading)
            .padding(.horizontal, Self.cellHPadding)
            .padding(.vertical, Self.cellVPadding)
    }

    @ViewBuilder
    private func rowCell<Content: View>(
        rowID: String,
        minWidth: CGFloat? = nil,
        trailing: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(minWidth: minWidth, maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .padding(.horizontal, Self.cellHPadding)
            .padding(.vertical, Self.cellVPadding)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpansion(rowID) }
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
