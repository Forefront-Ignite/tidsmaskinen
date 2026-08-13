import XCTest
@testable import Tidsmaskinen

/// Tests for ad-hoc call time in the weekly report: an attributed mic session
/// adds hours to its customer, but mic time overlapping a meeting is credited
/// once (via the meeting), never double-counted.
@MainActor
final class WeeklyReportCallsTests: XCTestCase {

    private let cal = Calendar.weekStartingMonday()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var week: DateInterval { cal.currentWeekInterval(reference: at(2026, 4, 15, 12)) }

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id.uppercased(), color: nil, createdAt: Date())
    }

    private func micSession(_ id: String, from: Date, to: Date, customerID: String?,
                            app: String = "com.tinyspeck.slackmacgap") -> MicSession {
        MicSession(id: id, startedAt: from, endedAt: to, voipAppsCSV: app,
                   participant: nil, slackChannel: nil, customerID: customerID, projectID: nil,
                   createdAt: Date(), updatedAt: Date())
    }

    private func event(_ id: String, from: Date, to: Date, customerID: String?,
                       provider: String? = nil) -> CalendarEvent {
        CalendarEvent(id: id, iCalUID: nil, subject: "Meeting", bodyPreview: nil,
                      startAt: from, endAt: to, isAllDay: false,
                      organizerEmail: nil, organizerName: nil, rsvpStatus: "accepted",
                      isOnlineMeeting: provider != nil, onlineMeetingProvider: provider,
                      attendeeDomainsCSV: nil,
                      location: nil, verifiedAttended: false, customerID: customerID, projectID: nil,
                      eventType: "singleInstance", seriesMasterID: nil, isIgnored: false,
                      createdAt: Date(), updatedAt: Date())
    }

    private func rowHours(_ report: WeeklyReport, customerID: String) -> Double {
        report.rows.first { $0.id == customerID }?.totalHours ?? 0
    }

    /// An attributed ad-hoc call with no overlapping meeting contributes its
    /// full duration to its customer.
    func testAttributedCallAddsHours() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let mic = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 13, 30), customerID: "A")
        let report = WeeklyReport.compute(
            week: week, samples: [], micSessions: [mic], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 0.5, accuracy: 0.001)
        XCTAssertEqual(report.grandTotal, 0.5, accuracy: 0.001)
    }

    /// An unattributed call (no manual save, no matching rule) is NOT counted —
    /// it belongs in the Review backlog, not the report totals.
    func testUnattributedCallIsNotCounted() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let mic = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 13, 30), customerID: nil)
        let report = WeeklyReport.compute(
            week: week, samples: [], micSessions: [mic], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 0, accuracy: 0.001)
    }

    /// An ignored call contributes nothing, even when it carries an attribution
    /// (manual save or rule) — ignore wins.
    func testIgnoredCallIsNotCounted() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        var mic = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 13, 30), customerID: "A")
        mic.isIgnored = true
        let report = WeeklyReport.compute(
            week: week, samples: [], micSessions: [mic], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 0, accuracy: 0.001)
    }

    /// Mic time fully inside a meeting is credited once (via the meeting), not
    /// added again as a call — the call's overlap with the meeting is subtracted.
    func testCallOverlappingMeetingIsNotDoubleCounted() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let e = event("e1", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        let mic = micSession("m1", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [mic], matcher: m, sampleIntervalSeconds: 15)
        // 1.0h from the meeting, nothing extra from the fully-overlapping call.
        XCTAssertEqual(rowHours(report, customerID: "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(report.grandTotal, 1.0, accuracy: 0.001)
    }

    /// A Teams meeting that ended early, followed by a Slack huddle for another
    /// customer inside the booked block. The huddle is not the meeting's audio,
    /// so it keeps its full duration and lands on its own customer instead of
    /// being swallowed by the booking.
    func testHuddleDuringTeamsMeetingIsCountedSeparately() {
        let m = RuleMatcher.make(customers: [customer("A"), customer("B")], projects: [], rules: [])
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 15),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 13, 15),
                               customerID: nil, app: "com.microsoft.teams2")
        let huddle = micSession("m2", from: at(2026, 4, 15, 13, 20), to: at(2026, 4, 15, 14, 20),
                                customerID: "B")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [teams, huddle],
            matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 2.0, accuracy: 0.001)
        XCTAssertEqual(rowHours(report, customerID: "B"), 1.0, accuracy: 0.001)
    }

    /// The flip side: a Teams meeting's own Teams audio is still absorbed, so
    /// pinning it can't double-count the booked time.
    func testTeamsAudioInsideTeamsMeetingIsNotDoubleCounted() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 13, 50),
                               customerID: "A", app: "com.microsoft.teams2")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [teams],
            matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(report.grandTotal, 1.0, accuracy: 0.001)
    }
}
