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
/// backlog, so it never inflates the count.
enum ReviewQueue {
    static func build(database: AppDatabase,
                      interval: DateInterval,
                      sampleIntervalSeconds: Int,
                      idleThresholdSeconds: TimeInterval,
                      minMinutes: Int) throws -> [ReviewUnit] {
        let m = try RuleMatcher.load(from: database)
        let hidden = try database.allHiddenSignals()
        let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
        let hiddenPaths = Set(hidden.filter { $0.kind == .urlPath }.map { $0.value })
        let minSec = Double(minMinutes) * 60
        var built: [ReviewUnit] = []

        // Resolve each sample at its actual timestamp before aggregating. A
        // Monday rule cannot hide Tuesday's backlog, and manual assignments or
        // a Wednesday-only rule must clear the activity they actually cover.
        var repos: [String: Double] = [:]
        var hosts: [String: Double] = [:]
        var pathsByHost: [String: [String: Double]] = [:]
        for sample in try database.samples(in: interval) where !sample.isIdle {
            guard !m.isRepoIgnored(remoteURL: sample.gitRemoteURL), m.attribute(sample).customer == nil else { continue }
            let seconds = min(Double(sampleIntervalSeconds), interval.end.timeIntervalSince(sample.capturedAt))
            if let remote = sample.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote) {
                repos[slug, default: 0] += seconds
            } else if let host = sample.chromeHost, !hiddenHosts.contains(host) {
                if let url = sample.chromeURL, let path = RuleMatcher.urlPathPrefix(url) {
                    guard !hiddenPaths.contains(path) else { continue }
                    pathsByHost[host, default: [:]][path, default: 0] += seconds
                }
                hosts[host, default: 0] += seconds
            }
        }
        let sessionSeconds = try database.sessionActiveSeconds(in: interval, idleThresholdSeconds: idleThresholdSeconds)
        for session in try database.sessions(in: interval) {
            guard !m.isRepoIgnored(remoteURL: session.gitRemoteURL),
                  m.attribute(session: session).customer == nil,
                  let remote = session.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: remote),
                  let seconds = sessionSeconds[session.id], seconds > 0 else { continue }
            repos[slug, default: 0] += seconds
        }
        for (slug, seconds) in repos where seconds >= minSec {
            built.append(.signal(.init(kind: .gitRepoSlug, value: slug, totalSeconds: seconds)))
        }
        for (host, seconds) in hosts where seconds >= minSec {
            let aggregate = AppDatabase.SignalAggregate(kind: .urlHost, value: host, totalSeconds: seconds)
            let paths = (pathsByHost[host] ?? [:]).compactMap { path, seconds -> AppDatabase.SignalAggregate? in
                guard seconds >= minSec else { return nil }
                return .init(kind: .urlPath, value: path, totalSeconds: seconds)
            }.sorted { $0.totalSeconds > $1.totalSeconds }
            // Many short paths can collectively be worth reviewing. Keep the
            // host assignable even when no individual path clears the threshold.
            built.append(paths.isEmpty ? .signal(aggregate) : .hostGroup(host: aggregate, paths: paths))
        }

        let rawEvents = try database.calendarEvents(in: interval)
        let unresolved = rawEvents.filter { $0.rsvpStatus != "declined" && m.attribute(event: $0) == .unattributed }
        let recurring = Dictionary(grouping: unresolved.filter { $0.seriesMasterID != nil }, by: { $0.seriesMasterID! })
        for (seriesID, events) in recurring {
            let sorted = events.sorted { $0.startAt < $1.startAt }
            guard let first = sorted.first, let last = sorted.last else { continue }
            let seconds = sorted.reduce(0.0) {
                $0 + max(0, min($1.endAt, interval.end).timeIntervalSince(max($1.startAt, interval.start)))
            }
            guard seconds >= minSec else { continue }
            built.append(.series(.init(seriesMasterID: seriesID, sampleSubject: first.subject,
                                       occurrenceCount: sorted.count, totalSeconds: seconds,
                                       firstStartAt: first.startAt, lastStartAt: last.startAt)))
        }
        for var event in unresolved where event.seriesMasterID == nil {
            event.startAt = max(event.startAt, interval.start)
            event.endAt = min(event.endAt, interval.end)
            if event.endAt.timeIntervalSince(event.startAt) >= minSec {
                built.append(.event(event))
            }
        }

        // Ad-hoc calls: ended mic sessions whose impromptu time (mic minus any
        // mic-extended meeting) clears the threshold and that aren't already
        // attributed (no manual save, no matching Slack-channel rule). This
        // mirrors the Calls tab's segmentation so a huddle or stray Teams call
        // can be attributed from Review instead of being stranded.
        let micSessions = try database.micSessions(in: interval)
        if !micSessions.isEmpty {
            let extendedEvents = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions, matcher: m)
            let owned = CalendarEvent.meetingMicSessionIDs(events: extendedEvents, micSessions: micSessions, matcher: m)
            for session in micSessions {
                guard let endedAt = session.endedAt, endedAt > session.startedAt else { continue }
                if session.isIgnored { continue }                                  // user said don't ask
                if m.attribute(micSession: session).customer != nil { continue }   // already has a home
                let adHoc = CallSegment.adHocRanges(
                    of: session, endedAt: endedAt, events: extendedEvents,
                    owned: owned, minimumSeconds: 30
                ).reduce(0.0) { $0 + max(0, min($1.end, interval.end).timeIntervalSince(max($1.start, interval.start))) }
                if adHoc > 0, adHoc >= minSec { built.append(.call(session: session, seconds: adHoc)) }
            }
        }

        built.sort { $0.totalSeconds > $1.totalSeconds }
        return built
    }

    /// Aggregate review backlog across the current week plus the previous
    /// `weeksBack` weeks. The always-on surfaces (menu-bar glance) use this so
    /// "all reviewed" reflects *every* recent week — a stray huddle left
    /// unattributed last week no longer hides behind a clean current week.
    struct Rolling {
        var totalCount: Int = 0
        var totalSeconds: Double = 0
        var currentWeekCount: Int = 0
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
            let fresh = units.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            result.totalCount += fresh.count
            if w == 0 { result.currentWeekCount += fresh.count } else { result.earlierCount += fresh.count }
            if result.oldestOpenWeekStart == nil { result.oldestOpenWeekStart = start }
        }
        return result
    }
}
