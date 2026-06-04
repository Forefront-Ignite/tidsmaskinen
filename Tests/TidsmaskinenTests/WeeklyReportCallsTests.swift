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

    private func micSession(_ id: String, from: Date, to: Date, customerID: String?) -> MicSession {
        MicSession(id: id, startedAt: from, endedAt: to, voipAppsCSV: "com.tinyspeck.slackmacgap",
                   participant: nil, slackChannel: nil, customerID: customerID, projectID: nil,
                   createdAt: Date(), updatedAt: Date())
    }

    private func event(_ id: String, from: Date, to: Date, customerID: String?) -> CalendarEvent {
        CalendarEvent(id: id, iCalUID: nil, subject: "Meeting", bodyPreview: nil,
                      startAt: from, endAt: to, isAllDay: false,
                      organizerEmail: nil, organizerName: nil, rsvpStatus: "accepted",
                      isOnlineMeeting: false, onlineMeetingProvider: nil, attendeeDomainsCSV: nil,
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
}
