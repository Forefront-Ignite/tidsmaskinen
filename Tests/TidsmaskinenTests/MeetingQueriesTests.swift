import XCTest
@testable import Tidsmaskinen

/// Meeting queries and Review agree on meetings that cross a day or week
/// boundary, and on series occurrences assigned or ignored one by one.
@MainActor
final class MeetingQueriesTests: XCTestCase {

    private let cal = Calendar.weekStartingMonday()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var week: DateInterval { cal.currentWeekInterval(reference: at(2026, 4, 15, 12)) }

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id.uppercased(), color: nil, createdAt: Date())
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

    func testReviewDoesNotAskAboutIndividuallyIgnoredOrAssignedSeriesOccurrences() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(customer("A"))
        var assigned = event("assigned", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        assigned.seriesMasterID = "series"
        var ignored = event("ignored", from: at(2026, 4, 16, 10), to: at(2026, 4, 16, 11), customerID: nil)
        ignored.seriesMasterID = "series"
        ignored.isIgnored = true
        try db.upsertEvents([assigned, ignored])
        let queue = try ReviewQueue.build(database: db, interval: week, sampleIntervalSeconds: 15,
                                          idleThresholdSeconds: 300, minMinutes: 5)
        XCTAssertTrue(queue.isEmpty)
    }

    /// A meeting crossing the week boundary is queued in both weeks (clipped),
    /// but the rolling badge counts it once, owned by the earlier week.
    func testRollingBacklogCountsBoundaryCrossingMeetingOnce() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let now = at(2026, 4, 15, 12)
        let weekStart = cal.currentWeekInterval(reference: now).start
        try db.upsertEvents([event("crossing", from: weekStart.addingTimeInterval(-3600),
                                   to: weekStart.addingTimeInterval(3600), customerID: nil)])
        let rolling = try ReviewQueue.rolling(database: db, now: now, weeksBack: 1, sampleIntervalSeconds: 15,
                                              idleThresholdSeconds: 300, minMinutes: 5)
        XCTAssertEqual(rolling.totalCount, 1)
        XCTAssertEqual(rolling.earlierCount, 1)
        XCTAssertEqual(rolling.currentWeekCount, 0)
        XCTAssertEqual(rolling.totalSeconds, 7200, accuracy: 1)
        XCTAssertEqual(rolling.oldestOpenWeekStart, cal.date(byAdding: .day, value: -7, to: weekStart))
    }

    /// Discover's meeting lists agree with Review and the report on a meeting
    /// crossing a day boundary: it appears on both days, clipped to each.
    func testDiscoverMeetingQueriesClipBoundaryCrossingMeetings() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let midnight = at(2026, 4, 15, 0)
        let before = DateInterval(start: midnight.addingTimeInterval(-86400), duration: 86400)
        let after = DateInterval(start: midnight, duration: 86400)
        let oneOff = event("one-off", from: midnight.addingTimeInterval(-1800), to: midnight.addingTimeInterval(1800), customerID: nil)
        var occurrence = event("occurrence", from: midnight.addingTimeInterval(-3600), to: midnight.addingTimeInterval(1800), customerID: nil)
        occurrence.seriesMasterID = "series"
        var ignored = event("ignored", from: midnight.addingTimeInterval(-900), to: midnight.addingTimeInterval(900), customerID: nil)
        ignored.isIgnored = true
        try db.upsertEvents([oneOff, occurrence, ignored])

        for interval in [before, after] {
            let listed = try XCTUnwrap(db.oneOffMeetingAggregates(in: interval).first)
            XCTAssertEqual(listed.id, "one-off")
            XCTAssertEqual(listed.startAt, oneOff.startAt)   // real bounds, so the row shows the true start
            XCTAssertEqual(listed.seconds(within: interval), 1800, accuracy: 1)
        }
        XCTAssertEqual(try db.meetingSeriesAggregates(in: before).first?.totalSeconds ?? 0, 3600, accuracy: 1)
        XCTAssertEqual(try db.meetingSeriesAggregates(in: after).first?.totalSeconds ?? 0, 1800, accuracy: 1)
        XCTAssertEqual(try db.ignoredMeetingAggregates(in: after).first?.totalSeconds ?? 0, 900, accuracy: 1)
    }

    func testCalendarQueryIncludesBoundaryCrossingEvents() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let start = at(2026, 4, 15, 0)
        let interval = DateInterval(start: start, duration: 86400)
        let crossing = event("crossing", from: start.addingTimeInterval(-1800), to: start.addingTimeInterval(1800), customerID: nil)
        let before = event("before", from: start.addingTimeInterval(-3600), to: start, customerID: nil)
        let after = event("after", from: interval.end, to: interval.end.addingTimeInterval(1800), customerID: nil)
        try db.upsertEvents([crossing, before, after])
        XCTAssertEqual(try db.calendarEvents(in: interval).map(\.id), ["crossing"])
    }

}
