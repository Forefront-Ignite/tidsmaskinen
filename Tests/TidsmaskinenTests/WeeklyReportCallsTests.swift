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

    func testDeclinedMeetingDoesNotBillOrAbsorbCalls() {
        let matcher = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        var booking = event("declined", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: "A")
        booking.rsvpStatus = "declined"
        let mic = micSession("call", from: booking.startAt, to: booking.endAt, customerID: "A")
        XCTAssertTrue(CalendarEvent.meetingMicSessionIDs(events: [booking], micSessions: [mic], matcher: matcher).isEmpty)
        let report = WeeklyReport.compute(week: week, samples: [], events: [booking], micSessions: [mic],
                                          matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 1)
        XCTAssertEqual(report.breakdownsByRowID["A"]?.perDay(.events).reduce(0, +), 0)
        XCTAssertEqual(report.breakdownsByRowID["A"]?.perDay(.calls).reduce(0, +), 1)
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

    func testIgnoredSeriesDoesNotAbsorbAttributedCall() {
        let series = MeetingSeriesAttribution(seriesMasterID: "series", customerID: nil,
                                              projectID: nil, isIgnored: true,
                                              updatedAt: Date())
        let matcher = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [], series: [series])
        var booking = event("e1", from: at(2026, 4, 15, 10), to: at(2026, 4, 15, 11), customerID: nil)
        booking.seriesMasterID = "series"
        let mic = micSession("m1", from: at(2026, 4, 15, 9, 30), to: at(2026, 4, 15, 11, 30), customerID: "A")
        let extended = CalendarEvent.withMicOverrun(events: [booking], micSessions: [mic], matcher: matcher)
        XCTAssertEqual(extended.first?.startAt, booking.startAt)
        XCTAssertEqual(extended.first?.endAt, booking.endAt)
        XCTAssertTrue(CalendarEvent.meetingMicSessionIDs(events: extended, micSessions: [mic], matcher: matcher).isEmpty)
        let report = WeeklyReport.compute(week: week, samples: [], events: extended, micSessions: [mic],
                                          matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(report.grandTotal, 2, accuracy: 0.001)

        // An explicitly assigned occurrence still overrides an ignored series.
        booking.customerID = "A"
        XCTAssertEqual(CalendarEvent.meetingMicSessionIDs(events: [booking], micSessions: [mic], matcher: matcher)[booking.id], [mic.id])
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

    /// A call crossing the week boundary is queued in both weeks (clipped), but
    /// the rolling badge counts it once, owned by the earlier week.
    func testRollingBacklogCountsBoundaryCrossingCallOnce() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let now = at(2026, 4, 15, 12)
        let weekStart = cal.currentWeekInterval(reference: now).start
        let id = try db.startMicSession(at: weekStart.addingTimeInterval(-3600), voipApps: [])
        try db.endMicSession(id: id, endedAt: weekStart.addingTimeInterval(3600), participant: nil, slackChannel: nil, voipApps: nil)
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

    /// A Teams meeting joined from the browser records the browser's bundle ID,
    /// not Teams'. That is not evidence of another platform, so the booking must
    /// still own its own audio — otherwise the same hour bills twice.
    func testBrowserJoinedTeamsMeetingStillOwnsItsAudio() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        // Pinned to a different customer, so a failure shows up as a second row
        // rather than being masked by same-bucket dedup.
        let web = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                             customerID: "B", app: "com.google.chrome")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [web],
            matcher: RuleMatcher.make(customers: [customer("A"), customer("B")], projects: [], rules: []),
            sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(rowHours(report, customerID: "B"), 0.0, accuracy: 0.001)
    }

    /// A meeting with no typed provider (in-person, dial-in, a Meet link in the
    /// body) still owns every overlapping session. This is the branch that keeps
    /// behaviour unchanged for most of the calendar — flipping it would make
    /// every untyped meeting double-bill its own audio.
    func testUntypedMeetingStillOwnsForeignPlatformAudio() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14), customerID: "A")
        let slack = micSession("m1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14), customerID: "A")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [slack],
            matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(report.grandTotal, 1.0, accuracy: 0.001)
    }

    /// An ignored meeting (a lunch hold) contributes no time itself, so it must
    /// not absorb a call either — otherwise the call's hours vanish entirely.
    func testIgnoredMeetingDoesNotSwallowCall() {
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [])
        var e = event("e1", from: at(2026, 4, 15, 12), to: at(2026, 4, 15, 13), customerID: nil)
        e.isIgnored = true
        let call = micSession("m1", from: at(2026, 4, 15, 12, 10), to: at(2026, 4, 15, 12, 50),
                              customerID: "A")
        let report = WeeklyReport.compute(
            week: week, samples: [], events: [e], micSessions: [call],
            matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(rowHours(report, customerID: "A"), 0.75, accuracy: 0.001)
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
