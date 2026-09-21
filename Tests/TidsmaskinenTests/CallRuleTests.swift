import XCTest
@testable import Tidsmaskinen

/// A call teaches a rule for its Slack channel or, for a 1:1, the other
/// party — and the rule editor's match preview counts what a pattern hits.
@MainActor
final class CallRuleTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()
    private func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 4, day: day, hour: hour))!
    }
    private func customer(_ id: String) -> Customer { Customer(id: id, name: id, color: nil, createdAt: Date()) }
    private func session(participant: String?, channel: String?) -> MicSession {
        MicSession(id: UUID().uuidString, startedAt: at(15, 10), endedAt: at(15, 11), voipAppsCSV: "com.microsoft.teams2",
                   participant: participant, slackChannel: channel, customerID: nil, projectID: nil,
                   createdAt: Date(), updatedAt: Date())
    }

    func testParticipantRuleAttributesOneToOneCalls() {
        let rule = Rule(id: "p", customerID: "A", projectID: nil, kind: .participant, pattern: "Anna *",
                        priority: 100, createdAt: Date())
        let m = RuleMatcher.make(customers: [customer("A")], projects: [], rules: [rule])
        XCTAssertEqual(m.attribute(micSession: session(participant: "Anna Andersson", channel: nil)).customer?.id, "A")
        XCTAssertNil(m.attribute(micSession: session(participant: "Bo Berg", channel: nil)).customer)
        XCTAssertNil(m.attribute(micSession: session(participant: nil, channel: "anna-project")).customer)
    }

    func testLearnableRulePrefersChannelOverParticipant() {
        XCTAssertEqual(session(participant: "Anna", channel: "nfc").learnableRule?.pattern, "nfc")
        XCTAssertEqual(session(participant: "Anna", channel: "nfc").learnableRule?.kind, .slackChannel)
        XCTAssertEqual(session(participant: "Anna", channel: nil).learnableRule?.kind, .participant)
        XCTAssertEqual(session(participant: "Anna", channel: nil).learnableRuleLabel, "calls with Anna")
        XCTAssertNil(session(participant: nil, channel: nil).learnableRule)
    }

    func testRuleMatchCountCountsSamplesAndCalls() throws {
        let db = try AppDatabase.inMemoryForTesting()
        for i in 0..<8 {
            _ = try db.insert(ActivitySample(id: nil, capturedAt: at(15, 10).addingTimeInterval(Double(i) * 15),
                                             appBundleID: "com.google.Chrome", appName: nil, windowTitle: nil,
                                             chromeURL: "https://\(i < 6 ? "app.acme.com" : "other.com")/x",
                                             chromeHost: i < 6 ? "app.acme.com" : "other.com",
                                             gitRepoPath: nil, gitRemoteURL: nil, isIdle: false, customerID: nil, projectID: nil))
        }
        let id = try db.startMicSession(at: at(15, 12), voipApps: ["com.microsoft.teams2"])
        try db.endMicSession(id: id, endedAt: at(15, 13), participant: "Anna Andersson", slackChannel: nil, voipApps: nil)

        let hosts = try db.ruleMatchCount(kind: .urlHost, pattern: "*.acme.com", since: at(1, 0), sampleIntervalSeconds: 15)
        XCTAssertEqual(hosts.sampleSeconds, 90)
        XCTAssertEqual(hosts.calls, 0)
        let calls = try db.ruleMatchCount(kind: .participant, pattern: "Anna *", since: at(1, 0), sampleIntervalSeconds: 15)
        XCTAssertEqual(calls.calls, 1)
        XCTAssertEqual(calls.sampleSeconds, 0)
        XCTAssertTrue(try db.ruleMatchCount(kind: .urlHost, pattern: "nomatch", since: at(1, 0), sampleIntervalSeconds: 15).isEmpty)
        // The window is honoured: nothing before `since`.
        XCTAssertTrue(try db.ruleMatchCount(kind: .urlHost, pattern: "*", since: at(16, 0), sampleIntervalSeconds: 15).isEmpty)
    }
}
