import XCTest
@testable import Tidsmaskinen

/// `ReviewQueue.rows` classifies every item of a period, and `build` is
/// exactly its open rows above the threshold.
@MainActor
final class ReviewRowsTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()
    private func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 4, day: day, hour: hour))!
    }
    /// Mon 13 – Sun 19 April 2026.
    private var week: DateInterval { DateInterval(start: at(13, 0), end: at(20, 0)) }

    private func sample(_ when: Date, host: String? = nil, remote: String? = nil,
                        app: String = "com.google.Chrome", title: String? = nil) -> ActivitySample {
        ActivitySample(id: nil, capturedAt: when, appBundleID: app, appName: nil, windowTitle: title,
                       chromeURL: host.map { "https://\($0)/x/y" }, chromeHost: host,
                       gitRepoPath: nil, gitRemoteURL: remote, isIdle: false,
                       customerID: nil, projectID: nil)
    }

    func testRowsClassifyOpenAttributedIgnoredAndAmbient() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(Customer(id: "A", name: "A", color: nil, createdAt: Date()))
        // A week-bounded rule for a.com, a hidden host, an app-only sample, an open repo.
        let (from, to) = AttributionScope.thisWeek.bounds(reference: at(15, 12))
        try db.upsert(Rule(id: "r1", customerID: "A", projectID: nil, kind: .urlHost, pattern: "a.com",
                           priority: 100, createdAt: Date(), validFrom: from, validTo: to))
        try db.hideSignal(kind: .urlHost, value: "hidden.com")
        for i in 0..<40 {   // 40 × 15 s = 10 min each, above the 5-minute threshold
            let t = at(15, 10).addingTimeInterval(Double(i) * 15)
            _ = try db.insert(sample(t, host: "a.com"))
            _ = try db.insert(sample(t, host: "hidden.com"))
            _ = try db.insert(sample(t, app: "com.openai.chat"))
            _ = try db.insert(sample(t, remote: "git@github.com:acme/repo.git", app: "com.microsoft.VSCode"))
        }
        _ = try db.insert(sample(at(16, 9), host: "short.com"))   // 15 s: below the threshold

        let rows = try ReviewQueue.rows(database: db, interval: week, sampleIntervalSeconds: 15,
                                        idleThresholdSeconds: 300, minMinutes: 5)
        func row(_ id: String) -> ReviewRow? { rows.first { $0.id == id } }

        XCTAssertEqual(row("sig:urlHost:a.com")?.status, .attributed(customerID: "A", projectID: nil, scope: "This week"))
        XCTAssertEqual(row("sig:urlHost:hidden.com")?.status, .ignored)
        XCTAssertEqual(row("sig:appBundleID:com.openai.chat")?.status, .ambient)
        XCTAssertEqual(row("sig:gitRepoSlug:acme/repo")?.status, .open)
        XCTAssertEqual(row("sig:urlHost:short.com")?.status, .open)
        XCTAssertEqual(row("sig:urlHost:short.com")?.belowThreshold, true)
        // Everything above landed on Wednesday, the third day of the week.
        XCTAssertEqual(row("sig:gitRepoSlug:acme/repo")?.perDay.enumerated().filter { $0.element > 0 }.map(\.offset), [2])
        XCTAssertEqual(row("sig:gitRepoSlug:acme/repo")?.totalSeconds, 600)

        // The backlog is exactly the open rows above the threshold.
        let backlog = try ReviewQueue.build(database: db, interval: week, sampleIntervalSeconds: 15,
                                            idleThresholdSeconds: 300, minMinutes: 5)
        XCTAssertEqual(backlog.map(\.id), ["sig:gitRepoSlug:acme/repo"])
    }

    /// Evidence: consecutive samples on a signal form a stretch, a gap over two
    /// minutes starts a new one, an open row lists only its open stretches, and
    /// each stretch names the title seen most.
    func testRowsCarryLongestStretchesAsEvidence() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(Customer(id: "A", name: "A", color: nil, createdAt: Date()))
        let remote = "git@github.com:acme/repo.git"
        // Wednesday 10:00: 20 samples (5 min) — "main.swift" 12×, "README" 8×.
        for i in 0..<20 {
            _ = try db.insert(sample(at(15, 10).addingTimeInterval(Double(i) * 15), remote: remote,
                                     app: "com.microsoft.VSCode", title: i < 12 ? "main.swift" : "README"))
        }
        // Wednesday 11:00: 8 samples (2 min) after a gap.
        for i in 0..<8 {
            _ = try db.insert(sample(at(15, 11).addingTimeInterval(Double(i) * 15), remote: remote,
                                     app: "com.microsoft.VSCode", title: "tests.swift"))
        }
        // Thursday: 40 attributed samples (a manual override) — not evidence for an open row.
        for i in 0..<40 {
            var s = sample(at(16, 9).addingTimeInterval(Double(i) * 15), remote: remote, app: "com.microsoft.VSCode", title: "other")
            s.customerID = "A"
            _ = try db.insert(s)
        }
        let rows = try ReviewQueue.rows(database: db, interval: week, sampleIntervalSeconds: 15,
                                        idleThresholdSeconds: 300, minMinutes: 5)
        let repo = try XCTUnwrap(rows.first { $0.id == "sig:gitRepoSlug:acme/repo" })
        XCTAssertEqual(repo.status, .open)
        XCTAssertEqual(repo.evidence.map(\.seconds), [300, 120])
        XCTAssertEqual(repo.evidence.map(\.detail), ["main.swift", "tests.swift"])
        XCTAssertEqual(repo.evidence.first?.start, at(15, 10))
        XCTAssertEqual(repo.evidence.first?.end, at(15, 10).addingTimeInterval(20 * 15))
    }
}
