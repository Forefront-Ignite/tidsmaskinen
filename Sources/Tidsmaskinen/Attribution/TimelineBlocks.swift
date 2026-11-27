import Foundation

/// A block on the timeline view. Blocks are computed on-demand from samples /
/// events / sessions and are not persisted as their own table.
struct TimelineBlock: Identifiable {
    enum Track: String, CaseIterable {
        case calendar, foreground, claudeCode

        var label: String {
            switch self {
            case .calendar:    return "Calendar"
            case .foreground:  return "Foreground"
            case .claudeCode:  return "Coding agents"
            }
        }
    }

    enum Source {
        case calendarEvent(id: String)
        case claudeSession(id: String)
        /// Inclusive range of sample IDs (sorted) that make up this foreground block.
        case foregroundSamples(ids: [Int64])
    }

    /// The signal a time-bounded/permanent rule would be built from when the
    /// user reattributes this block with a scope other than "just this block".
    /// nil for calendar blocks (which use event/series attribution) and any
    /// block with no clean signal.
    struct RuleSignal: Equatable { let kind: Rule.Kind; let pattern: String }

    let id: String
    let track: Track
    let source: Source
    let startedAt: Date
    let endedAt: Date
    let title: String          // app name / repo / meeting subject
    let subtitle: String?      // optional secondary line (window title / cwd / attendees)
    let attribution: AttributionResult
    /// For calendar-event blocks: the richer attribution that distinguishes
    /// "attributed via the series rule" from "attributed via the per-event
    /// override". `nil` for foreground and Claude blocks.
    let eventAttribution: EventAttribution?
    let hasManualOverride: Bool
    let isIdle: Bool
    /// Bundle identifier of the underlying app, when known (foreground blocks).
    /// The timeline view uses this to render the real app icon inside the block.
    let appBundleID: String?
    /// Series master id, present on calendar-event blocks that are part of a series.
    let seriesMasterID: String?
    /// Signal for "attribute this signal for today/this week/always" from My day.
    var ruleSignal: RuleSignal? = nil
    /// Ignored meeting, or work in an ignored repo: drawn dimmed and
    /// excluded from the report, never silently dropped from the day.
    var isIgnored: Bool = false

    var durationSeconds: TimeInterval {
        max(1, endedAt.timeIntervalSince(startedAt))
    }
}

enum TimelineBuilder {
    struct DayBundle {
        let calendar: [TimelineBlock]
        let foreground: [TimelineBlock]
        let claudeCode: [TimelineBlock]
    }

    /// The samples My day draws once hidden signals are applied — the same
    /// reading Review gives a hide: an app hide covers only app-only time (no
    /// repo, no site), a host hide covers that site. Repo time is never hidden
    /// here; ignored repos are drawn dimmed instead. Hiding Chrome as an app
    /// used to empty the whole foreground lane, sites included.
    static func visibleSamples(_ samples: [ActivitySample], hidden: [HiddenSignal]) -> [ActivitySample] {
        guard !hidden.isEmpty else { return samples }
        let hiddenApps = Set(hidden.filter { $0.kind == .appBundleID }.map { $0.value })
        let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
        return samples.filter { sample in
            if sample.gitRemoteURL != nil { return true }
            if let host = sample.chromeHost { return !hiddenHosts.contains(host) }
            if let bid = sample.appBundleID { return !hiddenApps.contains(bid) }
            return true
        }
    }

