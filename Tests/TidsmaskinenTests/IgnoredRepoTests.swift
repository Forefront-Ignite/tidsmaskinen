import XCTest
@testable import Tidsmaskinen

@MainActor
final class IgnoredRepoTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()
    private let privateRemote = "git@github.com:Personal/private.git"
    private let workRemote = "https://github.com/Personal/work.git"

    private var start: Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 10))!
    }
    private var week: DateInterval { cal.currentWeekInterval(reference: start) }

    private func sample(_ remote: String?, offset: TimeInterval = 0,
                        customerID: String? = nil) -> ActivitySample {
        ActivitySample(id: nil, capturedAt: start.addingTimeInterval(offset),
                       appBundleID: "com.microsoft.VSCode", appName: "Code",
                       windowTitle: "Editor", chromeURL: nil, chromeHost: nil,
                       gitRepoPath: remote.flatMap { RuleMatcher.gitSlug(fromRemote: $0) }.map { "/tmp/\($0)" },
                       gitRemoteURL: remote, isIdle: false,
                       customerID: customerID, projectID: nil)
    }

    private func session(_ id: String, remote: String, offset: TimeInterval = 0,
                         customerID: String? = nil) -> ClaudeSession {
        let at = start.addingTimeInterval(offset)
        return ClaudeSession(id: id, cwd: "/tmp/project", transcriptPath: nil,
                             gitRepoPath: "/tmp/project", gitRemoteURL: remote,
                             startedAt: at, endedAt: at.addingTimeInterval(1800),
                             lastActivityAt: at.addingTimeInterval(1800), activeSeconds: 1800,
                             promptCount: 1, customerID: customerID, projectID: nil,
                             createdAt: at, updatedAt: at)
    }

    private func queue(_ db: AppDatabase, interval: DateInterval? = nil) throws -> [ReviewUnit] {
        try ReviewQueue.build(database: db, interval: interval ?? week,
                              sampleIntervalSeconds: 900, idleThresholdSeconds: 300,
                              minMinutes: 0)
    }

    private func report(_ db: AppDatabase) throws -> WeeklyReport {
        try WeeklyReport.compute(week: week, samples: db.samples(in: week),
                                 sessions: db.sessions(in: week),
                                 claudeDeltas: db.claudeActiveDeltas(in: week),
                                 matcher: RuleMatcher.load(from: db), sampleIntervalSeconds: 900)
    }

    func testIgnorePersistsAndMatchesRepoAcrossRemoteFormats() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.hideSignal(kind: .gitRepoSlug, value: " Personal/private \n")
        try db.hideSignal(kind: .gitRepoSlug, value: "personal/PRIVATE")
        let records = try db.allHiddenSignals()
        XCTAssertEqual(records.count, 1, "Ignoring the same repo twice is idempotent")
        let matcher = try RuleMatcher.load(from: db)
        XCTAssertTrue(matcher.isRepoIgnored(remoteURL: privateRemote))
        XCTAssertTrue(matcher.isRepoIgnored(remoteURL: "https://github.com/personal/private.git"))
        XCTAssertFalse(matcher.isRepoIgnored(remoteURL: workRemote))
        XCTAssertFalse(matcher.isRepoIgnored(remoteURL: "git@github.com:Personal/private-tools.git"))
        XCTAssertFalse(matcher.isRepoIgnored(remoteURL: nil))

        try db.unhide(id: XCTUnwrap(records.first).id)
        XCTAssertFalse(try RuleMatcher.load(from: db).isRepoIgnored(remoteURL: privateRemote))
    }

    func testReviewExcludesSampleAndAgentReposAcrossWeeksUntilRestored() throws {
        let db = try AppDatabase.inMemoryForTesting()
        _ = try db.insert(sample(privateRemote))
        _ = try db.insert(sample(workRemote, offset: 900))
        try db.upsertSession(session("private-agent", remote: privateRemote))
        try db.upsertSession(session("agent-only", remote: "git@github.com:Personal/agent-only.git"))
        let nextWeek = DateInterval(start: week.end, duration: week.duration)
        _ = try db.insert(sample(privateRemote, offset: 7 * 86400))
        let initial = try queue(db)
        XCTAssertEqual(Set(initial.map(\.title)), ["Personal/private", "Personal/work", "Personal/agent-only"])
        XCTAssertTrue(try XCTUnwrap(initial.first { $0.title == "Personal/private" }).canIgnore)

        try db.hideSignal(kind: .gitRepoSlug, value: "personal/private")
        try db.hideSignal(kind: .gitRepoSlug, value: "Personal/agent-only")
        XCTAssertEqual(try queue(db).map(\.title), ["Personal/work"])
        XCTAssertTrue(try queue(db, interval: nextWeek).isEmpty)

        for ignored in try db.allHiddenSignals() { try db.unhide(id: ignored.id) }
        XCTAssertEqual(Set(try queue(db).map(\.title)), Set(initial.map(\.title)))
        XCTAssertEqual(try queue(db, interval: nextWeek).map(\.title), ["Personal/private"])
        XCTAssertEqual(try db.samples(in: week).count, 2, "Ignoring keeps captured history")
        XCTAssertEqual(try db.sessions(in: week).count, 2)
    }

    func testReportExcludesPrivateSamplesAndBothAgentAccountingPathsDespiteAttribution() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(Customer(id: "work", name: "Work", color: nil, createdAt: start))
        let rules = [
            Rule(id: "repo", customerID: "work", projectID: nil, kind: .gitRepoSlug,
                 pattern: "Personal/*", priority: 100, createdAt: start),
            Rule(id: "app", customerID: "work", projectID: nil, kind: .appBundleID,
                 pattern: "com.microsoft.VSCode", priority: 100, createdAt: start)
        ]
        for rule in rules { try db.upsert(rule) }
        _ = try db.insert(sample(privateRemote, customerID: "work"))
        _ = try db.insert(sample(workRemote, offset: 900))
        _ = try db.insert(sample(nil, offset: 1800))
        try db.upsertSession(session("delta", remote: privateRemote, offset: 3600, customerID: "work"))
        try db.insertClaudeActiveDelta(sessionID: "delta", occurredAt: start.addingTimeInterval(5400),
                                       gainedSeconds: 1800)
        var legacy = session("legacy", remote: privateRemote, offset: 7200)
        legacy.provider = .codex
        try db.upsertSession(legacy)
        try db.upsertSession(session("work-agent", remote: workRemote, offset: 10800))

        let before = try report(db)
        XCTAssertEqual(before.grandTotal, 2.25, accuracy: 0.001)
        try db.hideSignal(kind: .gitRepoSlug, value: "Personal/private")
        let ignored = try report(db)
        XCTAssertEqual(ignored.grandTotal, 1.0, accuracy: 0.001)
        XCTAssertEqual(ignored.activeHours, 1.0, accuracy: 0.001)
        XCTAssertEqual(ignored.unattributedTotal, 0)
        let contributors = try XCTUnwrap(ignored.breakdownsByRowID.values.first).topContributors
        XCTAssertFalse(contributors.contains { $0.label.lowercased().contains("personal/private") })
        XCTAssertEqual(try db.allRules().count, rules.count)

        try db.unhide(id: XCTUnwrap(db.allHiddenSignals().first).id)
        let restored = try report(db)
        XCTAssertEqual(restored.grandTotal, before.grandTotal)
        XCTAssertEqual(restored.activeHours, before.activeHours)
    }

    func testIgnoredUnattributedRepoDoesNotInflateUnattributedHours() throws {
        let db = try AppDatabase.inMemoryForTesting()
        _ = try db.insert(sample(privateRemote))
        try db.upsertSession(session("private", remote: privateRemote, offset: 3600))
        XCTAssertEqual(try report(db).unattributedTotal, 0.75, accuracy: 0.001)
        try db.hideSignal(kind: .gitRepoSlug, value: "Personal/private")
        let ignored = try report(db)
        XCTAssertEqual(ignored.unattributedTotal, 0)
        XCTAssertTrue(ignored.rows.isEmpty)
    }

    func testTimelineHidesBothRepoTracksAndShowHiddenRestoresThem() throws {
        let db = try AppDatabase.inMemoryForTesting()
        _ = try db.insert(sample(privateRemote))
        _ = try db.insert(sample(workRemote, offset: 900))
        try db.upsertSession(session("private", remote: privateRemote, offset: 3600))
        try db.upsertSession(session("work", remote: workRemote, offset: 7200))
        try db.insertClaudeActiveDelta(sessionID: "private", occurredAt: start.addingTimeInterval(5400),
                                       gainedSeconds: 1800)
        try db.hideSignal(kind: .gitRepoSlug, value: "Personal/private")
        let day = try XCTUnwrap(cal.dateInterval(of: .day, for: start))
        func timeline(showHidden: Bool) throws -> TimelineBuilder.DayBundle {
            try TimelineBuilder.build(day: day, samples: db.samples(in: day), events: [],
                                      sessions: db.sessions(in: day), claudeDeltas: db.claudeActiveDeltas(in: day),
                                      matcher: RuleMatcher.load(from: db), sampleIntervalSeconds: 900,
                                      claudeIdleThresholdSeconds: 300, includeIgnoredRepos: showHidden)
        }
        let visible = try timeline(showHidden: false)
        XCTAssertEqual(visible.foreground.count, 1)
        XCTAssertEqual(visible.claudeCode.count, 1)
        XCTAssertEqual(visible.foreground.first?.ruleSignal?.pattern, "Personal/work")
        XCTAssertEqual(visible.claudeCode.first?.ruleSignal?.pattern, "Personal/work")
        let all = try timeline(showHidden: true)
        XCTAssertEqual(all.foreground.count, 2)
        XCTAssertEqual(all.claudeCode.count, 2)
    }
}
