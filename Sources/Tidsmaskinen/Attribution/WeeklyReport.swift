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
    let rows: [Row]                    // attributed customer/project rows only
    let dayTotals: [Double]            // 7 entries, attributed only
    let unattributedPerDay: [Double]   // 7 entries — informational, not summed into totals
    var grandTotal: Double { dayTotals.reduce(0, +) }
    var unattributedTotal: Double { unattributedPerDay.reduce(0, +) }

    static let unattributedID = "__unattributed__"
    static let unattributedLabel = "Unattributed"

    static func compute(week: DateInterval,
                        samples: [ActivitySample],
                        events: [CalendarEvent] = [],
                        sessions: [ClaudeSession] = [],
                        claudeDeltas: [AppDatabase.ClaudeActiveDelta] = [],
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

        // Claude sessions: prefer per-event deltas (v10+) so multi-day sessions
        // split correctly. Sessions predating v10 have no deltas and fall back
        // to start-day attribution using the rolled-up activeSeconds.
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var creditedSessionIDs = Set<String>()
        for delta in claudeDeltas {
            guard let session = sessionByID[delta.sessionID] else { continue }
            guard let dayIdx = dayIndex(of: delta.occurredAt, weekStart: week.start, calendar: calendar) else { continue }
            let attribution = matcher.attribute(session: session)
            bucket(customer: attribution.customer, project: attribution.project,
                   dayIdx: dayIdx, seconds: delta.gainedSeconds)
            creditedSessionIDs.insert(session.id)
        }
        for session in sessions where !creditedSessionIDs.contains(session.id) {
            guard let dayIdx = dayIndex(of: session.startedAt, weekStart: week.start, calendar: calendar) else { continue }
            let active = session.amortizedActiveSeconds(idleThresholdSeconds: idleThresholdSeconds)
            guard active > 0 else { continue }
            let attribution = matcher.attribute(session: session)
            bucket(customer: attribution.customer, project: attribution.project, dayIdx: dayIdx, seconds: active)
        }

        let unattributedSeconds = perRow[unattributedID] ?? Array(repeating: 0.0, count: 7)
        let attributedDayTotals = zip(dayTotals, unattributedSeconds).map { $0 - $1 }

        let rows: [Row] = perRow
            .filter { $0.key != unattributedID }
            .map { (id, secsPerDay) in
                Row(id: id,
                    label: labels[id] ?? id,
                    color: colors[id] ?? nil,
                    perDayHours: secsPerDay.map { $0 / 3600.0 })
            }
            .sorted { lhs, rhs in
                if lhs.label != rhs.label, lhs.totalHours == rhs.totalHours {
                    return lhs.label < rhs.label
                }
                return lhs.totalHours > rhs.totalHours
            }

        return WeeklyReport(
            week: week,
            rows: rows,
            dayTotals: attributedDayTotals.map { $0 / 3600.0 },
            unattributedPerDay: unattributedSeconds.map { $0 / 3600.0 }
        )
    }

    private static func dayIndex(of date: Date, weekStart: Date, calendar: Calendar) -> Int? {
        let comps = calendar.dateComponents([.day], from: weekStart, to: date)
        guard let d = comps.day, d >= 0, d < 7 else { return nil }
        return d
    }

    // MARK: - Row drill-down

    struct Breakdown: Equatable {
        enum SourceKind: String, CaseIterable, Hashable {
            case samples
            case events
            case claude

            var label: String {
                switch self {
                case .samples: return "App activity"
                case .events:  return "Calendar"
                case .claude:  return "Claude Code"
                }
            }

            var systemImage: String {
                switch self {
                case .samples: return "app.dashed"
                case .events:  return "calendar"
                case .claude:  return "wand.and.stars"
                }
            }
        }

        struct Contributor: Identifiable, Hashable {
            let id: String
            let label: String
            let kindLabel: String
            let systemImage: String
            let seconds: Double
            var hours: Double { seconds / 3600.0 }
        }

        let rowID: String
        /// Hours per day (Mon..Sun), keyed by source kind. Always 7 entries.
        let perDayBySourceKind: [SourceKind: [Double]]
        /// Top contributors for the week, sorted descending by hours.
        let topContributors: [Contributor]
        /// Sum of all hours in this breakdown (matches the parent row's total within rounding).
        let totalHours: Double

        func perDay(_ kind: SourceKind) -> [Double] {
            perDayBySourceKind[kind] ?? Array(repeating: 0, count: 7)
        }

        var activeSourceKinds: [SourceKind] {
            SourceKind.allCases.filter { (perDayBySourceKind[$0] ?? []).contains(where: { $0 > 0 }) }
        }
    }

    /// Compute the contribution breakdown for a single row, given the same raw inputs
    /// used to produce the parent `WeeklyReport`. Pure function — re-runnable on demand
    /// without touching the database.
    static func breakdown(forRowID rowID: String,
                          week: DateInterval,
                          samples: [ActivitySample],
                          events: [CalendarEvent],
                          sessions: [ClaudeSession],
                          claudeDeltas: [AppDatabase.ClaudeActiveDelta],
                          matcher: RuleMatcher,
                          sampleIntervalSeconds: Int,
                          idleThresholdSeconds: TimeInterval) -> Breakdown {
        let calendar = Calendar.weekStartingMonday()
        let secondsPerSample = Double(sampleIntervalSeconds)

        var perDay: [Breakdown.SourceKind: [Double]] = [
            .samples: Array(repeating: 0, count: 7),
            .events:  Array(repeating: 0, count: 7),
            .claude:  Array(repeating: 0, count: 7),
        ]
        var contributorSeconds: [String: Double] = [:]
        var contributorMeta: [String: (label: String, kindLabel: String, systemImage: String)] = [:]
        var totalSeconds: Double = 0

        func matches(_ result: AttributionResult) -> Bool {
            rowKey(customer: result.customer, project: result.project) == rowID
        }

        func addContributor(id: String, label: String, kindLabel: String, systemImage: String, seconds: Double) {
            contributorSeconds[id, default: 0] += seconds
            if contributorMeta[id] == nil {
                contributorMeta[id] = (label, kindLabel, systemImage)
            }
        }

        // Samples
        for sample in samples where !sample.isIdle {
            let result = matcher.attribute(sample)
            guard matches(result) else { continue }
            guard let dayIdx = dayIndex(of: sample.capturedAt, weekStart: week.start, calendar: calendar) else { continue }
            perDay[.samples]?[dayIdx] += secondsPerSample
            totalSeconds += secondsPerSample
            let c = contributor(forSample: sample, rule: result.matchingRule)
            addContributor(id: c.id, label: c.label, kindLabel: c.kindLabel, systemImage: c.systemImage, seconds: secondsPerSample)
        }

        // Calendar events
        for event in events {
            let result = matcher.attribute(event: event)
            guard matches(result) else { continue }
            let perDayParts = splitEventByDay(event: event, weekStart: week.start, calendar: calendar)
            let eventSeconds = perDayParts.reduce(0.0) { $0 + $1.1 }
            for (dayIdx, secs) in perDayParts {
                perDay[.events]?[dayIdx] += secs
            }
            totalSeconds += eventSeconds
            let c = contributor(forEvent: event)
            addContributor(id: c.id, label: c.label, kindLabel: c.kindLabel, systemImage: c.systemImage, seconds: eventSeconds)
        }

        // Claude sessions: prefer per-event deltas, fall back to start-day attribution.
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var creditedSessionIDs = Set<String>()
        for delta in claudeDeltas {
            guard let session = sessionByID[delta.sessionID] else { continue }
            let result = matcher.attribute(session: session)
            guard matches(result) else { continue }
            guard let dayIdx = dayIndex(of: delta.occurredAt, weekStart: week.start, calendar: calendar) else { continue }
            perDay[.claude]?[dayIdx] += delta.gainedSeconds
            totalSeconds += delta.gainedSeconds
            let c = contributor(forClaudeSession: session)
            addContributor(id: c.id, label: c.label, kindLabel: c.kindLabel, systemImage: c.systemImage, seconds: delta.gainedSeconds)
            creditedSessionIDs.insert(session.id)
        }
        for session in sessions where !creditedSessionIDs.contains(session.id) {
            let result = matcher.attribute(session: session)
            guard matches(result) else { continue }
            guard let dayIdx = dayIndex(of: session.startedAt, weekStart: week.start, calendar: calendar) else { continue }
            let active = session.amortizedActiveSeconds(idleThresholdSeconds: idleThresholdSeconds)
            guard active > 0 else { continue }
            perDay[.claude]?[dayIdx] += active
            totalSeconds += active
            let c = contributor(forClaudeSession: session)
            addContributor(id: c.id, label: c.label, kindLabel: c.kindLabel, systemImage: c.systemImage, seconds: active)
        }

        let perDayHours = perDay.mapValues { $0.map { $0 / 3600.0 } }
        let contributors = contributorSeconds
            .compactMap { (id, secs) -> Breakdown.Contributor? in
                guard let meta = contributorMeta[id] else { return nil }
                return Breakdown.Contributor(
                    id: id,
                    label: meta.label,
                    kindLabel: meta.kindLabel,
                    systemImage: meta.systemImage,
                    seconds: secs
                )
            }
            .sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
                return lhs.label < rhs.label
            }

        return Breakdown(
            rowID: rowID,
            perDayBySourceKind: perDayHours,
            topContributors: contributors,
            totalHours: totalSeconds / 3600.0
        )
    }

    /// Row key shape must mirror `compute()`'s bucketing.
    private static func rowKey(customer: Customer?, project: Project?) -> String {
        guard let customer else { return unattributedID }
        if let project { return "\(customer.id)/\(project.id)" }
        return customer.id
    }

    private static func contributor(forSample sample: ActivitySample,
                                    rule: Rule?) -> (id: String, label: String, kindLabel: String, systemImage: String) {
        // If a rule matched, surface the signal it matched on so the user sees
        // *why* this sample was attributed.
        if let kind = rule?.kind {
            switch kind {
            case .gitRepoSlug, .gitRemoteHost:
                if let remote = sample.gitRemoteURL,
                   let slug = RuleMatcher.gitSlug(fromRemote: remote) {
                    return ("git:\(slug)", slug, "Git repo", "chevron.left.forwardslash.chevron.right")
                }
            case .urlPath, .urlHost:
                if let host = sample.chromeHost {
                    return ("host:\(host)", host, "Browser", "globe")
                }
            case .windowTitle:
                if let title = sample.windowTitle, !title.isEmpty {
                    return ("title:\(title)", title, "Window title", "macwindow")
                }
            case .appBundleID:
                break
            case .emailDomain:
                break
            }
        }
        // Fallback to app metadata — also covers manual overrides (rule == nil).
        let label = sample.appName ?? sample.appBundleID ?? "Unknown app"
        let id = sample.appBundleID ?? label
        return ("app:\(id)", label, "App", "app.fill")
    }

    private static func contributor(forEvent event: CalendarEvent) -> (id: String, label: String, kindLabel: String, systemImage: String) {
        let label = event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? "Untitled meeting" : label
        return ("event:\(display)", display, "Meeting", "calendar")
    }

    private static func contributor(forClaudeSession session: ClaudeSession) -> (id: String, label: String, kindLabel: String, systemImage: String) {
        if let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
            return ("claude:\(slug)", slug, "Claude · repo", "wand.and.stars")
        }
        if let path = session.gitRepoPath {
            let name = (path as NSString).lastPathComponent
            return ("claude:\(path)", name, "Claude · repo", "wand.and.stars")
        }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return ("claude:cwd:\(cwd)", name, "Claude · cwd", "wand.and.stars")
        }
        return ("claude:session:\(session.id)", "Claude session", "Claude", "wand.and.stars")
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
