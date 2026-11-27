import XCTest
import GRDB
@testable import Tidsmaskinen

/// Rows of rule kinds this version retired (Slack channel, call participant,
/// window title) stay in the database but must never break loading the rest.
final class RetiredRuleKindsTests: XCTestCase {
    func testRetiredRuleRowsAreSkippedNotFatal() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(Customer(id: "A", name: "A", color: nil, createdAt: Date()))
        try db.upsert(Rule(id: "repo", customerID: "A", projectID: nil, kind: .gitRepoSlug,
                           pattern: "acme/*", priority: 100, createdAt: Date()))
        try db.dbQueue.write { db in
            for (id, kind) in [("slack", "slackChannel"), ("person", "participant"), ("title", "windowTitle")] {
                try db.execute(sql: """
                    INSERT INTO rules (id, customerID, kind, pattern, priority, createdAt)
                    VALUES (?, 'A', ?, 'x', 100, ?)
                    """, arguments: [id, kind, Date()])
            }
        }
        XCTAssertEqual(try db.allRules().map(\.id), ["repo"])
        XCTAssertEqual(try db.rules(forCustomer: "A").map(\.id), ["repo"])
        let matcher = try RuleMatcher.load(from: db)
        XCTAssertEqual(matcher.attribute(kind: .gitRepoSlug, value: "acme/api").customer?.id, "A")
        // The retired rows are kept, not deleted.
        let stored = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM rules") }
        XCTAssertEqual(stored, 4)
    }
}
