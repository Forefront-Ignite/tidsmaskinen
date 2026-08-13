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
        let owned = CalendarEvent.meetingMicSessionIDs(events: [e], micSessions: [frag])
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
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [huddle])
        XCTAssertEqual(out[0].endAt, at(2026, 4, 15, 14))
    }

    /// The meeting's own audio still stretches it — that is the whole point of
    /// withMicOverrun and nothing tested it before.
    func testOwnedAudioStillStretchesMeeting() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13, 50), to: at(2026, 4, 15, 14, 20),
                               customerID: nil, app: "com.microsoft.teams2")
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [teams])
        XCTAssertEqual(out[0].endAt, at(2026, 4, 15, 14, 20))
    }

    /// ...but only on real participation: a 60s brush past the end is flicker,
    /// not an overrun, so the 120s stretch floor still holds.
    func testBrushingOverrunDoesNotStretchMeeting() {
        let e = event("e1", from: at(2026, 4, 15, 13), to: at(2026, 4, 15, 14),
                      customerID: "A", provider: "teamsForBusiness")
        let teams = micSession("m1", from: at(2026, 4, 15, 13, 59), to: at(2026, 4, 15, 14, 30),
                               customerID: nil, app: "com.microsoft.teams2")
        let out = CalendarEvent.withMicOverrun(events: [e], micSessions: [teams])
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
