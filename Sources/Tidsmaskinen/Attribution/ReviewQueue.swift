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
        var baseAggs = try database.signalAggregates(in: interval, sampleIntervalSeconds: sampleIntervalSeconds)
        // Fold Claude session activity into git-repo aggregates (as Discover does).
        let sessionRepos = try database.sessionRepoAggregates(in: interval, idleThresholdSeconds: idleThresholdSeconds)
        if !sessionRepos.isEmpty {
            var bySlug: [String: Double] = [:]
            var others: [AppDatabase.SignalAggregate] = []
            for agg in baseAggs {
                if agg.kind == .gitRepoSlug { bySlug[agg.value, default: 0] += agg.totalSeconds }
                else { others.append(agg) }
            }
            for s in sessionRepos { bySlug[s.value, default: 0] += s.totalSeconds }
            baseAggs = others + bySlug.map { AppDatabase.SignalAggregate(kind: .gitRepoSlug, value: $0.key, totalSeconds: $0.value) }
        }

        let allCustomers = try database.allCustomers()
        let allProjects = try database.allProjects()
        let rules = try database.allRules()
        let seriesAttrs = try database.allMeetingSeriesAttributions()
        let m = RuleMatcher.make(customers: allCustomers, projects: allProjects, rules: rules, series: seriesAttrs)
        let hidden = try database.allHiddenSignals()
        let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
        let hiddenPaths = Set(hidden.filter { $0.kind == .urlPath }.map { $0.value })

        let series = try database.meetingSeriesAggregates(in: interval)
        let oneOffs = try database.oneOffMeetingAggregates(in: interval)
        let seriesByID = Dictionary(uniqueKeysWithValues: seriesAttrs.map { ($0.seriesMasterID, $0) })

        let minSec = Double(minMinutes) * 60
        // Evaluate "is this already attributed?" in the reviewed period's
        // temporal context, so a rule bounded to that week/day still counts
        // (a rule for last week isn't treated as expired just because it's
        // not valid "now").
        let at = interval.start
        var built: [ReviewUnit] = []

        for agg in baseAggs {
            switch agg.kind {
            case .gitRepoSlug:
                if agg.totalSeconds < minSec { continue }
                if m.attribute(kind: .gitRepoSlug, value: agg.value, at: at).customer == nil {
                    built.append(.signal(agg))
                }
            case .appBundleID:
                // Apps are intentionally not reviewable — e.g. VS Code can't be
                // mapped to a single customer. They still attribute via repo/URL.
                continue
            case .urlHost:
                if agg.totalSeconds < minSec { continue }
                if hiddenHosts.contains(agg.value) { continue }
                if m.attribute(kind: .urlHost, value: agg.value, at: at).customer != nil { continue }
                // High limit so a host's unattributed time surfaces as assignable
                // paths rather than being orphaned beyond the default top-N cap.
                let paths = (try? database.urlPathAggregates(forHost: agg.value, in: interval, sampleIntervalSeconds: sampleIntervalSeconds, limit: 60)) ?? []
                let openPaths = paths.filter {
                    $0.totalSeconds >= minSec
                        && m.attribute(kind: .urlPath, value: $0.value, at: at).customer == nil
                        && !hiddenPaths.contains($0.value)
                }
                if openPaths.count >= 1 {
                    built.append(.hostGroup(host: agg, paths: openPaths))
                } else if paths.isEmpty {
                    built.append(.signal(agg))   // host with no path detail → assign whole host
                }
            case .urlPath:
                break
            }
        }

        for s in series where s.totalSeconds >= minSec {
            let attr = seriesByID[s.seriesMasterID]
            if attr?.isIgnored == true { continue }
            if attr?.customerID == nil { built.append(.series(s)) }
        }
        for e in oneOffs where e.customerID == nil {
            if max(0, e.endAt.timeIntervalSince(e.startAt)) >= minSec { built.append(.event(e)) }
        }

        built.sort { $0.totalSeconds > $1.totalSeconds }
        return built
    }
}
