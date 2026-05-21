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
        var engine = DedupEngine(week: week)
        let records = collectRecords(
            week: week,
            samples: samples,
            events: events,
            sessions: sessions,
            claudeDeltas: claudeDeltas,
            matcher: matcher,
            sampleIntervalSeconds: sampleIntervalSeconds,
            idleThresholdSeconds: idleThresholdSeconds
        )
        for record in records.sorted(by: byPriority) {
            engine.add(record)
        }

        var rows: [Row] = []
        var dayTotalSeconds = Array(repeating: 0.0, count: 7)
        var unattributedSeconds = Array(repeating: 0.0, count: 7)

        for (bucketID, bySource) in engine.perBucketPerSource {
            var seconds = Array(repeating: 0.0, count: 7)
            for (_, arr) in bySource {
                for d in 0..<7 { seconds[d] += arr[d] }
            }
            if bucketID == unattributedID {
                unattributedSeconds = seconds
                continue
            }
            let (label, color) = labelAndColor(forBucketID: bucketID, matcher: matcher)
            rows.append(Row(
                id: bucketID,
                label: label,
                color: color,
                perDayHours: seconds.map { $0 / 3600.0 }
            ))
            for d in 0..<7 { dayTotalSeconds[d] += seconds[d] }
        }

        rows.sort { lhs, rhs in
            if lhs.totalHours == rhs.totalHours { return lhs.label < rhs.label }
            return lhs.totalHours > rhs.totalHours
        }

        return WeeklyReport(
            week: week,
            rows: rows,
            dayTotals: dayTotalSeconds.map { $0 / 3600.0 },
            unattributedPerDay: unattributedSeconds.map { $0 / 3600.0 }
        )
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
        /// Top contributors for the week, sorted descending by hours. Each
        /// contributor's seconds reflect only the time uniquely credited to it
        /// after cross-source dedup.
        let topContributors: [Contributor]
        /// Sum of all hours in this breakdown (matches the parent row's total).
        let totalHours: Double

        func perDay(_ kind: SourceKind) -> [Double] {
            perDayBySourceKind[kind] ?? Array(repeating: 0, count: 7)
        }

        var activeSourceKinds: [SourceKind] {
            SourceKind.allCases.filter { (perDayBySourceKind[$0] ?? []).contains(where: { $0 > 0 }) }
        }
    }

    /// Compute the contribution breakdown for a single row using the same
    /// per-bucket, priority-ordered interval dedup as `compute()`. Pure
    /// function — re-runnable on demand without touching the database.
    static func breakdown(forRowID rowID: String,
                          week: DateInterval,
                          samples: [ActivitySample],
                          events: [CalendarEvent],
                          sessions: [ClaudeSession],
                          claudeDeltas: [AppDatabase.ClaudeActiveDelta],
                          matcher: RuleMatcher,
                          sampleIntervalSeconds: Int,
                          idleThresholdSeconds: TimeInterval) -> Breakdown {
        var engine = DedupEngine(week: week)
        let records = collectRecords(
            week: week,
            samples: samples,
            events: events,
            sessions: sessions,
            claudeDeltas: claudeDeltas,
            matcher: matcher,
            sampleIntervalSeconds: sampleIntervalSeconds,
            idleThresholdSeconds: idleThresholdSeconds
        )
        for record in records.sorted(by: byPriority) {
            engine.add(record)
        }

        let bySource = engine.perBucketPerSource[rowID] ?? [:]
        var perDayHours: [Breakdown.SourceKind: [Double]] = [:]
        for kind in Breakdown.SourceKind.allCases {
            let secs = bySource[kind] ?? Array(repeating: 0.0, count: 7)
            perDayHours[kind] = secs.map { $0 / 3600.0 }
        }

        let contribSeconds = engine.perBucketContribSeconds[rowID] ?? [:]
        let contribInfos = engine.perBucketContribInfo[rowID] ?? [:]
        let contributors: [Breakdown.Contributor] = contribSeconds.compactMap { (id, secs) -> Breakdown.Contributor? in
            guard let info = contribInfos[id], secs > 0 else { return nil }
            return Breakdown.Contributor(
                id: id,
                label: info.label,
                kindLabel: info.kindLabel,
                systemImage: info.systemImage,
                seconds: secs
            )
        }
        .sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            return lhs.label < rhs.label
        }

        let totalSeconds = bySource.reduce(0.0) { sum, kv in
            sum + kv.value.reduce(0, +)
        }

        return Breakdown(
            rowID: rowID,
            perDayBySourceKind: perDayHours,
            topContributors: contributors,
            totalHours: totalSeconds / 3600.0
        )
    }

    // MARK: - Aggregation engine

    /// One attributable slice of time. The dedup engine treats each record as
    /// `[start, end)` and credits the effective (non-overlapping) intersection
    /// to the record's bucket and source.
    private struct AttributedRecord {
        let bucketID: String
        let source: Breakdown.SourceKind
        let start: Date
        let end: Date
        let contributor: ContributorInfo?
    }

    private struct ContributorInfo {
        let id: String
        let label: String
        let kindLabel: String
        let systemImage: String
    }

    /// Priority order when overlapping sources cover the same second of wall
    /// time for the same bucket: calendar events outrank Claude sessions
    /// outrank app activity samples. Each second can only credit one source,
    /// so the per-bucket total never exceeds elapsed wall time.
    private static func byPriority(_ a: AttributedRecord, _ b: AttributedRecord) -> Bool {
        priorityIndex(a.source) < priorityIndex(b.source)
    }

    private static func priorityIndex(_ kind: Breakdown.SourceKind) -> Int {
        switch kind {
        case .events:  return 0
        case .claude:  return 1
        case .samples: return 2
        }
    }

    /// Walks raw inputs and turns each into a time-bounded `AttributedRecord`.
    private static func collectRecords(week: DateInterval,
                                        samples: [ActivitySample],
                                        events: [CalendarEvent],
                                        sessions: [ClaudeSession],
                                        claudeDeltas: [AppDatabase.ClaudeActiveDelta],
                                        matcher: RuleMatcher,
                                        sampleIntervalSeconds: Int,
                                        idleThresholdSeconds: TimeInterval) -> [AttributedRecord] {
        let secondsPerSample = TimeInterval(sampleIntervalSeconds)
        var records: [AttributedRecord] = []
        records.reserveCapacity(samples.count + events.count + claudeDeltas.count + sessions.count)

        for sample in samples where !sample.isIdle {
            let result = matcher.attribute(sample)
            records.append(AttributedRecord(
                bucketID: rowKey(customer: result.customer, project: result.project),
                source: .samples,
                start: sample.capturedAt,
                end: sample.capturedAt.addingTimeInterval(secondsPerSample),
                contributor: contributorInfo(forSample: sample, rule: result.matchingRule)
            ))
        }

        for event in events {
            let result = matcher.attribute(event: event)
            records.append(AttributedRecord(
                bucketID: rowKey(customer: result.customer, project: result.project),
                source: .events,
                start: event.startAt,
                end: event.endAt,
                contributor: contributorInfo(forEvent: event)
            ))
        }

        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var creditedSessionIDs = Set<String>()
        for delta in claudeDeltas {
            guard let session = sessionByID[delta.sessionID], delta.gainedSeconds > 0 else { continue }
            let result = matcher.attribute(session: session)
            records.append(AttributedRecord(
                bucketID: rowKey(customer: result.customer, project: result.project),
                source: .claude,
                start: delta.occurredAt.addingTimeInterval(-delta.gainedSeconds),
                end: delta.occurredAt,
                contributor: contributorInfo(forClaudeSession: session)
            ))
            creditedSessionIDs.insert(session.id)
        }
        // Fallback: pre-v10 sessions with no deltas — treat amortized active as
        // a single interval starting at session start.
        for session in sessions where !creditedSessionIDs.contains(session.id) {
            let active = session.amortizedActiveSeconds(idleThresholdSeconds: idleThresholdSeconds)
            guard active > 0 else { continue }
            let result = matcher.attribute(session: session)
            records.append(AttributedRecord(
                bucketID: rowKey(customer: result.customer, project: result.project),
                source: .claude,
                start: session.startedAt,
                end: session.startedAt.addingTimeInterval(active),
                contributor: contributorInfo(forClaudeSession: session)
            ))
        }

        return records
    }

    /// Tracks, for each bucket, the seconds (since week start) already credited
    /// to that bucket. Each subsequent record only contributes the seconds it
    /// adds beyond what's already covered for its bucket — eliminating overlap
    /// across sources while preserving cross-bucket independence.
    private struct DedupEngine {
        let week: DateInterval
        let weekSeconds: Int
        let daySecondOffsets: [Int]   // 8 entries; day i spans [offsets[i], offsets[i+1])

        var bucketCovered: [String: IndexSet] = [:]
        var perBucketPerSource: [String: [Breakdown.SourceKind: [Double]]] = [:]
        var perBucketContribSeconds: [String: [String: Double]] = [:]
        var perBucketContribInfo: [String: [String: ContributorInfo]] = [:]

        init(week: DateInterval) {
            let cal = Calendar.weekStartingMonday()
            var offsets: [Int] = [0]
            for d in 1...7 {
                if let date = cal.date(byAdding: .day, value: d, to: week.start) {
                    offsets.append(max(0, Int(date.timeIntervalSince(week.start))))
                } else {
                    offsets.append(d * 86_400)
                }
            }
            self.daySecondOffsets = offsets
            self.weekSeconds = offsets[7]
            self.week = week
        }

        mutating func add(_ record: AttributedRecord) {
            let startSec = max(0, Int(record.start.timeIntervalSince(week.start)))
            let endSec = min(weekSeconds, Int(record.end.timeIntervalSince(week.start)))
            guard endSec > startSec else { return }
            var effective = IndexSet(integersIn: startSec..<endSec)
            if let existing = bucketCovered[record.bucketID] {
                effective.subtract(existing)
            }
            guard !effective.isEmpty else { return }

            // Per-day, per-source seconds.
            var bySource = perBucketPerSource[record.bucketID] ?? [:]
            var arr = bySource[record.source] ?? Array(repeating: 0.0, count: 7)
            for d in 0..<7 {
                let dayRange = IndexSet(integersIn: daySecondOffsets[d]..<daySecondOffsets[d + 1])
                arr[d] += Double(effective.intersection(dayRange).count)
            }
            bySource[record.source] = arr
            perBucketPerSource[record.bucketID] = bySource

            // Contributor seconds (week-total).
            if let info = record.contributor {
                let added = Double(effective.count)
                var secsByID = perBucketContribSeconds[record.bucketID] ?? [:]
                secsByID[info.id, default: 0] += added
                perBucketContribSeconds[record.bucketID] = secsByID

                var infoByID = perBucketContribInfo[record.bucketID] ?? [:]
                if infoByID[info.id] == nil { infoByID[info.id] = info }
                perBucketContribInfo[record.bucketID] = infoByID
            }

            // Mark covered.
            var cov = bucketCovered[record.bucketID] ?? IndexSet()
            cov.formUnion(effective)
            bucketCovered[record.bucketID] = cov
        }
    }

    // MARK: - Helpers

    /// Row key shape must mirror everywhere we group by `(customer, project?)`.
    private static func rowKey(customer: Customer?, project: Project?) -> String {
        guard let customer else { return unattributedID }
        if let project { return "\(customer.id)/\(project.id)" }
        return customer.id
    }

    private static func labelAndColor(forBucketID id: String, matcher: RuleMatcher) -> (label: String, color: String?) {
        if id == unattributedID { return (unattributedLabel, nil) }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let customerID = parts[0]
        guard let customer = matcher.customersByID[customerID] else { return (id, nil) }
        if parts.count > 1, let project = matcher.projectsByID[parts[1]] {
            return ("\(customer.name) · \(project.name)", project.color ?? customer.color)
        }
        return (customer.name, customer.color)
    }

    private static func contributorInfo(forSample sample: ActivitySample, rule: Rule?) -> ContributorInfo {
        // If a rule matched, surface the signal it matched on so the user sees
        // *why* this sample was attributed.
        if let kind = rule?.kind {
            switch kind {
            case .gitRepoSlug, .gitRemoteHost:
                if let remote = sample.gitRemoteURL,
                   let slug = RuleMatcher.gitSlug(fromRemote: remote) {
                    return ContributorInfo(
                        id: "git:\(slug)",
                        label: slug,
                        kindLabel: "Git repo",
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
            case .urlPath, .urlHost:
                if let host = sample.chromeHost {
                    return ContributorInfo(
                        id: "host:\(host)",
                        label: host,
                        kindLabel: "Browser",
                        systemImage: "globe"
                    )
                }
            case .windowTitle:
                if let title = sample.windowTitle, !title.isEmpty {
                    return ContributorInfo(
                        id: "title:\(title)",
                        label: title,
                        kindLabel: "Window title",
                        systemImage: "macwindow"
                    )
                }
            case .appBundleID, .emailDomain:
                break
            }
        }
        // Fallback to app metadata — also covers manual overrides (rule == nil).
        let label = sample.appName ?? sample.appBundleID ?? "Unknown app"
        let id = sample.appBundleID ?? label
        return ContributorInfo(
            id: "app:\(id)",
            label: label,
            kindLabel: "App",
            systemImage: "app.fill"
        )
    }

    private static func contributorInfo(forEvent event: CalendarEvent) -> ContributorInfo {
        let trimmed = event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Untitled meeting" : trimmed
        return ContributorInfo(
            id: "event:\(display)",
            label: display,
            kindLabel: "Meeting",
            systemImage: "calendar"
        )
    }

    private static func contributorInfo(forClaudeSession session: ClaudeSession) -> ContributorInfo {
        if let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
            return ContributorInfo(
                id: "claude:\(slug)",
                label: slug,
                kindLabel: "Claude · repo",
                systemImage: "wand.and.stars"
            )
        }
        if let path = session.gitRepoPath {
            let name = (path as NSString).lastPathComponent
            return ContributorInfo(
                id: "claude:\(path)",
                label: name,
                kindLabel: "Claude · repo",
                systemImage: "wand.and.stars"
            )
        }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return ContributorInfo(
                id: "claude:cwd:\(cwd)",
                label: name,
                kindLabel: "Claude · cwd",
                systemImage: "wand.and.stars"
            )
        }
        return ContributorInfo(
            id: "claude:session:\(session.id)",
            label: "Claude session",
            kindLabel: "Claude",
            systemImage: "wand.and.stars"
        )
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
