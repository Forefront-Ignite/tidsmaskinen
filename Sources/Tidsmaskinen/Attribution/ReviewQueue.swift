import Foundation

/// Builds the Review triage queue: the unattributed, above-threshold signals and
/// meetings worth surfacing for attribution in a given period.
///
/// Shared by the Review screen (which renders each unit as a card) and the
/// Weekly Report / menu-bar glance (which only need the count + total time). By
/// deriving the report's "to review" indicator from this exact list, the two
/// stay in lockstep — no more "30% unattributed" in the report while Review
/// says "you're all caught up".
///
/// Deliberately excludes:
///  - **App-only time** — apps aren't reviewable (an editor or browser can't be
///    pinned to a single customer); they still attribute via repo/URL signals.
///  - **Anything below `minMinutes`** — short fragments are ambient, not a to-do.
///
/// That excluded time is real tracked time, but it's *ambient*, not a review
/// backlog, so it never inflates the count. `rows` lists it anyway (as
/// `.ambient` / `belowThreshold`) so Review can still teach an app rule from it.

/// One row of the Review list: the item, how it stands in the period, and
/// how its time falls across the period's days.
struct ReviewRow: Identifiable {
    enum Status: Equatable {
        /// Unattributed time worth a decision. `unit.totalSeconds` is that open time only.
        case open
        /// `scope` says how: "Always", "This week", "This day", "Bounded" (a rule
        /// window), "Manual" (per-item override), "Series", "This meeting",
        /// "Pinned" (a saved call), or "Mixed" when the period's time splits
        /// across several attributions — `customerID` is then the largest share.
        case attributed(customerID: String, projectID: String?, scope: String)
        case ignored
        /// App-only time with no home. Not a to-do — an editor or browser can't be
        /// pinned to one customer — but an app rule can be taught from it.
        case ambient
    }

    let unit: ReviewUnit
    let status: Status
    /// Seconds per day of the period, first day first.
    let perDay: [Double]
    /// Open time under the review threshold: hidden from Review by default and
    /// never part of the backlog count.
    let belowThreshold: Bool
    /// The longest stretches of this signal in the period (open ones for an open
    /// row), longest first — the evidence the detail pane shows. Signals only.
    var evidence: [ReviewEvidence] = []
    /// How many stretches `evidence` was picked from, so the pane can say what
    /// the shorter ones add up to.
    var stretchCount: Int = 0

    var id: String { unit.id }
    var totalSeconds: Double { unit.totalSeconds }
    var isOpen: Bool { status == .open }
}

/// One stretch of consecutive samples on a signal, with the window title (or
/// URL path for a browser host) seen most in it.
struct ReviewEvidence: Identifiable, Equatable {
    let start: Date
    let end: Date
    /// Sampled seconds inside the stretch (brief switches elsewhere are not counted).
    let seconds: Double
    let detail: String?
    var id: Date { start }
}

enum ReviewQueue {
    /// Samples further apart than this start a new evidence stretch, so a quick
    /// look at Slack doesn't split a morning on one repo into two.
    static let evidenceGapSeconds: TimeInterval = 120

    /// The scope a rule was written with, as Review prints it.
    static func scopeLabel(_ rule: Rule?) -> String {
        guard let rule else { return "Manual" }
        guard rule.isTemporary else { return "Always" }
        if let from = rule.validFrom, let to = rule.validTo {
            if to.timeIntervalSince(from) <= 86_400 + 3_600 { return "This day" }
            if to.timeIntervalSince(from) <= 7 * 86_400 + 3_600 { return "This week" }
        }
        return "Bounded"
    }

