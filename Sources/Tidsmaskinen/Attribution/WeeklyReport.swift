import Foundation

/// How each report cell is rounded to a quarter hour. Every mode keeps the
/// day's true total: the rounding residue lands on that day's largest bucket.
enum ReportRounding: String, CaseIterable, Identifiable {
    case nearest, up, down
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nearest: return "Nearest ¼ h"
        case .up:      return "Round up"
        case .down:    return "Round down"
        }
    }

    func round(_ hours: Double) -> Double {
        switch self {
        case .nearest: return (hours * 4).rounded() / 4
        case .up:      return (hours * 4 - 1e-9).rounded(.up) / 4
        case .down:    return (hours * 4 + 1e-9).rounded(.down) / 4
        }
    }
}

struct WeeklyReport {
    struct Row: Identifiable, Equatable {
        let id: String          // customerID or "__unattributed__"
        let label: String       // customer name or "Unattributed"
        let color: String?
        let perDayHours: [Double]   // 7 entries, Mon..Sun, rounded
        /// The same cells before rounding, for hover.
        var rawPerDayHours: [Double] = []
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
    /// Hours an agent was active per row id (and `unattributedID`), by the
    /// hook measure: wall clock with any of that bucket's sessions running.
    /// Context beside the billed hours; never part of them.
    let agentHoursByRowID: [String: Double]
    /// Overlapping meetings of the same standing, resolved or not. Unresolved
    /// ones bill twice until the user picks the meeting they were in.
    let doubleBookings: [MeetingBilling.DoubleBooking]
    var grandTotal: Double { dayTotals.reduce(0, +) }
    var unattributedTotal: Double { unattributedPerDay.reduce(0, +) }

    static let unattributedID = "__unattributed__"
    static let unattributedLabel = "Unattributed"

    /// Reads one period's inputs and computes its report.
    static func load(from database: AppDatabase, week: DateInterval, matcher: RuleMatcher,
                     sampleIntervalSeconds: Int, rounding: ReportRounding) throws -> WeeklyReport {
        compute(week: week,
                samples: try database.samples(in: week),
                events: try database.calendarEvents(in: week),
                sessions: try database.sessions(in: week),
                claudeDeltas: try database.claudeActiveDeltas(in: week),
                overlapChoices: try database.meetingOverlapChoices(),
                cellsCalls: try database.cellsCalls(in: week),
                matcher: matcher,
                sampleIntervalSeconds: sampleIntervalSeconds,
                rounding: rounding)
    }

    /// `sessions` and `claudeDeltas` only feed the agent-activity context;
    /// they bill nothing.
    static func compute(week: DateInterval,
                        samples: [ActivitySample],
                        events: [CalendarEvent] = [],
                        sessions: [ClaudeSession] = [],
                        claudeDeltas: [AppDatabase.ClaudeActiveDelta] = [],
                        overlapChoices: [MeetingOverlapChoice] = [],
                        cellsCalls: [CellsCall] = [],
                        matcher: RuleMatcher,
                        sampleIntervalSeconds: Int,
                        rounding: ReportRounding = .nearest) -> WeeklyReport {
        var engine = DedupEngine(week: week)
        let records = collectRecords(
            samples: samples,
            events: events,
            overlapChoices: overlapChoices,
            cellsCalls: cellsCalls,
            matcher: matcher,
            sampleIntervalSeconds: sampleIntervalSeconds
        )
        for record in records {
            engine.add(record)
        }
        engine.finalize()

        var rows: [Row] = []
        var dayTotals = Array(repeating: 0.0, count: 7)
        var unattributedSeconds = Array(repeating: 0.0, count: 7)
        var breakdowns: [String: Breakdown] = [:]

        var raw: [(id: String, label: String, color: String?, hours: [Double])] = []
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
            raw.append((bucketID, label, color, seconds.map { $0 / 3600.0 }))
            breakdowns[bucketID] = makeBreakdown(rowID: bucketID, engine: engine)
        }
        // Round each cell at construction time so the grid and the TSV stay
        // self-consistent (row total = its cells, column total = its cells),
        // then keep every day's true total: a positive residue lands on that
        // day's largest bucket, a negative one comes off the largest buckets
        // that still have time, so seven 0.10 h slivers can't add a phantom
        // 0.75 and three rounded-up slivers can't overstate the day.
        raw.sort { $0.id < $1.id }   // deterministic tie-breaking
        var rounded = raw.map { $0.hours.map { rounding.round($0) } }
        for d in 0..<7 {
            let trueTotal = rounding.round(raw.reduce(0) { $0 + $1.hours[d] })
            var diff = trueTotal - rounded.reduce(0) { $0 + $1[d] }
            while diff <= -0.125 {
                guard let i = raw.indices.filter({ rounded[$0][d] > 0 })
                        .max(by: { raw[$0].hours[d] < raw[$1].hours[d] }) else { break }
                let step = min(rounded[i][d], (-diff * 4).rounded() / 4)
                rounded[i][d] -= step
                diff += step
            }
            if diff >= 0.125, let i = raw.indices.max(by: { raw[$0].hours[d] < raw[$1].hours[d] }) {
                rounded[i][d] += diff
            }
        }
        for (i, r) in raw.enumerated() {
            rows.append(Row(id: r.id, label: r.label, color: r.color, perDayHours: rounded[i], rawPerDayHours: r.hours))
            for d in 0..<7 { dayTotals[d] += rounded[i][d] }
        }

