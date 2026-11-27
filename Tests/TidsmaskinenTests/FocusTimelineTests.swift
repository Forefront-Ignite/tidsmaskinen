import XCTest
@testable import Tidsmaskinen

/// The report bills one focus timeline: booked meetings own their slot,
/// samples fill the rest once, and agent samples go through their session.
@MainActor
final class FocusTimelineTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()

    private func at(_ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h, minute: mi, second: s))!
    }

    private var week: DateInterval { cal.currentWeekInterval(reference: at(12)) }

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id, color: nil, createdAt: Date())
    }

    private func event(_ id: String, _ from: Date, _ to: Date, customer: String?, rsvp: String = "accepted",
                       allDay: Bool = false, ignored: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, iCalUID: nil, subject: id, bodyPreview: nil,
                      startAt: from, endAt: to, isAllDay: allDay,
                      organizerEmail: nil, organizerName: nil, rsvpStatus: rsvp,
                      isOnlineMeeting: false, onlineMeetingProvider: nil, attendeeDomainsCSV: nil,
                      location: nil, verifiedAttended: false, customerID: customer, projectID: nil,
                      eventType: "singleInstance", seriesMasterID: nil, isIgnored: ignored,
                      createdAt: Date(), updatedAt: Date())
    }

    private func samples(from: Date, minutes: Int, app: String = "com.example.app", customer: String? = nil,
                         session: String? = nil, remote: String? = nil) -> [ActivitySample] {
        (0..<(minutes * 4)).map { i in
            ActivitySample(id: nil, capturedAt: from.addingTimeInterval(Double(i) * 15), appBundleID: app,
                           appName: nil, windowTitle: nil, chromeURL: nil, chromeHost: nil,
                           gitRepoPath: nil, gitRemoteURL: remote, isIdle: false,
                           customerID: customer, projectID: nil, agentSessionID: session)
        }
    }

    private func hours(_ r: WeeklyReport, _ id: String) -> Double {
        r.rows.first { $0.id == id }?.rawPerDayHours.reduce(0, +) ?? 0
    }

    private let matcher = RuleMatcher.make(customers: ["A", "B", "C"].map { Customer(id: $0, name: $0, color: nil, createdAt: Date()) },
                                           projects: [], rules: [])

    // MARK: - Meetings

    func testAcceptedMeetingBeatsTentativeInTheOverlap() {
        let a = event("a", at(10), at(11), customer: "A")
        let b = event("b", at(10, 30), at(11, 30), customer: "B", rsvp: "tentativelyAccepted")
        let r = WeeklyReport.compute(week: week, samples: [], events: [a, b], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(hours(r, "B"), 0.5, accuracy: 0.001)
        XCTAssertTrue(r.doubleBookings.isEmpty)
    }

    func testTwoAcceptedMeetingsBothBillUntilTheUserPicksOne() {
        let a = event("a", at(10), at(11), customer: "A")
        let b = event("b", at(10, 30), at(11, 30), customer: "B")
        let open = WeeklyReport.compute(week: week, samples: [], events: [a, b], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(open, "A") + hours(open, "B"), 2.0, accuracy: 0.001)
        XCTAssertEqual(open.doubleBookings.map(\.id), [MeetingOverlapChoice.pairKey("a", "b")])
        XCTAssertFalse(open.doubleBookings[0].isResolved)

        let choice = MeetingOverlapChoice("b", "a", winner: "a")
        let resolved = WeeklyReport.compute(week: week, samples: [], events: [a, b], overlapChoices: [choice],
                                            matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(resolved, "A"), 1.0, accuracy: 0.001)
        XCTAssertEqual(hours(resolved, "B"), 0.5, accuracy: 0.001)
        XCTAssertTrue(resolved.doubleBookings[0].isResolved)

        let both = WeeklyReport.compute(week: week, samples: [], events: [a, b],
                                        overlapChoices: [MeetingOverlapChoice("a", "b", winner: nil)],
                                        matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(both, "A") + hours(both, "B"), 2.0, accuracy: 0.001)
    }

    func testDeclinedAllDayAndIgnoredMeetingsBillNothingAndBlockNothing() {
        let declined = event("d", at(9), at(10), customer: "A", rsvp: "declined")
        let allDay = event("h", at(0), at(23, 59), customer: "A", allDay: true)
        let ignored = event("i", at(14), at(15), customer: "A", ignored: true)
        let work = samples(from: at(9), minutes: 60, customer: "B") + samples(from: at(14), minutes: 60, customer: "B")
        let r = WeeklyReport.compute(week: week, samples: work, events: [declined, allDay, ignored],
                                     matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "A"), 0)
        XCTAssertEqual(hours(r, "B"), 2.0, accuracy: 0.001)
    }

    // MARK: - Samples

    func testAMeetingOwnsItsSlotAndSamplesFillTheRest() {
        let meeting = event("m", at(10), at(10, 30), customer: "A")
        let work = samples(from: at(10), minutes: 60, customer: "B")
        let r = WeeklyReport.compute(week: week, samples: work, events: [meeting], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "A"), 0.5, accuracy: 0.001)
        XCTAssertEqual(hours(r, "B"), 0.5, accuracy: 0.001)
        XCTAssertEqual(r.activeHours, 1.0, accuracy: 0.001)
    }

    func testASampleEndsWhereTheNextOneStarts() {
        // Two apps sampled 10 s apart with a 15 s interval: 10 s + 15 s, not 30 s.
        let first = ActivitySample(id: nil, capturedAt: at(9), appBundleID: "x", appName: nil, windowTitle: nil,
                                   chromeURL: nil, chromeHost: nil, gitRepoPath: nil, gitRemoteURL: nil,
                                   isIdle: false, customerID: "A", projectID: nil)
        var second = first
        second.capturedAt = at(9, 0, 10)
        second.customerID = "B"
        let r = WeeklyReport.compute(week: week, samples: [first, second], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "A") * 3600, 10, accuracy: 0.01)
        XCTAssertEqual(hours(r, "B") * 3600, 15, accuracy: 0.01)
    }

    // MARK: - Agent sessions

    func testAgentSampleBillsToItsSessionRepoAtTheSampleTime() {
        let remote = "git@github.com:Acme/api.git"
        let weekRule = Rule(id: "r", customerID: "A", projectID: nil, kind: .gitRepoSlug, pattern: "Acme/api",
                            priority: 100, createdAt: Date(), validFrom: week.start, validTo: week.end)
        let session = ClaudeSession(id: "s1", cwd: "/r", transcriptPath: nil, gitRepoPath: "/r", gitRemoteURL: remote,
                                    // Last active next week: the rule must be checked at the sample's time.
                                    startedAt: at(9), endedAt: nil, lastActivityAt: week.end.addingTimeInterval(3600),
                                    activeSeconds: 0, promptCount: 1, customerID: nil, projectID: nil,
                                    createdAt: Date(), updatedAt: Date())
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [weekRule], sessions: [session])
        let work = samples(from: at(9), minutes: 30, app: ClaudeFocusLog.bundleID, session: "s1")
        let r = WeeklyReport.compute(week: week, samples: work, matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "A"), 0.5, accuracy: 0.001)
        XCTAssertEqual(r.breakdownsByRowID["A"]?.topContributors.first?.label, "Acme/api")
    }

    func testManualAssignmentBeatsSessionPinWhichBeatsRules() {
        var pinned = ClaudeSession(id: "s1", cwd: nil, transcriptPath: nil, gitRepoPath: nil, gitRemoteURL: nil,
                                   startedAt: at(9), endedAt: nil, lastActivityAt: nil, activeSeconds: 0,
                                   promptCount: 0, customerID: "B", projectID: nil, createdAt: Date(), updatedAt: Date())
        let appRule = Rule(id: "app", customerID: "C", projectID: nil, kind: .appBundleID,
                           pattern: ClaudeFocusLog.bundleID, priority: 100, createdAt: Date())
        let m = RuleMatcher.make(customers: ["A", "B", "C"].map(customer), projects: [], rules: [appRule], sessions: [pinned])
        let sample = samples(from: at(9), minutes: 1, app: ClaudeFocusLog.bundleID, session: "s1")[0]
        XCTAssertEqual(m.attribute(sample).customer?.id, "B")
        var manual = sample
        manual.customerID = "A"
        XCTAssertEqual(m.attribute(manual).customer?.id, "A")
        // A session nothing covers falls through to the app's own rules.
        pinned.customerID = nil
        let unpinned = RuleMatcher.make(customers: ["A", "B", "C"].map(customer), projects: [], rules: [appRule], sessions: [pinned])
        XCTAssertEqual(unpinned.attribute(sample).customer?.id, "C")
    }

    func testIgnoredSessionRepoBillsNothing() {
        let remote = "git@github.com:Personal/private.git"
        let session = ClaudeSession(id: "s1", cwd: nil, transcriptPath: nil, gitRepoPath: nil, gitRemoteURL: remote,
                                    startedAt: at(9), endedAt: nil, lastActivityAt: nil, activeSeconds: 0,
                                    promptCount: 0, customerID: "A", projectID: nil, createdAt: Date(), updatedAt: Date())
        let hidden = HiddenSignal(id: "h", kind: .gitRepoSlug, value: "Personal/private", hiddenAt: Date())
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [], hiddenSignals: [hidden], sessions: [session])
        let r = WeeklyReport.compute(week: week, samples: samples(from: at(9), minutes: 30, app: ClaudeFocusLog.bundleID, session: "s1"),
                                     matcher: m, sampleIntervalSeconds: 15)
        XCTAssertEqual(r.grandTotal, 0)
        XCTAssertEqual(r.unattributedTotal, 0)
    }
}
