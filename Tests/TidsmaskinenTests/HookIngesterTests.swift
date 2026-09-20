import XCTest
@testable import Tidsmaskinen

@MainActor
final class HookIngesterTests: XCTestCase {
    var db: AppDatabase!
    var ingester: HookIngester!
    private var previousIdleThreshold: Any?

    /// idleThreshold used throughout: default is 5 minutes (300s). Pin it so the
    /// gap-capping assertions are deterministic regardless of the host's saved settings.
    let idleThresholdSeconds: TimeInterval = 300

    override func setUp() async throws {
        try await super.setUp()
        previousIdleThreshold = AppSettings.defaults.object(forKey: SettingsKey.claudeIdleThresholdMinutes)
        AppSettings.defaults.set(5, forKey: SettingsKey.claudeIdleThresholdMinutes)
        db = try AppDatabase.inMemoryForTesting()
        ingester = HookIngester(database: db)
    }

    override func tearDown() async throws {
        if let previousIdleThreshold {
            AppSettings.defaults.set(previousIdleThreshold, forKey: SettingsKey.claudeIdleThresholdMinutes)
        } else {
            AppSettings.defaults.removeObject(forKey: SettingsKey.claudeIdleThresholdMinutes)
        }
        try await super.tearDown()
    }

    // MARK: helpers

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func line(_ eventType: String, _ ts: Date, sessionID: String = "sess-1") -> String {
        // cwd/transcript left null so the test never touches the filesystem / git.
        """
        {"timestamp":"\(iso(ts))","eventType":"\(eventType)","payload":{"session_id":"\(sessionID)"}}
        """
    }

    private func session(_ id: String = "sess-1") throws -> ClaudeSession? {
        try db.session(id: id)
    }

    /// Insert a session that was already closed (as sleep-finalization would leave it).
    private func seedClosedSession(
        id: String = "sess-1",
        startedAt: Date,
        endedAt: Date,
        lastActivityAt: Date,
        activeSeconds: Double,
        promptCount: Int
    ) throws {
        let s = ClaudeSession(
            id: id,
            cwd: nil,
            transcriptPath: nil,
            gitRepoPath: nil,
            gitRemoteURL: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            lastActivityAt: lastActivityAt,
            activeSeconds: activeSeconds,
            promptCount: promptCount,
            customerID: nil,
            projectID: nil,
            createdAt: startedAt,
            updatedAt: endedAt
        )
        try db.upsertSession(s)
    }

    // MARK: the bug — continuing yesterday's sleep-closed session this morning

    func testUserPromptResurrectsSleepClosedSession() throws {
        let yesterdayStart = Date(timeIntervalSince1970: 1_700_000_000) // some fixed point
        let yesterdayLast = yesterdayStart.addingTimeInterval(3600)     // 1h of work
        let sleepClose = yesterdayLast.addingTimeInterval(idleThresholdSeconds)
        try seedClosedSession(
            startedAt: yesterdayStart,
            endedAt: sleepClose,
            lastActivityAt: yesterdayLast,
            activeSeconds: 3600 + idleThresholdSeconds, // 1h + the trailing idle sleep-finalize billed
            promptCount: 4
        )

        // The next morning the user types a new prompt in the SAME session.
        let thisMorning = yesterdayStart.addingTimeInterval(16 * 3600)
        ingester.handleLine(line("UserPromptSubmit", thisMorning))

        let s = try XCTUnwrap(try session())
        XCTAssertNil(s.endedAt, "session must be reopened on continuation")
        XCTAssertEqual(s.promptCount, 5, "the new prompt must be counted")
        XCTAssertEqual(s.lastActivityAt, thisMorning, "activity advances to this morning")
        // The overnight gap must NOT be billed (no ghost idle chunk).
        XCTAssertEqual(s.activeSeconds, 3600 + idleThresholdSeconds, accuracy: 0.001,
                       "resurrection must not bill the sleep span")
    }