    /// Build the tracks for a given day. When `includeIgnoredEvents` is
    /// false (the default), ignored calendar events are dropped;
    /// when true, they're emitted flagged `isIgnored` so the Timeline can
    /// render them faded and the user can recover from an accidental ignore.
    /// Work in ignored repos is always emitted, flagged `isIgnored`, so the
    /// day stays complete and the repo can be un-ignored from where it shows.
    /// `events` are drawn at their booked times, as the report bills them.
    static func build(day: DateInterval,
                      samples: [ActivitySample],
                      events: [CalendarEvent],
                      sessions: [ClaudeSession],
                      claudeDeltas: [AppDatabase.ClaudeActiveDelta] = [],
                      cellsCalls: [CellsCall] = [],
                      now: Date = Date(),
                      matcher: RuleMatcher,
                      sampleIntervalSeconds: Int,
                      claudeIdleThresholdSeconds: TimeInterval,
                      includeIgnoredEvents: Bool = false) -> DayBundle {

        // ---- Calendar ----
        let calendarBlocks: [TimelineBlock] = events.compactMap { event -> TimelineBlock? in
            let clippedStart = max(event.startAt, day.start)
            let clippedEnd = min(event.endAt, day.end)
            guard clippedEnd > clippedStart else { return nil }
            let eventAttribution = matcher.attribute(event: event)
            if eventAttribution.isIgnored && !includeIgnoredEvents { return nil }
            let override = (event.customerID != nil)
            return TimelineBlock(
                id: "evt-\(event.id)",
                track: .calendar,
                source: .calendarEvent(id: event.id),
                startedAt: clippedStart,
                endedAt: clippedEnd,
                title: event.subject.isEmpty ? "(no subject)" : event.subject,
                subtitle: event.attendeeDomains.isEmpty ? nil : event.attendeeDomains.joined(separator: ", "),
                attribution: eventAttribution.asAttributionResult,
                eventAttribution: eventAttribution,
                hasManualOverride: override,
                isIdle: false,
                appBundleID: nil,
                seriesMasterID: event.seriesMasterID,
                isIgnored: eventAttribution.isIgnored
            )
        }

        // ---- Foreground (group consecutive same-identity samples) ----
        let foregroundBlocks = groupForeground(samples: samples,
                                               sampleIntervalSeconds: sampleIntervalSeconds,
                                               matcher: matcher,
                                               calls: CellsCallIndex(calls: cellsCalls, now: now))

        // ---- Claude Code sessions ----
        // A session spans wall-clock from start to end, but most of that can be
        // idle. When per-event activity deltas are available we render only the
        // ACTIVE spans (merging gaps ≤ idle threshold) so an editor left open
        // since 00:00 doesn't paint the whole day as work. Sessions without
        // deltas fall back to a single capped block.
        let deltasBySession = Dictionary(grouping: claudeDeltas, by: { $0.sessionID })
        let claudeBlocks: [TimelineBlock] = sessions.flatMap { session -> [TimelineBlock] in
            let attribution = matcher.attribute(session: session)
            let override = (session.customerID != nil)
            let titlePath = session.gitRepoPath ?? session.cwd ?? "(no cwd)"
            let title = "\(session.provider.displayName) · \((titlePath as NSString).lastPathComponent)"
            let subtitle = session.gitRemoteURL ?? session.cwd

            let claudeSignal: TimelineBlock.RuleSignal? = session.gitRemoteURL
                .flatMap { RuleMatcher.gitSlug(fromRemote: $0) }
                .map { TimelineBlock.RuleSignal(kind: .gitRepoSlug, pattern: $0) }
            let ignoredRepo = matcher.isRepoIgnored(remoteURL: session.gitRemoteURL)
            func block(_ start: Date, _ end: Date, idSuffix: String, idle: Bool) -> TimelineBlock? {
                let clippedStart = max(start, day.start)
                let clippedEnd = min(end, day.end)
                guard clippedEnd > clippedStart else { return nil }
                return TimelineBlock(
                    id: "ses-\(session.id)\(idSuffix)",
                    track: .claudeCode,
                    source: .claudeSession(id: session.id),
                    startedAt: clippedStart,
                    endedAt: clippedEnd,
                    title: title,
                    subtitle: subtitle,
                    attribution: attribution,
                    eventAttribution: nil,
                    hasManualOverride: override,
                    isIdle: idle,
                    appBundleID: nil,
                    seriesMasterID: nil,
                    ruleSignal: claudeSignal,
                    isIgnored: ignoredRepo
                )
            }

            let deltas = (deltasBySession[session.id] ?? []).sorted { $0.occurredAt < $1.occurredAt }
            if !deltas.isEmpty {
                // Build active intervals [occurredAt - gained, occurredAt], merging
                // those separated by ≤ the idle threshold into one work block.
                var intervals: [(start: Date, end: Date)] = []
                for d in deltas {
                    let s = d.occurredAt.addingTimeInterval(-max(1, d.gainedSeconds))
                    let e = d.occurredAt
                    if var last = intervals.last, s.timeIntervalSince(last.end) <= claudeIdleThresholdSeconds {
                        last.end = max(last.end, e)
                        intervals[intervals.count - 1] = last
                    } else {
                        intervals.append((s, e))
                    }
                }
                return intervals.enumerated().compactMap { i, iv in
                    block(iv.start, iv.end, idSuffix: "-\(i)", idle: false)
                }
            } else {
                // No deltas: cap an open session at lastActivity + idle threshold.
                let inferredEnd: Date = {
                    if let last = session.lastActivityAt {
                        return max(session.startedAt, last.addingTimeInterval(claudeIdleThresholdSeconds))
                    }
                    return session.startedAt
                }()
                let end = session.endedAt ?? inferredEnd
                let idle = !session.isActive(idleThresholdSeconds: claudeIdleThresholdSeconds) && session.endedAt == nil
                return [block(session.startedAt, end, idSuffix: "", idle: idle)].compactMap { $0 }
            }
        }

        return DayBundle(calendar: calendarBlocks,
                         foreground: foregroundBlocks,
                         claudeCode: claudeBlocks)
    }

