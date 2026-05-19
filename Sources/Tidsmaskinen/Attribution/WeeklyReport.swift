import Foundation

struct WeeklyReport {
    struct Row: Identifiable, Equatable {
        let id: String          // customerID or "__unattributed__"
        let label: String       // customer name or "Unattributed"
        let color: String?
        let perDayHours: [Double]   // 7 entries, Mon..Sun
        var totalHours: Double { perDayHours.reduce(0, +) }
    }

    let week: DateInterval
    let rows: [Row]
    let dayTotals: [Double]      // 7 entries
    var grandTotal: Double { dayTotals.reduce(0, +) }

    static let unattributedID = "__unattributed__"
    static let unattributedLabel = "Unattributed"

    static func compute(week: DateInterval,
                        samples: [ActivitySample],
                        events: [CalendarEvent] = [],
                        sessions: [ClaudeSession] = [],
                        idleThresholdSeconds: TimeInterval = 300,
                        matcher: RuleMatcher,
                        sampleIntervalSeconds: Int) -> WeeklyReport {
        let calendar = Calendar.weekStartingMonday()
        let secondsPerSample = Double(sampleIntervalSeconds)

        // bucket: rowKey -> [day: totalSeconds]; rowKey is "customerID" or "customerID/projectID"
        var perRow: [String: [Double]] = [:]
        var labels: [String: String] = [:]
        var colors: [String: String?] = [:]
        var dayTotals = Array(repeating: 0.0, count: 7)

        func bucket(customer: Customer?, project: Project?, dayIdx: Int, seconds: Double) {
            let id: String
            let label: String
            let color: String?
            if let customer {
                if let project {
                    id = "\(customer.id)/\(project.id)"
                    label = "\(customer.name) · \(project.name)"
                    color = project.color ?? customer.color
                } else {
                    id = customer.id
                    label = customer.name
                    color = customer.color
                }
            } else {
                id = unattributedID
                label = unattributedLabel
                color = nil
            }
            labels[id] = label
            colors[id] = color
            var arr = perRow[id] ?? Array(repeating: 0.0, count: 7)
            arr[dayIdx] += seconds
            perRow[id] = arr
            dayTotals[dayIdx] += seconds
        }

        for sample in samples where !sample.isIdle {
            guard let dayIdx = dayIndex(of: sample.capturedAt, weekStart: week.start, calendar: calendar) else { continue }
            let result = matcher.attribute(sample)
            bucket(customer: result.customer, project: result.project, dayIdx: dayIdx, seconds: secondsPerSample)
        }

        for event in events {
            let attribution = matcher.attribute(event: event)
            // Split duration across days that the event spans.
            for (dayIdx, seconds) in splitEventByDay(event: event, weekStart: week.start, calendar: calendar) {
                bucket(customer: attribution.customer, project: attribution.project, dayIdx: dayIdx, seconds: seconds)
            }
        }

        // Claude sessions — attribute activeSeconds to the session's start day.
        // (v1 limitation: multi-day sessions all bucket on start day. Per-event
        // timestamps would let us split properly; deferred to Phase 6.)
        for session in sessions {
            guard let dayIdx = dayIndex(of: session.startedAt, weekStart: week.start, calendar: calendar) else { continue }
            let active = session.amortizedActiveSeconds(idleThresholdSeconds: idleThresholdSeconds)
            guard active > 0 else { continue }
            let attribution = matcher.attribute(session: session)
            bucket(customer: attribution.customer, project: attribution.project, dayIdx: dayIdx, seconds: active)
        }

        let rows: [Row] = perRow
            .map { (id, secsPerDay) in
                Row(id: id,
                    label: labels[id] ?? id,
                    color: colors[id] ?? nil,
                    perDayHours: secsPerDay.map { $0 / 3600.0 })
            }
            .sorted { lhs, rhs in
                if lhs.id == unattributedID { return false }
                if rhs.id == unattributedID { return true }
                if lhs.label != rhs.label, lhs.totalHours == rhs.totalHours {
                    return lhs.label < rhs.label
                }
                return lhs.totalHours > rhs.totalHours
            }

        return WeeklyReport(
            week: week,
            rows: rows,
            dayTotals: dayTotals.map { $0 / 3600.0 }
        )
    }

    private static func dayIndex(of date: Date, weekStart: Date, calendar: Calendar) -> Int? {
        let comps = calendar.dateComponents([.day], from: weekStart, to: date)
        guard let d = comps.day, d >= 0, d < 7 else { return nil }
        return d
    }

    /// Splits a calendar event into per-day (dayIdx, seconds) buckets inside [weekStart, weekStart+7).
    /// Events crossing midnight (or week boundaries) contribute proportionally to each day they touch.
    private static func splitEventByDay(event: CalendarEvent, weekStart: Date, calendar: Calendar) -> [(Int, Double)] {
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let clippedStart = max(event.startAt, weekStart)
        let clippedEnd = min(event.endAt, weekEnd)
        guard clippedEnd > clippedStart else { return [] }
        var result: [(Int, Double)] = []
        var cursor = clippedStart
        while cursor < clippedEnd {
            guard let dayIdx = dayIndex(of: cursor, weekStart: weekStart, calendar: calendar) else { break }
            let nextDay = calendar.date(byAdding: .day, value: dayIdx + 1, to: weekStart) ?? weekEnd
            let segmentEnd = min(clippedEnd, nextDay)
            let seconds = segmentEnd.timeIntervalSince(cursor)
            if seconds > 0 {
                result.append((dayIdx, seconds))
            }
            cursor = segmentEnd
        }
        return result
    }

    func tsv(weekDays: [Date]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d/M"
        var lines: [String] = []
        let header = ["Customer"] + weekDays.map { formatter.string(from: $0) } + ["Total"]
        lines.append(header.joined(separator: "\t"))
        for row in rows {
            let cells = [row.label]
                + row.perDayHours.map { Self.formatHours($0) }
                + [Self.formatHours(row.totalHours)]
            lines.append(cells.joined(separator: "\t"))
        }
        let totalRow = ["Total"]
            + dayTotals.map { Self.formatHours($0) }
            + [Self.formatHours(grandTotal)]
        lines.append(totalRow.joined(separator: "\t"))
        return lines.joined(separator: "\n")
    }

    static func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 4).rounded() / 4   // nearest 0.25h
        if rounded == 0 { return "" }
        return String(format: "%.2f", rounded)
    }
}

extension Calendar {
    static func weekStartingMonday() -> Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2  // Monday
        cal.timeZone = TimeZone.current
        return cal
    }

    func currentWeekInterval(reference: Date = Date()) -> DateInterval {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
        let start = self.date(from: comps) ?? reference
        let end = self.date(byAdding: .day, value: 7, to: start) ?? reference
        return DateInterval(start: start, end: end)
    }

    func days(in week: DateInterval) -> [Date] {
        (0..<7).compactMap { self.date(byAdding: .day, value: $0, to: week.start) }
    }
}