        rows.sort { lhs, rhs in
            if lhs.totalHours == rhs.totalHours { return lhs.label < rhs.label }
            return lhs.totalHours > rhs.totalHours
        }

        let agent = agentSeconds(week: week, sessions: sessions, claudeDeltas: claudeDeltas, matcher: matcher)
        return WeeklyReport(
            week: week,
            rows: rows,
            dayTotals: dayTotals,
            unattributedPerDay: unattributedSeconds.map { rounding.round($0 / 3600.0) },
            breakdownsByRowID: breakdowns,
            activeHours: engine.attributedActiveSeconds / 3600.0,
            agentHoursByRowID: agent.mapValues { $0 / 3600.0 },
            doubleBookings: MeetingBilling.doubleBookings(events: events, matcher: matcher, choices: overlapChoices)
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
        formatter.dateFormat = "EEE d/M/yyyy"
        var lines: [String] = []
        let header = ["Customer · Project"] + weekDays.map { formatter.string(from: $0) } + ["Total"]
        lines.append(header.joined(separator: "\t"))
        // A row that rounds to 0 h all week has nothing to report.
        for row in rows where row.totalHours > 0 {
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

            var label: String {
                switch self {
                case .samples: return "App activity"
                case .events:  return "Calendar"
                }
            }

            var systemImage: String {
                switch self {
                case .samples: return "app.dashed"
                case .events:  return "calendar"
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

    /// Priority order when sources cover the same second for the same bucket:
    /// meetings before samples. Samples are already clipped around meetings,
    /// so this only orders records; meetings themselves are never deduplicated.
    private static func byPriority(_ a: AttributedRecord, _ b: AttributedRecord) -> Bool {
        priorityIndex(a.source) < priorityIndex(b.source)
    }

    private static func priorityIndex(_ kind: Breakdown.SourceKind) -> Int {
        switch kind {
        case .events:  return 0
        case .samples: return 1
        }
    }

    /// Lays meetings and samples on one focus timeline. A meeting bills its
    /// booked time after double bookings are settled; each active sample
    /// bills from its capture to the next sample, minus meeting time. Calls
    /// and agent runtime bill nothing.
    private static func collectRecords(samples: [ActivitySample],
                                        events: [CalendarEvent],
                                        overlapChoices: [MeetingOverlapChoice],
                                        cellsCalls: [CellsCall],
                                        matcher: RuleMatcher,
                                        sampleIntervalSeconds: Int) -> [AttributedRecord] {
        var records: [AttributedRecord] = []
        records.reserveCapacity(samples.count + events.count)

        let billed = MeetingBilling.billed(events: events, matcher: matcher, choices: overlapChoices)
        for m in billed {
            let result = m.attribution.asAttributionResult
            let contributor = contributorInfo(forEvent: m.event)
            for iv in m.intervals {
                records.append(AttributedRecord(
                    bucketID: rowKey(customer: result.customer, project: result.project),
                    source: .events, start: iv.start, end: iv.end, contributor: contributor))
            }
        }

        // Cells in front during one of your calls is that call's time.
        let calls = CellsCallIndex(calls: cellsCalls)
        let spans = FocusSpans.spans(samples: samples,
                                     sampleInterval: TimeInterval(sampleIntervalSeconds),
                                     blocked: MeetingBilling.blocked(events: events, matcher: matcher),
                                     isActive: calls.isActive)
        for (sample, pieces) in spans {
            let call = calls.call(for: sample)
            if call == nil, matcher.isRepoIgnored(sample: sample) { continue }
            let result = call.map(matcher.attribute(cellsCall:)) ?? matcher.attribute(sample)
            let contributor = call.map { contributorInfo(forCellsCall: $0, matcher: matcher) }
                ?? matcher.session(for: sample).map(contributorInfo(forClaudeSession:))
                ?? contributorInfo(forSample: sample, rule: result.matchingRule)
            for piece in pieces {
                records.append(AttributedRecord(
                    bucketID: rowKey(customer: result.customer, project: result.project),
                    source: .samples, start: piece.start, end: piece.end, contributor: contributor))
            }
        }
        return records
    }

    /// Wall-clock seconds per bucket during which an agent session for that
    /// bucket was active, by the hook measure. Context only.
    private static func agentSeconds(week: DateInterval, sessions: [ClaudeSession],
                                     claudeDeltas: [AppDatabase.ClaudeActiveDelta],
                                     matcher: RuleMatcher) -> [String: Double] {
        let sessionByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byBucket: [String: [DateInterval]] = [:]
        for d in claudeDeltas where d.gainedSeconds > 0 {
            guard let session = sessionByID[d.sessionID] ?? matcher.sessionsByID[d.sessionID],
                  !matcher.isRepoIgnored(remoteURL: session.gitRemoteURL) else { continue }
            let span = DateInterval(start: d.occurredAt.addingTimeInterval(-d.gainedSeconds), end: d.occurredAt)
            guard let clipped = span.intersectionIfPositive(with: week) else { continue }
            let r = matcher.attribute(session: session, at: d.occurredAt)
            byBucket[rowKey(customer: r.customer, project: r.project), default: []].append(clipped)
        }
        return byBucket.mapValues { DateInterval.union($0).reduce(0) { $0 + $1.duration } }
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
            // A shorter period (My day passes one day) ends where it ends:
            // a meeting running past midnight doesn't add tomorrow to today.
            self.weekSeconds = min(offsets[7], max(0, Int(week.duration)))
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
                    // Meetings were settled by MeetingBilling: a double booking
                    // bills both meetings, even for the same customer, until the
                    // user picks one. Samples are already clipped around them.
                    if record.source == .events {
                        while i < e {
                            let d = dayIndex(forSecond: i)
                            let limit = min(e, daySecondOffsets[d + 1])
                            if isAttributed { for k in i..<limit { attributedUnion[k] = true } }
                            arr[d] += Double(limit - i)
                            addedTotal += limit - i
                            i = limit
                        }
                    }
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
                if let slug = sample.gitRemoteURL.flatMap(RuleMatcher.gitSlug(fromRemote:))
                    ?? sample.chromeURL.flatMap(RuleMatcher.gitSlug(fromForgeURL:)) {
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

    private static func contributorInfo(forCellsCall call: CellsCall, matcher: RuleMatcher) -> ContributorInfo {
        let name = matcher.cellsChatsByID[call.chatID]?.name ?? "Cells call"
        return ContributorInfo(id: "cells-call:\(call.chatID)", label: name, kindLabel: "Cells call",
                               systemImage: "phone.fill", eventID: nil, seriesMasterID: nil)
    }

    private static func contributorInfo(forClaudeSession session: ClaudeSession) -> ContributorInfo {
        if let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
            return ContributorInfo(
                id: "\(session.provider.rawValue):\(slug)",
                label: slug,
                kindLabel: "\(session.provider.displayName) · repo",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        if let path = session.gitRepoPath {
            let name = (path as NSString).lastPathComponent
            return ContributorInfo(
                id: "\(session.provider.rawValue):\(path)",
                label: name,
                kindLabel: "\(session.provider.displayName) · repo",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return ContributorInfo(
                id: "\(session.provider.rawValue):cwd:\(cwd)",
                label: name,
                kindLabel: "\(session.provider.displayName) · cwd",
                systemImage: "wand.and.stars",
                eventID: nil,
                seriesMasterID: nil
            )
        }
        return ContributorInfo(
            id: "\(session.provider.rawValue):session:\(session.id)",
            label: "\(session.provider.displayName) session",
            kindLabel: session.provider.displayName,
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
