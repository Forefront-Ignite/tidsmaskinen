import SwiftUI
import AppKit

struct WeeklyReportView: View {
    @EnvironmentObject private var state: AppState
    @State private var weekStart: Date = Calendar.weekStartingMonday().currentWeekInterval().start
    @State private var report: WeeklyReport?
    @State private var loadError: String?
    @State private var copied: Bool = false

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
        .onAppear { reload() }
        .onChange(of: weekStart) { _, _ in reload() }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
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

    @ViewBuilder
    private func gridTable(report: WeeklyReport) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Customer").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        Text(dayHeader(day))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    Text("Total")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                }
                Divider().gridCellColumns(9)

                if report.rows.isEmpty {
                    GridRow {
                        Text("No activity this week.").foregroundStyle(.secondary)
                    }
                }

                ForEach(report.rows) { row in
                    GridRow {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: row.color) ?? .blue)
                                .frame(width: 10, height: 10)
                            Text(row.label)
                        }
                        ForEach(0..<7, id: \.self) { i in
                            Text(WeeklyReport.formatHours(row.perDayHours[i]))
                                .monospacedDigit()
                                .frame(minWidth: 56, alignment: .trailing)
                                .foregroundStyle(row.perDayHours[i] == 0 ? Color.secondary : Color.primary)
                        }
                        Text(WeeklyReport.formatHours(row.totalHours))
                            .monospacedDigit()
                            .bold()
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                }

                Divider().gridCellColumns(9)
                GridRow {
                    Text("Total").bold()
                    ForEach(0..<7, id: \.self) { i in
                        Text(WeeklyReport.formatHours(report.dayTotals[i]))
                            .monospacedDigit()
                            .bold()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    Text(WeeklyReport.formatHours(report.grandTotal))
                        .monospacedDigit()
                        .bold()
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            .padding()
        }
    }

    private func dayHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d/M"
        return f.string(from: date)
    }

    private func reload() {
        do {
            let samples = try state.database.samples(in: week)
            let events = try state.database.calendarEvents(in: week)
            let sessions = try state.database.sessions(in: week)
            let claudeDeltas = try state.database.claudeActiveDeltas(in: week)
            let matcher = try RuleMatcher.load(from: state.database)
            self.report = WeeklyReport.compute(
                week: week,
                samples: samples,
                events: events,
                sessions: sessions,
                claudeDeltas: claudeDeltas,
                idleThresholdSeconds: TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60),
                matcher: matcher,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds
            )
        } catch {
            loadError = error.localizedDescription
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
