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

    /// Build all three tracks for a given day.
    static func build(day: DateInterval,
                      samples: [ActivitySample],
                      events: [CalendarEvent],
                      sessions: [ClaudeSession],
                      matcher: RuleMatcher,
                      sampleIntervalSeconds: Int,
                      claudeIdleThresholdSeconds: TimeInterval) -> DayBundle {

        // ---- Calendar ----
        let calendarBlocks: [TimelineBlock] = events.compactMap { event -> TimelineBlock? in
            let clippedStart = max(event.startAt, day.start)
            let clippedEnd = min(event.endAt, day.end)
            guard clippedEnd > clippedStart else { return nil }
            let eventAttribution = matcher.attribute(event: event)
            // Ignored events are not drawn on the timeline at all.
            if eventAttribution.isIgnored { return nil }
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
        let claudeBlocks: [TimelineBlock] = sessions.compactMap { session -> TimelineBlock? in
            // For open sessions, cap the rendered end at lastActivityAt + idleThreshold so
            // a session that idled overnight (no SessionEnd received before sleep) doesn't
            // visually paint the whole sleep window as work.
            let inferredEnd: Date = {
                if let last = session.lastActivityAt {
                    return max(session.startedAt, last.addingTimeInterval(claudeIdleThresholdSeconds))
                }
                return session.startedAt
            }()
            let sessionEnd = session.endedAt ?? inferredEnd
            let clippedStart = max(session.startedAt, day.start)
            let clippedEnd = min(sessionEnd, day.end)
            guard clippedEnd > clippedStart else { return nil }
            let attribution = matcher.attribute(session: session)
            let override = (session.customerID != nil)
            let titlePath = session.gitRepoPath ?? session.cwd ?? "(no cwd)"
            let title = (titlePath as NSString).lastPathComponent
            let subtitle = session.gitRemoteURL ?? session.cwd
            return TimelineBlock(
                id: "ses-\(session.id)",
                track: .claudeCode,
                source: .claudeSession(id: session.id),
                startedAt: clippedStart,
                endedAt: clippedEnd,
                title: title,
                subtitle: subtitle,
                attribution: attribution,
                eventAttribution: nil,
                hasManualOverride: override,
                isIdle: !session.isActive(idleThresholdSeconds: claudeIdleThresholdSeconds) && session.endedAt == nil,
                appBundleID: nil,
                seriesMasterID: nil
            )
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
                seriesMasterID: nil
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