    private static func groupForeground(samples: [ActivitySample],
                                        sampleIntervalSeconds: Int,
                                        matcher: RuleMatcher,
                                        calls: CellsCallIndex = CellsCallIndex(calls: [])) -> [TimelineBlock] {
        // Cells in front during your call is the call, as the report bills it:
        // not idle, and attributed through the call unless assigned by hand.
        func call(_ s: ActivitySample) -> CellsCall? {
            guard s.customerID == nil, ActivitySample.isCells(s.appBundleID) else { return nil }
            return calls.call(at: s.capturedAt)
        }
        func attribution(_ s: ActivitySample) -> AttributionResult {
            call(s).map(matcher.attribute(cellsCall:)) ?? matcher.attribute(s)
        }
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }.map { s -> ActivitySample in
            guard s.isIdle, call(s) != nil else { return s }
            var active = s
            active.isIdle = false
            return active
        }
        let interval = TimeInterval(sampleIntervalSeconds)
        let maxGap: TimeInterval = max(60, interval * 3)

        struct Acc {
            var ids: [Int64]
            var samples: [ActivitySample]
            var first: Date
            var last: Date
            var representative: ActivitySample
        }
        var groups: [Acc] = []

        // A block is one attribution: a new session, or a rule that starts
        // or ends mid-stretch, starts a new block instead of being labelled
        // by the stretch's first sample.
        func owner(_ s: ActivitySample) -> String {
            let r = attribution(s)
            return "\(r.customer?.id ?? "")/\(r.project?.id ?? "")"
        }
        for sample in sorted {
            guard let sid = sample.id else { continue }
            if var prev = groups.last,
               sameBlockIdentity(prev.representative, sample),
               owner(prev.representative) == owner(sample),
               sample.capturedAt.timeIntervalSince(prev.last) <= maxGap {
                prev.ids.append(sid)
                prev.samples.append(sample)
                prev.last = sample.capturedAt
                groups[groups.count - 1] = prev
            } else {
                groups.append(Acc(ids: [sid],
                                  samples: [sample],
                                  first: sample.capturedAt,
                                  last: sample.capturedAt,
                                  representative: sample))
            }
        }

