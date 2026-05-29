import XCTest
@testable import Tidsmaskinen

@MainActor
final class HookIngesterTests: XCTestCase {
    var db: AppDatabase!
    var ingester: HookIngester!

    /// idleThreshold used throughout: default is 5 minutes (300s). Pin it so the
    /// gap-capping assertions are deterministic regardless of the host's saved settings.
    let idleThresholdSeconds: TimeInterval = 300

    override func setUp() async throws {
        try await super.setUp()
        AppSettings.defaults.set(5, forKey: SettingsKey.claudeIdleThresholdMinutes)
        db = try AppDatabase.inMemoryForTesting()
        ingester = HookIngester(database: db)
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
}
