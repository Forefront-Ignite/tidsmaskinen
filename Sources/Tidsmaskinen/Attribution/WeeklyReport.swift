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
    let breakdownsByRowID: [String: Breakdown]
    /// Distinct wall-clock hours of attributed activity across the week — the
    /// union of every attributed bucket's covered seconds laid on a single
    /// timeline. Unlike `grandTotal` (which sums per-customer time, so parallel
    /// work on two customers in the same minute counts twice), each real second
    /// is counted at most once here. Always ≤ `grandTotal`. Excludes the
    /// unattributed bucket, matching what `grandTotal` sums.
    let activeHours: Double
    var grandTotal: Double { dayTotals.reduce(0, +) }
    var unattributedTotal: Double { unattributedPerDay.reduce(0, +) }

    static let unattributedID = "__unattributed__"
    static let unattributedLabel = "Unattributed"

    static func compute(week: DateInterval,
                        samples: [ActivitySample],
                        events: [CalendarEvent] = [],
                        sessions: [ClaudeSession] = [],
                        claudeDeltas: [AppDatabase.ClaudeActiveDelta] = [],
                        micSessions: [MicSession] = [],
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
            micSessions: micSessions,
            matcher: matcher,
            sampleIntervalSeconds: sampleIntervalSeconds,
            idleThresholdSeconds: idleThresholdSeconds
        )
        for record in records {
            engine.add(record)
        }
        engine.finalize()

        var rows: [Row] = []
        var dayTotals = Array(repeating: 0.0, count: 7)
        var unattributedSeconds = Array(repeating: 0.0, count: 7)
        var breakdowns: [String: Breakdown] = [:]

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
            // Round each cell to nearest 0.25h at construction time so the
            // displayed grid and TSV stay self-consistent — row total is the
            // sum of its cells, column total is the sum of its cells, grand
            // total is the sum of everything. Avoids the classic "0.10h × 7
            // shows blank but the row total reads 0.75".
            let roundedDay = seconds.map { roundedQuarter($0 / 3600.0) }
            rows.append(Row(
                id: bucketID,
                label: label,
                color: color,
                perDayHours: roundedDay
            ))
            for d in 0..<7 { dayTotals[d] += roundedDay[d] }
            breakdowns[bucketID] = makeBreakdown(rowID: bucketID, engine: engine)
        }

        rows.sort { lhs, rhs in
            if lhs.totalHours == rhs.totalHours { return lhs.label < rhs.label }
            return lhs.totalHours > rhs.totalHours
        }

        return WeeklyReport(
            week: week,
            rows: rows,
            dayTotals: dayTotals,
            unattributedPerDay: unattributedSeconds.map { roundedQuarter($0 / 3600.0) },
            breakdownsByRowID: breakdowns,
            activeHours: engine.attributedActiveSeconds / 3600.0
        )
    }

    private static func makeBreakdown(rowID: String, engine: DedupEngine) -> Breakdown {
        let bySource = engine.perBucketPerSource[rowID] ?? [:]
        var perDayHours: [Breakdown.SourceKind: [Double]] = [:]
        for kind in Breakdown.SourceKind.allCases {
            let secs = bySource[kind] ?? Array(repeating: 0.0, count: 7)
            perDayHours[kind] = secs.map { $0 / 3600.0 }
        }

        let contribSeconds = engine.perBucketContribSeconds[rowID] ?? [:]
        let contribInfos = engine.perBucketContribInfo[rowID] ?? [:]
        let eventIDsByContrib = engine.perBucketContribMeetingEventIDs[rowID] ?? [:]
        let seriesIDsByContrib = engine.perBucketContribMeetingSeriesIDs[rowID] ?? [:]
        let contributors: [Breakdown.Contributor] = contribSeconds.compactMap { (id, secs) -> Breakdown.Contributor? in
            guard let info = contribInfos[id], secs > 0 else { return nil }
            let eventIDs = (eventIDsByContrib[id] ?? []).sorted()
            let seriesIDs = (seriesIDsByContrib[id] ?? []).sorted()
            return Breakdown.Contributor(
                id: id,
                label: info.label,
                kindLabel: info.kindLabel,
                systemImage: info.systemImage,
                seconds: secs,
                meetingEventIDs: eventIDs,
                meetingSeriesIDs: seriesIDs
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

    func tsv(weekDays: [Date]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d/M"
        var lines: [String] = []
        let header = ["Customer"] + weekDays.map { formatter.string(from: $0) } + ["Total"]
        lines.append(header.joined(separator: "\t"))
        for row in rows {
            let cells = [Self.tsvSanitize(row.label)]
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

    /// Replace tab/newline/CR in customer or project names so they can't break
    /// the TSV layout. Anything weird is collapsed to a single space.
    private static func tsvSanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\t", "\n", "\r": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Values that reach this function are already quarter-rounded at report
    /// construction time, so we just format them.
    static func formatHours(_ hours: Double) -> String {
        let rounded = roundedQuarter(hours)
        if rounded == 0 { return "" }
        return String(format: "%.2f", rounded)
    }

    static func roundedQuarter(_ hours: Double) -> Double {
        (hours * 4).rounded() / 4
    }

    // MARK: - Row drill-down

    struct Breakdown: Equatable {
        enum SourceKind: String, CaseIterable, Hashable {
            case samples
            case events
            case calls
            case claude

            var label: String {
                switch self {
                case .samples: return "App activity"
                case .events:  return "Calendar"
                case .calls:   return "Calls"
                case .claude:  return "Claude Code"
                }
            }

            var systemImage: String {
                switch self {
                case .samples: return "app.dashed"
                case .events:  return "calendar"
                case .calls:   return "mic.fill"
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
            /// Calendar event IDs that fed this contributor (meetings only).
            /// Lets the UI re-attribute a contributor row back to its underlying
            /// occurrences without re-querying the database.
            let meetingEventIDs: [String]
            /// Unique `seriesMasterID`s among the contributing events. Empty
            /// when no event in the row was part of a recurring series.
            let meetingSeriesIDs: [String]
            var hours: Double { seconds / 3600.0 }
            var isMeeting: Bool { !meetingEventIDs.isEmpty }
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
        /// Calendar-event-specific payload. Set only for `.events` records; the
        /// dedup engine accumulates the IDs to power "re-attribute this
        /// contributor" actions in the weekly report drill-down.
        let eventID: String?
        let seriesMasterID: String?
    }

    /// Priority order when overlapping sources cover the same second of wall
    /// time for the same bucket: calendar events outrank calls outrank Claude
    /// sessions outrank app activity samples. Each second can only credit one
    /// source, so the per-bucket total never exceeds elapsed wall time.
    private static func byPriority(_ a: AttributedRecord, _ b: AttributedRecord) -> Bool {
        priorityIndex(a.source) < priorityIndex(b.source)
    }

    private static func priorityIndex(_ kind: Breakdown.SourceKind) -> Int {
        switch kind {
        case .events:  return 0
        case .calls:   return 1
        case .claude:  return 2
        case .samples: return 3
        }
    }

    /// Walks raw inputs and turns each into a time-bounded `AttributedRecord`.
    private static func collectRecords(week: DateInterval,
                                        samples: [ActivitySample],
                                        events: [CalendarEvent],
                                        sessions: [ClaudeSession],
                                        claudeDeltas: [AppDatabase.ClaudeActiveDelta],
                                        micSessions: [MicSession],
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
            let attribution = matcher.attribute(event: event)
            if attribution.isIgnored { continue }
            let result = attribution.asAttributionResult
            records.append(AttributedRecord(
                bucketID: rowKey(customer: result.customer, project: result.project),
                source: .events,
                start: event.startAt,
                end: event.endAt,
                contributor: contributorInfo(forEvent: event)
            ))
        }

        // Ad-hoc call time: mic activity that isn't already covered by a
        // (mic-extended) meeting. Meeting-overlapping mic time is credited via
        // the events above, so we subtract the same extended events here to
        // avoid double-counting; only genuinely impromptu calls (huddles,
        // ad-hoc Teams/FaceTime) remain. Only attributed calls reach the report
        // — unattributed call time shows up in the Review backlog instead. We
        // skip ongoing sessions (no end yet) so a live call isn't counted.
        for session in micSessions {
            guard let endedAt = session.endedAt, endedAt > session.startedAt else { continue }
            if session.isIgnored { continue }
            let result = matcher.attribute(micSession: session)
            guard result.customer != nil else { continue }
            let bucketID = rowKey(customer: result.customer, project: result.project)
            let contributor = contributorInfo(forCall: session)
            let remainders = CallSegment.subtractEvents(
                from: session.startedAt, to: endedAt, events: events, minimumSeconds: 30
            )
            for r in remainders {
                records.append(AttributedRecord(
                    bucketID: bucketID,
                    source: .calls,
                    start: r.start,
                    end: r.end,
                    contributor: contributor
                ))
            }
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

    /// Buffers records per bucket, then resolves them into per-day / per-source
    /// / per-contributor seconds. Within a bucket, records are applied in
    /// priority order and each wall-clock second is credited to the first source
    /// that claims it (so the bucket total never exceeds elapsed time and higher
    /// priority sources win contested seconds). Buckets are independent, so the
    /// same second can be credited to two different customers worked in parallel.
    ///
    /// Coverage is tracked with a flat per-second claim buffer (reused across
    /// buckets) rather than a per-bucket `IndexSet`. A real week fragments a
    /// busy bucket into thousands of disjoint 15 s blocks; the old IndexSet
    /// rescanned all of them on every insert (O(N²) — multiple seconds per
    /// report). The flat buffer makes resolution O(total covered seconds).
    private struct DedupEngine {
        let week: DateInterval
        let weekSeconds: Int
        let daySecondOffsets: [Int]   // 8 entries; day i spans [offsets[i], offsets[i+1])

        var perBucketPerSource: [String: [Breakdown.SourceKind: [Double]]] = [:]
        var perBucketContribSeconds: [String: [String: Double]] = [:]
        var perBucketContribInfo: [String: [String: ContributorInfo]] = [:]
        /// Calendar-event payload accumulated per `(bucket, contributor)`. Used
        /// to surface the underlying events on a meeting contributor row so the
        /// UI can reattribute them in one click.
        var perBucketContribMeetingEventIDs: [String: [String: Set<String>]] = [:]
        var perBucketContribMeetingSeriesIDs: [String: [String: Set<String>]] = [:]
        /// Distinct active seconds across all *attributed* buckets — each
        /// wall-clock second counted at most once regardless of parallel work,
        /// so it never exceeds elapsed time. Filled by `finalize()`.
        var attributedActiveSeconds: Double = 0

        private var recordsByBucket: [String: [AttributedRecord]] = [:]

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
            recordsByBucket[record.bucketID, default: []].append(record)
        }

        /// Resolve all buffered records. Call once after every `add`.
        mutating func finalize() {
            guard weekSeconds > 0 else { return }
            // `claimed` is reset (only over touched spans) between buckets;
            // `attributedUnion` persists to count distinct active seconds.
            var claimed = [Bool](repeating: false, count: weekSeconds)
            var attributedUnion = [Bool](repeating: false, count: weekSeconds)

            for (bucketID, recs) in recordsByBucket {
                let isAttributed = bucketID != WeeklyReport.unattributedID
                let sorted = recs.sorted(by: WeeklyReport.byPriority)

                var bySource: [Breakdown.SourceKind: [Double]] = [:]
                var secsByID: [String: Double] = [:]
                var infoByID: [String: ContributorInfo] = [:]
                var eventIDsByContrib: [String: Set<String>] = [:]
                var seriesIDsByContrib: [String: Set<String>] = [:]
                var touched: [(Int, Int)] = []
                touched.reserveCapacity(sorted.count)

                for record in sorted {
                    let s = max(0, Int(record.start.timeIntervalSince(week.start)))
                    let e = min(weekSeconds, Int(record.end.timeIntervalSince(week.start)))
                    guard e > s else { continue }
                    touched.append((s, e))

                    var arr = bySource[record.source] ?? Array(repeating: 0.0, count: 7)
                    var addedTotal = 0
                    var i = s
                    while i < e {
                        if claimed[i] { i += 1; continue }
                        // Claim a contiguous free run, bounded by the day end so
                        // each run lands in exactly one day bucket.
                        let d = dayIndex(forSecond: i)
                        let limit = min(e, daySecondOffsets[d + 1])
                        var j = i
                        while j < limit && !claimed[j] {
                            claimed[j] = true
                            if isAttributed { attributedUnion[j] = true }
                            j += 1
                        }
                        let secs = j - i
                        arr[d] += Double(secs)
                        addedTotal += secs
                        i = j
                    }
                    bySource[record.source] = arr

                    if let info = record.contributor, addedTotal > 0 {
                        secsByID[info.id, default: 0] += Double(addedTotal)
                        if infoByID[info.id] == nil { infoByID[info.id] = info }
                        if let eventID = info.eventID { eventIDsByContrib[info.id, default: []].insert(eventID) }
                        if let seriesID = info.seriesMasterID { seriesIDsByContrib[info.id, default: []].insert(seriesID) }
                    }
                }

                perBucketPerSource[bucketID] = bySource
                perBucketContribSeconds[bucketID] = secsByID
                perBucketContribInfo[bucketID] = infoByID
                perBucketContribMeetingEventIDs[bucketID] = eventIDsByContrib
                perBucketContribMeetingSeriesIDs[bucketID] = seriesIDsByContrib

                // Reset only what this bucket touched, ready for the next bucket.
                for (s, e) in touched where e > s {
                    for k in s..<e { claimed[k] = false }
                }
            }

            var active = 0
            for v in attributedUnion where v { active += 1 }
            attributedActiveSeconds = Double(active)
        }

        /// Day index (0...6) a given second-offset falls in, per the (possibly
        /// DST-adjusted) day boundaries. Clamped to the valid range.
        private func dayIndex(forSecond sec: Int) -> Int {
            var d = 0
            while d < 6 && sec >= daySecondOffsets[d + 1] { d += 1 }
            return d
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
            return ("\(customer.name) · \(project.name)", project.displayColor)
        }
        return (customer.name, customer.displayColor)
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
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        eventID: nil,
                        seriesMasterID: nil
                    )
                }
            case .urlPath, .urlHost:
                if let host = sample.chromeHost {
                    return ContributorInfo(
                        id: "host:\(host)",
                        label: host,
                        kindLabel: "Browser",
                        systemImage: "globe",
                        eventID: nil,
                        seriesMasterID: nil
                    )
                }
            case .windowTitle:
                if let title = sample.windowTitle, !title.isEmpty {
                    return ContributorInfo(
                        id: "title:\(title)",
                        label: title,
                        kindLabel: "Window title",
                        systemImage: "macwindow",
                        eventID: nil,
                        seriesMasterID: nil
                    )
                }
            case .slackChannel:
                if let title = sample.windowTitle,
                   let channel = MicSession.parseSlackChannel(fromTitle: title) {
                    return ContributorInfo(
                        id: "slack:\(channel)",
                        label: "#\(channel)",
                        kindLabel: "Slack channel",
                        systemImage: "bubble.left.and.bubble.right",
                        eventID: nil,
                        seriesMasterID: nil
                    )
                }
            case .appBundleID:
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
            systemImage: "app.fill",
            eventID: nil,
            seriesMasterID: nil
        )
    }

    private static func contributorInfo(forEvent event: CalendarEvent) -> ContributorInfo {
        let trimmed = event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Untitled meeting" : trimmed
        return ContributorInfo(
            id: "event:\(display)",
            label: display,
            kindLabel: "Meeting",
            systemImage: "calendar",
            eventID: event.id,
            seriesMasterID: event.seriesMasterID
        )
    }

    private static func contributorInfo(forCall session: MicSession) -> ContributorInfo {
        let label: String
        if let p = session.participant, !p.isEmpty {
            label = p
        } else if let ch = session.slackChannel, !ch.isEmpty {
            label = "#\(ch)"
        } else {
            label = "Call"
        }
        return ContributorInfo(
            id: "call:\(session.id)",
            label: label,
            kindLabel: "Call",
            systemImage: "mic.fill",
            eventID: nil,
            seriesMasterID: nil
        )
    }

    private static func contributorInfo(forClaudeSession session: ClaudeSession) -> ContributorInfo {
        if let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
            return ContributorInfo(
                id: "claude:\(slug)",
                label: slug,
                kindLabel: "Claude · repo",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        if let path = session.gitRepoPath {
            let name = (path as NSString).lastPathComponent
            return ContributorInfo(
                id: "claude:\(path)",
                label: name,
                kindLabel: "Claude · repo",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return ContributorInfo(
                id: "claude:cwd:\(cwd)",
                label: name,
                kindLabel: "Claude · cwd",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        return ContributorInfo(
            id: "claude:session:\(session.id)",
            label: "Claude session",
            kindLabel: "Claude",
            systemImage: "wand.and.stars",
            eventID: nil,
            seriesMasterID: nil
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