    /// The triage backlog: the open rows above the threshold, largest first.
    static func build(database: AppDatabase,
                      interval: DateInterval,
                      sampleIntervalSeconds: Int,
                      idleThresholdSeconds: TimeInterval,
                      minMinutes: Int) throws -> [ReviewUnit] {
        try rows(database: database, interval: interval,
                 sampleIntervalSeconds: sampleIntervalSeconds,
                 idleThresholdSeconds: idleThresholdSeconds,
                 minMinutes: minMinutes)
            .filter { $0.isOpen && !$0.belowThreshold }
            .map(\.unit)
            .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    /// Every item with time in the period — open, attributed, ignored or
    /// ambient — resolved per sample at its own timestamp, so a Monday rule
    /// cannot hide Tuesday's backlog and a Wednesday-only rule shows as such.
    static func rows(database: AppDatabase,
                     interval: DateInterval,
                     sampleIntervalSeconds: Int,
                     idleThresholdSeconds: TimeInterval,
                     minMinutes: Int) throws -> [ReviewRow] {
        let m = try RuleMatcher.load(from: database)
        let hidden = try database.allHiddenSignals()
        let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
        let hiddenPaths = Set(hidden.filter { $0.kind == .urlPath }.map { $0.value })
        let hiddenApps = Set(hidden.filter { $0.kind == .appBundleID }.map { $0.value })
        let minSec = Double(minMinutes) * 60
        let cal = Calendar.weekStartingMonday()
        let dayCount = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: interval.start),
                                                  to: cal.startOfDay(for: interval.end.addingTimeInterval(-1))).day ?? 0) + 1)
        func dayIndex(_ date: Date) -> Int {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: interval.start), to: date).day ?? 0
            return min(max(d, 0), dayCount - 1)
        }

        /// Time for one signal, split by how it was attributed.
        struct Share: Hashable { let customerID: String?; let projectID: String?; let scope: String }
        struct Stretch { var start: Date; var end: Date; var open: Bool; var seconds: Double; var details: [String: Int] = [:] }
        struct Acc {
            var shares: [Share: Double] = [:]
            var perDay: [Double]        // all time, for attributed / ambient rows
            var openPerDay: [Double]    // open time only, for open rows (matches their total)
            var hidden = false
            var stretches: [Stretch] = []
            init(days: Int) { perDay = Array(repeating: 0, count: days); openPerDay = perDay }
            var total: Double { shares.values.reduce(0, +) }
            var open: Double { shares.filter { $0.key.customerID == nil }.values.reduce(0, +) }
            mutating func add(_ seconds: Double, day: Int, _ r: AttributionResult) {
                shares[share(for: r), default: 0] += seconds
                perDay[day] += seconds
                if r.customer == nil { openPerDay[day] += seconds }
            }
            /// Extend the current stretch with a sample, or start a new one after
            /// a gap or when the attribution state flips. Samples arrive in time order.
            mutating func note(_ seconds: Double, at: Date, open: Bool, detail: String?) {
                if var last = stretches.last, last.open == open, at.timeIntervalSince(last.end) <= ReviewQueue.evidenceGapSeconds {
                    last.end = max(last.end, at.addingTimeInterval(seconds))
                    last.seconds += seconds
                    if let detail { last.details[detail, default: 0] += 1 }
                    stretches[stretches.count - 1] = last
                } else {
                    var s = Stretch(start: at, end: at.addingTimeInterval(seconds), open: open, seconds: seconds)
                    if let detail { s.details[detail] = 1 }
                    stretches.append(s)
                }
            }
            func stretchCount(openOnly: Bool) -> Int { stretches.filter { !openOnly || $0.open }.count }
            /// The three longest stretches — only the open ones for an open row.
            func evidence(openOnly: Bool) -> [ReviewEvidence] {
                stretches.filter { !openOnly || $0.open }
                    .sorted { $0.seconds > $1.seconds }.prefix(3)
                    .map { s in
                        let top = s.details.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
                        return ReviewEvidence(start: s.start, end: s.end, seconds: s.seconds, detail: top)
                    }
            }
        }
        func share(for r: AttributionResult) -> Share {
            guard let c = r.customer else { return Share(customerID: nil, projectID: nil, scope: "") }
            return Share(customerID: c.id, projectID: r.project?.id, scope: ReviewQueue.scopeLabel(r.matchingRule))
        }
        /// The row status for a signal: open when open time remains, else its
        /// largest attribution (flagged Mixed when others exist), else ambient.
        func status(_ acc: Acc, ambientWhenOpen: Bool) -> ReviewRow.Status {
            if acc.hidden { return .ignored }
            if acc.open > 0 { return ambientWhenOpen ? .ambient : .open }
            let attributed = acc.shares.filter { $0.key.customerID != nil }
            guard let top = attributed.max(by: { $0.value < $1.value }), let cid = top.key.customerID else { return .ambient }
            let scope = attributed.count > 1 ? "Mixed" : top.key.scope
            return .attributed(customerID: cid, projectID: top.key.projectID, scope: scope)
        }

        var repos: [String: Acc] = [:]
        var hosts: [String: Acc] = [:]
        var paths: [String: [String: Acc]] = [:]     // host → path → acc
        var apps: [String: Acc] = [:]

        for sample in try database.samples(in: interval) where !sample.isIdle {
            let seconds = min(Double(sampleIntervalSeconds), interval.end.timeIntervalSince(sample.capturedAt))
            let day = dayIndex(sample.capturedAt)
            let r = m.attribute(sample)
            let open = r.customer == nil
            let title = sample.windowTitle?.trimmingCharacters(in: .whitespaces)
            if let remote = sample.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
                var acc = repos[slug] ?? Acc(days: dayCount)
                acc.hidden = m.isRepoIgnored(slug: slug)
                acc.add(seconds, day: day, r)
                acc.note(seconds, at: sample.capturedAt, open: open, detail: title)
                repos[slug] = acc
            } else if let host = sample.chromeHost {
                let path = sample.chromeURL.flatMap { RuleMatcher.urlPathPrefix($0) }
                if let path {
                    // Hidden paths are dropped entirely, host included — as the
                    // backlog always did. Settings → Ignored still lists them.
                    guard !hiddenPaths.contains(path) else { continue }
                    var pacc = paths[host]?[path] ?? Acc(days: dayCount)
                    pacc.add(seconds, day: day, r)
                    pacc.note(seconds, at: sample.capturedAt, open: open, detail: title)
                    paths[host, default: [:]][path] = pacc
                }
                var acc = hosts[host] ?? Acc(days: dayCount)
                acc.hidden = hiddenHosts.contains(host)
                acc.add(seconds, day: day, r)
                acc.note(seconds, at: sample.capturedAt, open: open, detail: path ?? title)
                hosts[host] = acc
            } else if let bundle = sample.appBundleID {
                var acc = apps[bundle] ?? Acc(days: dayCount)
                acc.hidden = hiddenApps.contains(bundle)
                acc.add(seconds, day: day, r)
                acc.note(seconds, at: sample.capturedAt, open: open, detail: title)
                apps[bundle] = acc
            }
        }
        let sessionSeconds = try database.sessionActiveSeconds(in: interval, idleThresholdSeconds: idleThresholdSeconds)
        for session in try database.sessions(in: interval) {
            guard let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote),
                  let seconds = sessionSeconds[session.id], seconds > 0 else { continue }
            var acc = repos[slug] ?? Acc(days: dayCount)
            acc.hidden = m.isRepoIgnored(slug: slug)
            // Active seconds aren't split by day; credit the session's day in the period.
            acc.add(seconds, day: dayIndex(max(session.startedAt, interval.start)), m.attribute(session: session))
            repos[slug] = acc
        }

        var rows: [ReviewRow] = []
        func signalRow(_ kind: AppDatabase.SignalAggregate.Kind, _ value: String, _ acc: Acc, ambient: Bool = false) -> ReviewRow {
            let st = status(acc, ambientWhenOpen: ambient)
            let seconds = st == .open ? acc.open : acc.total
            return ReviewRow(unit: .signal(.init(kind: kind, value: value, totalSeconds: seconds)),
                             status: st, perDay: st == .open ? acc.openPerDay : acc.perDay,
                             belowThreshold: st == .open && seconds < minSec,
                             evidence: acc.evidence(openOnly: st == .open), stretchCount: acc.stretchCount(openOnly: st == .open))
        }
        for (slug, acc) in repos { rows.append(signalRow(.gitRepoSlug, slug, acc)) }
        for (bundle, acc) in apps { rows.append(signalRow(.appBundleID, bundle, acc, ambient: true)) }
        for (host, acc) in hosts {
            let st = status(acc, ambientWhenOpen: false)
            guard st == .open else {
                rows.append(signalRow(.urlHost, host, acc)); continue
            }
            // Every open path with a minute or more gets its own assign row — the
            // review threshold gates the host, not which of its paths can be sorted
            // (under a 10-minute threshold no GitHub repo page would ever qualify).
            let openPaths = (paths[host] ?? [:]).compactMap { path, pacc -> AppDatabase.SignalAggregate? in
                guard pacc.open >= 60 else { return nil }
                return .init(kind: .urlPath, value: path, totalSeconds: pacc.open)
            }.sorted { $0.totalSeconds > $1.totalSeconds }
            let aggregate = AppDatabase.SignalAggregate(kind: .urlHost, value: host, totalSeconds: acc.open)
            rows.append(ReviewRow(unit: openPaths.isEmpty ? .signal(aggregate) : .hostGroup(host: aggregate, paths: openPaths),
                                  status: .open, perDay: acc.openPerDay, belowThreshold: acc.open < minSec,
                                  evidence: acc.evidence(openOnly: true), stretchCount: acc.stretchCount(openOnly: true)))
        }

        // Meetings, stretched over the mic time each one owns (as the report and
        // My day count them). Declined bookings never bill, so they are not listed.
        let rawEvents = try database.calendarEvents(in: interval)
        let micSessions = try database.micSessions(in: interval)
        let extendedEvents = micSessions.isEmpty ? rawEvents
            : CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions, matcher: m)
        let events = extendedEvents.filter { $0.rsvpStatus != "declined" }
        func eventDays(_ e: CalendarEvent) -> [Double] {
            var d = Array(repeating: 0.0, count: dayCount)
            d[dayIndex(max(e.startAt, interval.start))] += e.seconds(within: interval)
            return d
        }
        for (seriesID, occurrences) in Dictionary(grouping: events.filter { $0.seriesMasterID != nil }, by: { $0.seriesMasterID! }) {
            let sorted = occurrences.sorted { $0.startAt < $1.startAt }
            guard let first = sorted.first, let last = sorted.last else { continue }
            var perDay = Array(repeating: 0.0, count: dayCount)
            var openPerDay = perDay
            var open = 0.0, total = 0.0
            var shares: [Share: Double] = [:]
            for e in sorted {
                let secs = e.seconds(within: interval)
                let attribution = m.attribute(event: e)
                // An occurrence ignored on its own is its own row and not part
                // of the series' time; a series ignore covers every occurrence.
                if case .ignored(.event) = attribution {
                    var clipped = e
                    clipped.startAt = max(e.startAt, interval.start)
                    clipped.endAt = min(e.endAt, interval.end)
                    rows.append(ReviewRow(unit: .event(clipped), status: .ignored, perDay: eventDays(e), belowThreshold: false))
                    continue
                }
                total += secs
                let day = dayIndex(max(e.startAt, interval.start))
                perDay[day] += secs
                switch attribution {
                case .unattributed: open += secs; openPerDay[day] += secs
                case .ignored: break
                case .attributed(let c, let p, let src):
                    shares[Share(customerID: c.id, projectID: p?.id, scope: src == .series ? "Series" : "This meeting"), default: 0] += secs
                }
            }
            let ignoredWholeSeries = m.seriesAttributionsByID[seriesID]?.isIgnored == true
            let st: ReviewRow.Status
            if open > 0 { st = .open }
            else if ignoredWholeSeries { st = .ignored }
            else if let top = shares.max(by: { $0.value < $1.value }), let cid = top.key.customerID {
                st = .attributed(customerID: cid, projectID: top.key.projectID, scope: shares.count > 1 ? "Mixed" : top.key.scope)
            } else { continue }   // every occurrence was ignored on its own: each is already listed
            let seconds = st == .open ? open : total
            let unit = ReviewUnit.series(.init(seriesMasterID: seriesID, sampleSubject: first.subject,
                                               occurrenceCount: sorted.count, totalSeconds: seconds,
                                               firstStartAt: first.startAt, lastStartAt: last.startAt))
            rows.append(ReviewRow(unit: unit, status: st, perDay: st == .open ? openPerDay : perDay,
                                  belowThreshold: st == .open && seconds < minSec))
        }
        for var event in events where event.seriesMasterID == nil {
            let perDay = eventDays(event)
            let secs = event.seconds(within: interval)
            let st: ReviewRow.Status
            switch m.attribute(event: event) {
            case .unattributed: st = .open
            case .ignored: st = .ignored
            case .attributed(let c, let p, _): st = .attributed(customerID: c.id, projectID: p?.id, scope: "This meeting")
            }
            event.startAt = max(event.startAt, interval.start)
            event.endAt = min(event.endAt, interval.end)
            rows.append(ReviewRow(unit: .event(event), status: st, perDay: perDay, belowThreshold: st == .open && secs < minSec))
        }

        // Ad-hoc calls: mic time minus the meetings each session *is*, mirroring
        // the Calls tab, so a huddle can be attributed from Review too.
        if !micSessions.isEmpty {
            let owned = CalendarEvent.meetingMicSessionIDs(events: extendedEvents, micSessions: micSessions, matcher: m)
            for session in micSessions {
                guard let endedAt = session.endedAt, endedAt > session.startedAt else { continue }
                let adHoc = CallSegment.adHocRanges(
                    of: session, endedAt: endedAt, events: extendedEvents,
                    owned: owned, minimumSeconds: 30
                ).reduce(0.0) { $0 + max(0, min($1.end, interval.end).timeIntervalSince(max($1.start, interval.start))) }
                guard adHoc > 0 else { continue }
                var perDay = Array(repeating: 0.0, count: dayCount)
                perDay[dayIndex(max(session.startedAt, interval.start))] = adHoc
                let st: ReviewRow.Status
                if session.isIgnored { st = .ignored }
                else {
                    let r = m.attribute(micSession: session)
                    if let c = r.customer {
                        st = .attributed(customerID: c.id, projectID: r.project?.id,
                                         scope: r.matchingRule == nil ? "Pinned" : ReviewQueue.scopeLabel(r.matchingRule))
                    } else { st = .open }
                }
                rows.append(ReviewRow(unit: .call(session: session, seconds: adHoc), status: st,
                                      perDay: perDay, belowThreshold: st == .open && adHoc < minSec))
            }
        }
        return rows
    }

    /// Aggregate review backlog across the current week plus the previous
    /// `weeksBack` weeks. The always-on surfaces (menu-bar glance) use this so
    /// "all reviewed" reflects *every* recent week — a stray huddle left
    /// unattributed last week no longer hides behind a clean current week.
    struct Rolling {
        var totalCount: Int = 0
        var totalSeconds: Double = 0
        var currentWeekCount: Int = 0
        /// Open time in the current week only (the tray's week line).
        var currentWeekSeconds: Double = 0
        var earlierCount: Int = 0
        /// Start of the oldest week (within the window) that still has open
        /// items — where Review should land so you clear the backlog tail first.
        /// nil when nothing is open anywhere in the window.
        var oldestOpenWeekStart: Date?
    }

    /// Default look-back window for the "any open backlog?" surfaces (menu-bar
    /// glance, Review's landing week). Kept in one place so they agree.
    static let defaultBacklogWeeksBack = 4

    static func rolling(database: AppDatabase,
                        now: Date,
                        weeksBack: Int,
                        sampleIntervalSeconds: Int,
                        idleThresholdSeconds: TimeInterval,
                        minMinutes: Int) throws -> Rolling {
        let cal = Calendar.weekStartingMonday()
        let currentStart = cal.currentWeekInterval(reference: now).start
        var result = Rolling()
        // Walk oldest → newest. A call or meeting crossing a week boundary is
        // queued in both weeks (each clipped), so each unit id is counted once
        // and the oldest week owns it — Review still lands where the backlog
        // tail begins. Seconds stay summed: the clipped parts are disjoint.
        var seen = Set<String>()
        for w in stride(from: max(0, weeksBack), through: 0, by: -1) {
            guard let start = cal.date(byAdding: .day, value: -7 * w, to: currentStart) else { continue }
            let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
            let units = try build(database: database,
                                  interval: DateInterval(start: start, end: end),
                                  sampleIntervalSeconds: sampleIntervalSeconds,
                                  idleThresholdSeconds: idleThresholdSeconds,
                                  minMinutes: minMinutes)
            result.totalSeconds += units.reduce(0) { $0 + $1.totalSeconds }
            // Every unit's time counts here, including ones an earlier week
            // already owns for the count — a repo open last week and this week
            // still has this week's hours open.
            if w == 0 { result.currentWeekSeconds = units.reduce(0) { $0 + $1.totalSeconds } }
            let fresh = units.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            result.totalCount += fresh.count
            if w == 0 { result.currentWeekCount += fresh.count } else { result.earlierCount += fresh.count }
            if result.oldestOpenWeekStart == nil { result.oldestOpenWeekStart = start }
        }
        return result
    }
}
