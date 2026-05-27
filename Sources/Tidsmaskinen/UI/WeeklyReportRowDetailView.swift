import SwiftUI

struct WeeklyReportRowDetailView: View {
    let breakdown: WeeklyReport.Breakdown
    let weekDays: [Date]
    let rowColor: Color
    /// Invoked when the user clicks a Meeting contributor row. The weekly
    /// report view opens an `AssignmentSheet` and decides whether to write a
    /// series-level or per-event attribution.
    var onAssignMeetingContributor: ((WeeklyReport.Breakdown.Contributor) -> Void)? = nil
    private let collapsedLimit = 5
    @State private var showAllContributors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceSection
            contributorSection
        }
        .padding(.vertical, 10)
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowColor.opacity(0.06))
        )
    }

    @ViewBuilder
    private var sourceSection: some View {
        let kinds = breakdown.activeSourceKinds
        VStack(alignment: .leading, spacing: 6) {
            Text("By source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if kinds.isEmpty {
                Text("No contributions this week.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 1, height: 0)
                        ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                            Text(dayHeader(day))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        Text("Total")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    ForEach(kinds, id: \.self) { kind in
                        let perDay = breakdown.perDay(kind)
                        let total = perDay.reduce(0, +)
                        GridRow {
                            Label {
                                Text(kind.label)
                                    .font(.caption)
                            } icon: {
                                Image(systemName: kind.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(0..<7, id: \.self) { i in
                                Text(WeeklyReport.formatHours(perDay[i]))
                                    .font(.caption.monospacedDigit())
                                    .frame(minWidth: 56, alignment: .trailing)
                                    .foregroundStyle(perDay[i] == 0 ? Color.tertiary : Color.secondary)
                            }
                            Text(WeeklyReport.formatHours(total))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .frame(minWidth: 60, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contributorSection: some View {
        // Drop entries whose displayed time rounds to zero — they're just
        // noise in the list (a couple of sampled seconds on a stray browser
        // tab) and the user explicitly asked not to see them.
        let visible = breakdown.topContributors.filter {
            WeeklyReport.roundedQuarter($0.hours) > 0
        }
        let shown = showAllContributors ? visible : Array(visible.prefix(collapsedLimit))
        let hiddenCount = visible.count - shown.count

        VStack(alignment: .leading, spacing: 6) {
            Text("Top contributors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if shown.isEmpty {
                Text("Nothing to show.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shown) { c in
                        contributorRow(c)
                    }
                    if visible.count > collapsedLimit {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showAllContributors.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAllContributors ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                Text(showAllContributors
                                     ? "Show less"
                                     : "Show \(hiddenCount) more")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contributorRow(_ c: WeeklyReport.Breakdown.Contributor) -> some View {
        let actionable = c.isMeeting && onAssignMeetingContributor != nil
        HStack(spacing: 8) {
            Image(systemName: c.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(c.label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(c.kindLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
            Text(WeeklyReport.formatHours(c.hours).ifEmpty("0.00"))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 50, alignment: .trailing)
            if actionable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard actionable else { return }
            onAssignMeetingContributor?(c)
        }
        .help(actionable ? "Re-attribute this meeting" : "")
    }

    private func dayHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}

private extension Color {
    static var tertiary: Color { Color.secondary.opacity(0.55) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
