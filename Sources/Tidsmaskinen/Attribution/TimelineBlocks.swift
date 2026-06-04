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
            case .claudeCode:  return "Claude Code"
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

    /// Build all three tracks for a given day. When `includeIgnoredEvents` is
    /// false (the default), ignored calendar events are dropped entirely;
    /// when true, they're emitted so the Timeline can render them faded so
    /// the user can recover from an accidental ignore.
    static func build(day: DateInterval,
                      samples: [ActivitySample],
                      events: [CalendarEvent],
                      sessions: [ClaudeSession],
                      claudeDeltas: [AppDatabase.ClaudeActiveDelta] = [],
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
                seriesMasterID: event.seriesMasterID
            )
        }

        // ---- Foreground (group consecutive same-identity samples) ----
        let foregroundBlocks = groupForeground(samples: samples,
                                               sampleIntervalSeconds: sampleIntervalSeconds,
                                               matcher: matcher)

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
            let title = (titlePath as NSString).lastPathComponent
            let subtitle = session.gitRemoteURL ?? session.cwd

            let claudeSignal: TimelineBlock.RuleSignal? = session.gitRemoteURL
                .flatMap { RuleMatcher.gitSlug(fromRemote: $0) }
                .map { TimelineBlock.RuleSignal(kind: .gitRepoSlug, pattern: $0) }
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
                    ruleSignal: claudeSignal
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
                                        matcher: RuleMatcher) -> [TimelineBlock] {
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
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

        for sample in sorted {
            guard let sid = sample.id else { continue }
            if var prev = groups.last,
               sameBlockIdentity(prev.representative, sample),
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
            let attribution = matcher.attribute(g.representative)
            let override = (g.representative.customerID != nil)
            let title = g.representative.appName ?? g.representative.appBundleID ?? "—"
            let subtitle = representativeSubtitle(for: g.samples)

            // Most-specific signal a rule could attach to: repo > host > app.
            let rep = g.representative
            let signal: TimelineBlock.RuleSignal? = {
                if let url = rep.gitRemoteURL, let slug = RuleMatcher.gitSlug(fromRemote: url) {
                    return TimelineBlock.RuleSignal(kind: .gitRepoSlug, pattern: slug)
                }
                if let host = rep.chromeHost { return TimelineBlock.RuleSignal(kind: .urlHost, pattern: host) }
                if let bid = rep.appBundleID { return TimelineBlock.RuleSignal(kind: .appBundleID, pattern: bid) }
                return nil
            }()

            // Extend the block end by one sample interval so a single-sample
            // block is still visible on the timeline.
            let endedAt = g.last.addingTimeInterval(interval)
            return TimelineBlock(
                id: "fg-\(g.ids.first ?? 0)-\(g.ids.last ?? 0)",
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
                ruleSignal: signal
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
