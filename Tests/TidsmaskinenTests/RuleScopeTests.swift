import XCTest
@testable import Tidsmaskinen

/// Tests for time-bounded rules: how the matcher resolves conflicts
/// (most-precise window wins) and how `upsertReplacingWindow` keeps layered
/// rules for the same signal from clobbering each other.
@MainActor
final class RuleScopeTests: XCTestCase {

    private let cal = Calendar.weekStartingMonday()

    // Concrete dates. 2026-04-13 is a Monday → "week 16" of 2026 (Mon 13 – Sun 19).
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private var w16wed: Date { at(2026, 4, 15) }    // Wed of week 16
    private var w16thu: Date { at(2026, 4, 16) }    // Thu of week 16 (different day, same week)
    private var w17wed: Date { at(2026, 4, 22) }    // Wed of week 17

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id.uppercased(), color: nil, createdAt: Date())
    }
    private func project(_ id: String, _ customerID: String) -> Project {
        Project(id: id, customerID: customerID, name: id, color: nil, createdAt: Date())
    }

    /// Build a rule whose validity window comes from the real `AttributionScope`
    /// bounds logic (so these tests also cover bounds() / week math).
    private func rule(_ pattern: String, kind: Rule.Kind = .urlHost,
                      customer: String, project: String? = nil,
                      scope: AttributionScope, reference: Date) -> Rule {
        let (from, to) = scope.bounds(reference: reference)
        return Rule(id: UUID().uuidString, customerID: customer, projectID: project,
                    kind: kind, pattern: pattern, priority: 100, createdAt: Date(),
                    validFrom: from, validTo: to)
    }

    private func matcher(_ rules: [Rule],
                         customers: [Customer] = [],
                         projects: [Project] = []) -> RuleMatcher {
        let custs = customers.isEmpty
            ? ["A", "B", "C"].map { customer($0) } : customers
        return RuleMatcher.make(customers: custs, projects: projects, rules: rules)
    }

    private func host(_ m: RuleMatcher, _ at: Date) -> String? {
        m.attribute(kind: .urlHost, value: "test.com", at: at).customer?.id
    }

    /// In-memory DB seeded with customers A/B/C (rules have a FK on customerID).
    private func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemoryForTesting()
        for id in ["A", "B", "C"] { try db.upsert(customer(id)) }
        return db
    }

    // MARK: - Matcher conflict resolution (most-precise window wins)

    func testPermanentRuleAppliesEveryWeek() {
        let m = matcher([rule("test.com", customer: "A", scope: .always, reference: w16wed)])
        XCTAssertEqual(host(m, w16wed), "A")
        XCTAssertEqual(host(m, w17wed), "A")
    }

    func testWeekRuleOverridesPermanentInsideWindowOnly() {
        let m = matcher([
            rule("test.com", customer: "A", scope: .always, reference: w16wed),
            rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed),
        ])
        XCTAssertEqual(host(m, w16wed), "B", "inside week 16, the week rule wins")
        XCTAssertEqual(host(m, w17wed), "A", "outside week 16, falls back to permanent")
    }

    func testTwoWeekRulesDifferentWeeksCoexist() {
        // The user's scenario: test.com → A for week 16, → B for week 17.
        let m = matcher([
            rule("test.com", customer: "A", scope: .thisWeek, reference: w16wed),
            rule("test.com", customer: "B", scope: .thisWeek, reference: w17wed),
        ])
        XCTAssertEqual(host(m, w16wed), "A")
        XCTAssertEqual(host(m, w17wed), "B")
        XCTAssertNil(host(m, at(2026, 4, 29)), "a week with no rule is unattributed")
    }

    func testTodayBeatsWeekBeatsAlways() {
        let m = matcher([
            rule("test.com", customer: "A", scope: .always, reference: w16wed),
            rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed),
            rule("test.com", customer: "C", scope: .today, reference: w16wed),  // today == Wed w16
        ])
        XCTAssertEqual(host(m, w16wed), "C", "the Wed-only rule is most precise")
        XCTAssertEqual(host(m, w16thu), "B", "other days of week 16 → week rule")
        XCTAssertEqual(host(m, w17wed), "A", "other weeks → permanent")
    }

    func testProjectScopedOverrideSameCustomer() {
        let custs = [customer("A")]
        let projs = [project("p1", "A"), project("p2", "A")]
        let m = matcher([
            rule("test.com", customer: "A", project: "p1", scope: .always, reference: w16wed),
            rule("test.com", customer: "A", project: "p2", scope: .thisWeek, reference: w16wed),
        ], customers: custs, projects: projs)
        XCTAssertEqual(m.attribute(kind: .urlHost, value: "test.com", at: w16wed).project?.id, "p2")
        XCTAssertEqual(m.attribute(kind: .urlHost, value: "test.com", at: w17wed).project?.id, "p1")
    }

    func testNoRuleIsUnattributed() {
        let m = matcher([])
        XCTAssertNil(host(m, w16wed))
    }

    func testLongerPatternWinsOnEqualWindow() {
        // Same kind + same (unbounded) window, different glob specificity.
        let m = matcher([
            rule("test.com/*", kind: .urlPath, customer: "A", scope: .always, reference: w16wed),
            rule("test.com/foo*", kind: .urlPath, customer: "B", scope: .always, reference: w16wed),
        ])
        XCTAssertEqual(m.attribute(kind: .urlPath, value: "test.com/foo/x", at: w16wed).customer?.id, "B",
                       "more specific pattern wins when windows tie")
        XCTAssertEqual(m.attribute(kind: .urlPath, value: "test.com/bar", at: w16wed).customer?.id, "A")
    }

    func testExpiredWeekRuleDoesNotMatchLater() {
        // A "this week" rule for week 16, queried during week 17, must NOT match.
        let m = matcher([rule("test.com", customer: "A", scope: .thisWeek, reference: w16wed)])
        XCTAssertEqual(host(m, w16wed), "A")
        XCTAssertNil(host(m, w17wed), "week-16 rule is not valid in week 17")
    }

    // MARK: - upsertReplacingWindow (DB dedup semantics)

    func testReplaceWindowKeepsDifferentWindows() throws {
        let db = try seededDB()
        try db.upsertReplacingWindow(rule("test.com", customer: "A", scope: .always, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed))
        let rules = try db.allRules().filter { $0.pattern == "test.com" }
        XCTAssertEqual(rules.count, 2, "permanent + this-week rules coexist")
        XCTAssertEqual(rules.first { $0.validFrom == nil }?.customerID, "A")
        XCTAssertEqual(rules.first { $0.validFrom != nil }?.customerID, "B")
    }

    func testReplaceWindowReplacesSameWindow() throws {
        // The user's last example: same signal + same window (week 16), A then B.
        let db = try seededDB()
        try db.upsertReplacingWindow(rule("test.com", customer: "A", scope: .thisWeek, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed))
        let rules = try db.allRules().filter { $0.pattern == "test.com" }
        XCTAssertEqual(rules.count, 1, "same signal + same window → the later replaces the earlier")
        XCTAssertEqual(rules.first?.customerID, "B")
    }

    func testReplaceWindowDifferentWeeksBothKept() throws {
        let db = try seededDB()
        try db.upsertReplacingWindow(rule("test.com", customer: "A", scope: .thisWeek, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "B", scope: .thisWeek, reference: w17wed))
        XCTAssertEqual(try db.allRules().filter { $0.pattern == "test.com" }.count, 2)
    }

    func testReplacingPermanentKeepsTemporary() throws {
        // Re-assigning the permanent rule must not touch a temporary one.
        let db = try seededDB()
        try db.upsertReplacingWindow(rule("test.com", customer: "A", scope: .always, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "C", scope: .always, reference: w16wed)) // re-assign permanent
        let rules = try db.allRules().filter { $0.pattern == "test.com" }
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.first { $0.validFrom == nil }?.customerID, "C", "permanent replaced A→C")
        XCTAssertEqual(rules.first { $0.validFrom != nil }?.customerID, "B", "this-week rule untouched")
    }

    /// End-to-end: build the rules through the DB, load a matcher from it, and
    /// assert the resolved customer per timestamp — the real path the app uses.
    func testLayeredRulesThroughDatabaseAndMatcher() throws {
        let db = try seededDB()
        try db.upsert(customer("A")); try db.upsert(customer("B")); try db.upsert(customer("C"))
        try db.upsertReplacingWindow(rule("test.com", customer: "A", scope: .always, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "B", scope: .thisWeek, reference: w16wed))
        try db.upsertReplacingWindow(rule("test.com", customer: "C", scope: .today, reference: w16wed))
        let m = try RuleMatcher.load(from: db)
        XCTAssertEqual(host(m, w16wed), "C")
        XCTAssertEqual(host(m, w16thu), "B")
        XCTAssertEqual(host(m, w17wed), "A")
    }
}
