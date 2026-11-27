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

    func testCallAndRuleSaveRollsBackTogether() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(customer("A"))
        let id = try db.startMicSession(at: at(2026, 4, 15, 10), voipApps: [])
        let invalidRule = Rule(id: "invalid", customerID: "missing", projectID: nil,
                               kind: .slackChannel, pattern: "channel", priority: 100, createdAt: Date())
        XCTAssertThrowsError(try db.setMicSessionAttribution(id: id, customerID: "A", projectID: nil, rule: invalidRule))
        XCTAssertNil(try db.micSessions(in: week).first?.customerID)
        XCTAssertTrue(try db.allRules().isEmpty)
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

    func testMicQueryIncludesBoundaryCrossingCalls() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let start = at(2026, 4, 15, 0)
        let interval = DateInterval(start: start, duration: 86400)
        let crossing = try db.startMicSession(at: start.addingTimeInterval(-1800), voipApps: [])
        try db.endMicSession(id: crossing, endedAt: start.addingTimeInterval(1800), participant: nil, slackChannel: nil, voipApps: nil)
        let before = try db.startMicSession(at: start.addingTimeInterval(-3600), voipApps: [])
        try db.endMicSession(id: before, endedAt: start, participant: nil, slackChannel: nil, voipApps: nil)
        XCTAssertEqual(try db.micSessions(in: interval).map(\.id), [crossing])
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

    /// Ownership has no overlap floor: a fragment of a meeting's own audio that
    /// overlaps by less than the 120s *stretch* threshold is still the meeting's,
    /// so it gets subtracted instead of surfacing as a phantom ad-hoc call in the
    /// Calls tab and a nag in Review. The weekly report cannot see this — 60s
    /// rounds to 0.00h — so assert on the segmentation directly.
    func testShortTeamsFragmentInsideItsMeetingIsOwned() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let frag = micSession("m1", from: at(2026, 4, 15, 13, 30), to: at(2026, 4, 15, 13, 31),
                              customerID: nil, app: "com.microsoft.teams2")
        let owned = CalendarEvent.meetingMicSessionIDs(events: [e], micSessions: [frag], matcher: .make(customers: [], projects: [], rules: []))
        XCTAssertEqual(owned["e1"], ["m1"])
        XCTAssertTrue(CallSegment.adHocRanges(of: frag, endedAt: frag.endedAt!, events: [e],
                                              owned: owned, minimumSeconds: 30).isEmpty)
    }

    /// A foreign-platform call must not stretch a booking. Before, a huddle
    /// running past a Teams meeting dragged that meeting's end out to meet it,
    /// inflating the meeting's customer by the whole huddle.
    func testHuddleDoesNotStretchTeamsMeeting() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let huddle = micSession("m1", from: at(2026, 4, 15, 13, 50), to: at(2026, 4, 15, 14, 20),
                                customerID: nil)
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [huddle], matcher: .make(customers: [], projects: [], rules: []))
        XCTAssertEqual(out[0].endAt, at(2026, 4, 15, 14))
    }

    /// The meeting's own audio still stretches it — that is the whole point of
    /// withMicOverrun and nothing tested it before.
    func testOwnedAudioStillStretchesMeeting() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13, 50), to: at(2026, 4, 15, 14, 20),
                               customerID: nil, app: "com.microsoft.teams2")
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [teams], matcher: .make(customers: [], projects: [], rules: []))
        XCTAssertEqual(out[0].endAt, at(2026, 4, 15, 14, 20))
    }

    /// ...but only on real participation: a 60s brush past the end is flicker,
    /// not an overrun, so the 120s stretch floor still holds.
    func testBrushingOverrunDoesNotStretchMeeting() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13, 59), to: at(2026, 4, 15, 14, 30),
                               customerID: nil, app: "com.microsoft.teams2")
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [teams], matcher: .make(customers: [], projects: [], rules: []))
        XCTAssertEqual(out[0].endAt, at(2026, 4, 15, 14))
    }

}
