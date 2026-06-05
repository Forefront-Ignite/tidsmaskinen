import XCTest
@testable import Tidsmaskinen

/// Tests for `WeeklyReport.activeHours` — distinct wall-clock working time, the
/// union of every attributed bucket's covered seconds. Parallel work on two
/// customers in the same minute sums into `grandTotal` (you report it to both)
/// but counts once here.
@MainActor
final class WeeklyReportActiveHoursTests: XCTestCase {

    private let cal = Calendar.weekStartingMonday()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var week: DateInterval { cal.currentWeekInterval(reference: at(2026, 4, 15, 12)) }

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id.uppercased(), color: nil, createdAt: Date())
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

    /// Sequential, non-overlapping work on two customers: active time equals the
    /// tracked total because nothing overlaps.
    func testSequentialWorkActiveEqualsGrand() {
        let m = RuleMatcher.make(customers: [customer("A"), customer("B")], projects: [], rules: [])
        let a = event("a", from: at(2026, 4, 15, 9), to: at(2026, 4, 15, 10), customerID: "A")
        let b = event("b", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "B")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [a, b], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 2.0, accuracy: 0.001)
        XCTAssertEqual(report.activeHours, 2.0, accuracy: 0.001)
    }

    /// Fully-parallel work on two customers (same hour): tracked total is 2h
    /// (reported to both), but only 1h of actual wall-clock time elapsed.
    func testFullyParallelWorkCollapses() {
        let m = RuleMatcher.make(customers: [customer("A"), customer("B")], projects: [], rules: [])
        let a = event("a", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        let b = event("b", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "B")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [a, b], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 2.0, accuracy: 0.001)
        XCTAssertEqual(report.activeHours, 1.0, accuracy: 0.001)
    }

    /// Partial overlap: A 10:00–11:00, B 10:30–11:30. Tracked = 2h, but the
    /// union spans only 10:00–11:30 = 1.5h of distinct active time.
    func testPartialOverlapUnion() {
        let m = RuleMatcher.make(customers: [customer("A"), customer("B")], projects: [], rules: [])
        let a = event("a", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        let b = event("b", from: at(2026, 4, 15, 10, 30), to: at(2026, 4, 15, 11, 30), customerID: "B")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [a, b], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 2.0, accuracy: 0.001)
        XCTAssertEqual(report.activeHours, 1.5, accuracy: 0.001)
    }

    /// Unattributed time never inflates active hours — it's excluded just like
    /// it's excluded from `grandTotal`.
    func testUnattributedExcludedFromActive() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let a = event("a", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        let u = event("u", from: at(2026, 4, 15, 14), to: at(2026, 4, 15, 15), customerID: nil)
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [a, u], matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 1.0, accuracy: 0.001)
        XCTAssertEqual(report.activeHours, 1.0, accuracy: 0.001)
    }
}
