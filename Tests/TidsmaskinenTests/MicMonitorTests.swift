import XCTest
@testable import Tidsmaskinen

@MainActor
final class MicMonitorTests: XCTestCase {
    func testSleepClosesCurrentSessionAndDoesNotCloseItAgainOnStop() throws {
        let database = try AppDatabase.inMemoryForTesting()
        let monitor = MicMonitor(database: database)
        var closed: [MicSession] = []
        monitor.onSessionEnd = { closed.append($0) }
        let before = Date()
        monitor.beginSession(with: [MicMonitor.Recorder(
            pid: 0, ownerPID: 0, bundleID: "com.microsoft.teams2", appName: "Teams"
        )])

        monitor.handleSleep()
        let afterSleep = Date()
        let sessions = try database.micSessions(
            // SQLite stores millisecond timestamps; avoid an empty boundary
            // when this synthetic session begins and ends in the same millisecond.
            in: DateInterval(start: before.addingTimeInterval(-1), end: afterSleep.addingTimeInterval(1)),
            minDurationSeconds: 0
        )
        let session = try XCTUnwrap(sessions.first)
        let endedAt = try XCTUnwrap(session.endedAt)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertGreaterThanOrEqual(endedAt, session.startedAt)
        XCTAssertLessThanOrEqual(endedAt, afterSleep.addingTimeInterval(0.001))
        XCTAssertEqual(closed.count, 1)

        monitor.handleSleep()
        monitor.stop()
        XCTAssertEqual(closed.count, 1, "sleep must clear session state before wake or shutdown")
    }
}