        return groups.map { g in
            let attribution = attribution(g.representative)
            let override = (g.representative.customerID != nil)
            let title = g.representative.appName ?? g.representative.appBundleID ?? "—"
            let rep = g.representative
            // Claude or Codex in front: the session's repo or folder says what it was.
            let session = matcher.session(for: rep)
            let callChat = call(rep).map { matcher.cellsChatsByID[$0.chatID]?.name ?? "Cells call" }
            let subtitle = callChat.map { "Call · \($0)" } ?? session.flatMap { s in
                s.gitRemoteURL.flatMap(RuleMatcher.gitSlug(fromRemote:))
                    ?? (s.gitRepoPath ?? s.cwd).map { ($0 as NSString).lastPathComponent }
            } ?? representativeSubtitle(for: g.samples)

            // Most-specific signal a rule could attach to: repo > host > app.
            let signal: TimelineBlock.RuleSignal? = {
                if let url = rep.gitRemoteURL ?? session?.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: url) {
                    return TimelineBlock.RuleSignal(kind: .gitRepoSlug, pattern: slug)
                }
                if let host = rep.chromeHost { return TimelineBlock.RuleSignal(kind: .urlHost, pattern: host) }
                if let bid = rep.appBundleID { return TimelineBlock.RuleSignal(kind: .appBundleID, pattern: bid) }
                return nil
            }()

            // Extend the block end by one sample interval so a single-sample
            // block is still visible on the timeline.
            let endedAt = g.last.addingTimeInterval(interval)
            // Keyed on the first sample only: the block still being recorded
            // gains a sample every interval, and an id that moved with it tore
            // its popover down mid-edit.
            return TimelineBlock(
                id: "fg-\(g.ids.first ?? 0)",
                track: .foreground,
                source: .foregroundSamples(ids: g.ids),
                startedAt: g.first,
                endedAt: endedAt,
                title: title,
                subtitle: subtitle,
                attribution: attribution,
                eventAttribution: nil,
                hasManualOverride: override,
                isIdle: g.representative.isIdle,
                appBundleID: g.representative.appBundleID,
                seriesMasterID: nil,
                ruleSignal: signal,
                isIgnored: matcher.isRepoIgnored(sample: rep)
            )
        }
    }

    /// Two samples belong to the same foreground block when their *project-relevant*
    /// identity matches. Window title is deliberately excluded: chat-channel hops
    /// and per-file editor titles would otherwise shred a continuous work session
    /// into dozens of unreadable slivers.
    private static func sameBlockIdentity(_ a: ActivitySample, _ b: ActivitySample) -> Bool {
        a.appBundleID == b.appBundleID
            && a.chromeHost == b.chromeHost
            && a.gitRepoPath == b.gitRepoPath
            && a.isIdle == b.isIdle
            && a.agentSessionID == b.agentSessionID
            && a.customerID == b.customerID
            && a.projectID == b.projectID
    }

    /// Pick something meaningful to show as the block's secondary line.
    /// Order of preference:
    ///   1. shared repo / host across the whole group (true context)
    ///   2. dominant window title (>=40% of samples)
    ///   3. "N contexts" for highly variable sessions
    ///   4. nil when there's nothing useful to add
    private static func representativeSubtitle(for samples: [ActivitySample]) -> String? {
        guard let head = samples.first else { return nil }
        if let repo = head.gitRepoPath {
            return (repo as NSString).lastPathComponent
        }
        if let host = head.chromeHost {
            return host
        }
        let titles = samples.compactMap { $0.windowTitle?.isEmpty == false ? $0.windowTitle : nil }
        guard !titles.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for t in titles { counts[t, default: 0] += 1 }
        if let top = counts.max(by: { $0.value < $1.value }),
           Double(top.value) / Double(titles.count) >= 0.4 {
            return top.key
        }
        let unique = Set(titles).count
        return unique > 1 ? "\(unique) contexts" : titles.first
    }
}