    func testSessionStartResurrectsSleepClosedSession() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try seedClosedSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            lastActivityAt: start.addingTimeInterval(300),
            activeSeconds: 300,
            promptCount: 1
        )
        let later = start.addingTimeInterval(20 * 3600)
        ingester.handleLine(line("SessionStart", later))

        let s = try XCTUnwrap(try session())
        XCTAssertNil(s.endedAt, "SessionStart on a closed id reopens it")
        XCTAssertEqual(s.startedAt, start, "startedAt is preserved for an existing session")
        XCTAssertEqual(s.activeSeconds, 300, accuracy: 0.001, "no ghost gap billed")
    }

    // MARK: stale terminating events for a closed session are still dropped

    func testLateSessionEndOnClosedSessionIsIgnored() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let close = start.addingTimeInterval(600)
        try seedClosedSession(
            startedAt: start,
            endedAt: close,
            lastActivityAt: start.addingTimeInterval(300),
            activeSeconds: 300,
            promptCount: 1
        )
        // A SessionEnd queued during sleep arrives much later.
        ingester.handleLine(line("SessionEnd", start.addingTimeInterval(20 * 3600)))

        let s = try XCTUnwrap(try session())
        XCTAssertEqual(s.endedAt, close, "endedAt must be unchanged")
        XCTAssertEqual(s.activeSeconds, 300, accuracy: 0.001, "no second ghost gap billed")
    }

    func testLateStopOnClosedSessionIsIgnored() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let close = start.addingTimeInterval(600)
        try seedClosedSession(
            startedAt: start,
            endedAt: close,
            lastActivityAt: start.addingTimeInterval(300),
            activeSeconds: 300,
            promptCount: 1
        )
        ingester.handleLine(line("Stop", start.addingTimeInterval(20 * 3600)))

        let s = try XCTUnwrap(try session())
        XCTAssertEqual(s.endedAt, close)
        XCTAssertEqual(s.activeSeconds, 300, accuracy: 0.001)
    }

    // MARK: no regression for live sessions

    func testOpenSessionStillBillsGapWithinThreshold() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        ingester.handleLine(line("SessionStart", t0))
        ingester.handleLine(line("UserPromptSubmit", t0.addingTimeInterval(60)))

        let s = try XCTUnwrap(try session())
        XCTAssertNil(s.endedAt)
        XCTAssertEqual(s.promptCount, 1)
        XCTAssertEqual(s.activeSeconds, 60, accuracy: 0.001, "60s gap billed normally")
    }

    func testOpenSessionGapCappedAtThreshold() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        ingester.handleLine(line("SessionStart", t0))
        // 10-minute gap, threshold is 5 minutes → only 300s billed.
        ingester.handleLine(line("UserPromptSubmit", t0.addingTimeInterval(600)))

        let s = try XCTUnwrap(try session())
        XCTAssertEqual(s.activeSeconds, idleThresholdSeconds, accuracy: 0.001,
                       "gap is capped at the idle threshold")
    }

    func testResurrectedSessionBillsSubsequentGapFromMorning() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try seedClosedSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            lastActivityAt: start.addingTimeInterval(300),
            activeSeconds: 300,
            promptCount: 1
        )
        let morning = start.addingTimeInterval(20 * 3600)
        ingester.handleLine(line("UserPromptSubmit", morning))            // resurrect, no bill
        ingester.handleLine(line("UserPromptSubmit", morning.addingTimeInterval(120))) // +2min

        let s = try XCTUnwrap(try session())
        XCTAssertNil(s.endedAt)
        XCTAssertEqual(s.promptCount, 3)
        XCTAssertEqual(s.activeSeconds, 300 + 120, accuracy: 0.001,
                       "after resurrection, gaps bill from this morning's activity")
    }
    func testCodexLifecycleUsesSeparateIDAndSharedAccounting() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func codex(_ event: String, _ seconds: Double) {
            let raw = line(event, start.addingTimeInterval(seconds))
            ingester.handleLine(raw.replacingOccurrences(of: "\"payload\":", with: "\"provider\":\"codex\",\"payload\":"))
        }
        ingester.handleLine(line("SessionStart", start))
        codex("SessionStart", 0)
        codex("UserPromptSubmit", 30)
        codex("Interrupt", 90)
        codex("UserPromptSubmit", 120)
        codex("Stop", 720) // gap capped at 300s
        codex("SessionEnd", 720)
        let captured = try XCTUnwrap(try session("codex:sess-1"))
        XCTAssertEqual(captured.provider, .codex)
        XCTAssertEqual(captured.promptCount, 2)
        XCTAssertEqual(captured.activeSeconds, 420, accuracy: 0.001)
        XCTAssertEqual(captured.endedAt, start.addingTimeInterval(720))
        let legacy = try XCTUnwrap(try session())
        XCTAssertEqual(legacy.provider, .claude)
        XCTAssertEqual(legacy.promptCount, 0)
        XCTAssertEqual(legacy.activeSeconds, 0)
        let deltas = try db.claudeActiveDeltas(in: DateInterval(start: start, duration: 1000))
        XCTAssertEqual(deltas.reduce(0) { $0 + $1.gainedSeconds }, 420, accuracy: 0.001)
        XCTAssertTrue(deltas.allSatisfy { $0.sessionID == captured.id })
    }

    func testCodexActivityReachesTimelineAndWeeklyReport() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (event, offset) in [("SessionStart", 0.0), ("UserPromptSubmit", 60.0), ("SessionEnd", 180.0)] {
            let raw = line(event, start.addingTimeInterval(offset))
            ingester.handleLine(raw.replacingOccurrences(of: "\"payload\":", with: "\"provider\":\"codex\",\"payload\":"))
        }
        let customer = Customer(id: "customer", name: "Customer", color: nil, createdAt: start)
        try db.upsert(customer)
        try db.setClaudeSessionAttribution(sessionID: "codex:sess-1", customerID: customer.id, projectID: nil)
        let captured = try XCTUnwrap(try session("codex:sess-1"))
        let day = Calendar.current.dateInterval(of: .day, for: start)!
        let deltas = try db.claudeActiveDeltas(in: day)
        let matcher = RuleMatcher.make(customers: [customer], projects: [], rules: [])
        let timeline = TimelineBuilder.build(day: day, samples: [], events: [], sessions: [captured],
                                             claudeDeltas: deltas, matcher: matcher, sampleIntervalSeconds: 15,
                                             claudeIdleThresholdSeconds: 300)
        XCTAssertEqual(timeline.claudeCode.count, 1)
        XCTAssertTrue(timeline.claudeCode[0].title.hasPrefix("Codex ·"))
        XCTAssertEqual(timeline.claudeCode[0].attribution.customer?.id, customer.id)
        let week = Calendar.weekStartingMonday().currentWeekInterval(reference: start)
        let report = WeeklyReport.compute(week: week, samples: [], sessions: [captured], claudeDeltas: deltas,
                                          matcher: matcher, sampleIntervalSeconds: 15)
        // The grid rounds to quarter hours; activeHours retains precise time.
        XCTAssertEqual(report.activeHours, 180.0 / 3600, accuracy: 0.001)
        XCTAssertEqual(report.rows.count, 1)
        let contributors = report.breakdownsByRowID.values.flatMap { $0.topContributors }
        XCTAssertEqual(contributors.first?.kindLabel, "Codex")
    }

    func testInvalidProviderOrTimestampDoesNotCreateSession() throws {
        ingester.handleLine(#"{"timestamp":"invalid","eventType":"SessionStart","provider":"codex","payload":{"session_id":"bad"}}"#)
        ingester.handleLine(#"{"timestamp":"2026-09-08T12:00:00Z","eventType":"SessionStart","provider":"unknown","payload":{"session_id":"bad"}}"#)
        XCTAssertNil(try session("codex:bad"))
        XCTAssertNil(try session("bad"))
    }

    func testCappedGapStaysAtStartOfIdlePeriod() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        ingester.handleLine(line("SessionStart", start))
        ingester.handleLine(line("UserPromptSubmit", start.addingTimeInterval(24 * 3600)))
        let deltas = try db.claudeActiveDeltas(in: DateInterval(start: start, duration: 48 * 3600))
        let delta = try XCTUnwrap(deltas.first)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(delta.gainedSeconds, 300)
        XCTAssertEqual(delta.occurredAt, start.addingTimeInterval(300),
                       "an overnight gap must not move yesterday's activity into today")
    }

    func testOutOfOrderEventCannotRewindAndRebillActivity() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        ingester.handleLine(line("SessionStart", start))
        ingester.handleLine(line("Stop", start.addingTimeInterval(120)))
        ingester.handleLine(line("UserPromptSubmit", start.addingTimeInterval(60)))
        ingester.handleLine(line("SessionEnd", start.addingTimeInterval(180)))
        let captured = try XCTUnwrap(try session())
        XCTAssertEqual(captured.activeSeconds, 180)
        XCTAssertEqual(captured.lastActivityAt, start.addingTimeInterval(180))
        let deltas = try db.claudeActiveDeltas(in: DateInterval(start: start, duration: 1000))
        XCTAssertEqual(deltas.reduce(0) { $0 + $1.gainedSeconds }, 180)
    }

}
