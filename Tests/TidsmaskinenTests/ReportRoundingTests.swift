import XCTest
@testable import Tidsmaskinen

/// Each cell rounds to a quarter hour in the chosen mode, and every day keeps
/// its true total: the residue lands on the day's largest bucket.
@MainActor
final class ReportRoundingTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()

    private func customer(_ id: String) -> Customer {
        Customer(id: id, name: id, color: nil, createdAt: Date())
    }

    /// Three customers with 6, 6 and 12 minutes on Monday of week 16, 2026,
    /// attributed by per-sample overrides so no rules are involved.
    private func report(_ rounding: ReportRounding) -> WeeklyReport {
        let monday = cal.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 9))!
        let week = cal.currentWeekInterval(reference: monday)
        var samples: [ActivitySample] = []
        var id: Int64 = 1
        for (cust, minutes) in [("A", 6), ("B", 6), ("C", 12)] {
            for i in 0..<(minutes * 4) {   // 15 s samples
                samples.append(ActivitySample(id: id, capturedAt: monday.addingTimeInterval(Double(i) * 15 + Double(id) * 0.001),
                                              appBundleID: "app.\(cust)", appName: nil, windowTitle: nil,
                                              chromeURL: nil, chromeHost: nil, gitRepoPath: nil, gitRemoteURL: nil,
                                              isIdle: false, customerID: cust, projectID: nil))
                id += 1
            }
        }
        let matcher = RuleMatcher.make(customers: ["A", "B", "C"].map(customer), projects: [], rules: [])
        return WeeklyReport.compute(week: week, samples: samples, matcher: matcher, sampleIntervalSeconds: 15, rounding: rounding)
    }

    private func monday(_ r: WeeklyReport, _ id: String) -> Double { r.rows.first { $0.id == id }!.perDayHours[0] }

    func testNearestKeepsTheDaysTrueTotal() {
        let r = report(.nearest)
        // 0.1 + 0.1 + 0.2 = 0.4 h → 0.5 h; cells alone would round to 0 + 0 + 0.25.
        XCTAssertEqual(r.dayTotals[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(monday(r, "C"), 0.5, accuracy: 0.001)   // the largest bucket carries the residue
        XCTAssertEqual(monday(r, "A"), 0, accuracy: 0.001)
        XCTAssertEqual(r.rows.first { $0.id == "C" }!.rawPerDayHours[0], 0.2, accuracy: 0.001)
    }

    func testUpAndDownRoundEveryCellInTheirDirection() {
        let up = report(.up)
        // Cells alone would be 0.25 + 0.25 + 0.25 = 0.75; the day's true 0.4 h
        // rounds up to 0.5, so 0.25 comes off the largest bucket.
        XCTAssertEqual(up.dayTotals[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(up.rows.map { $0.perDayHours[0] }.reduce(0, +), up.dayTotals[0], accuracy: 0.001)
        XCTAssertEqual(monday(up, "C"), 0, accuracy: 0.001)
        let down = report(.down)
        XCTAssertEqual(monday(down, "A"), 0, accuracy: 0.001)
        XCTAssertEqual(down.dayTotals[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(monday(down, "C"), 0.25, accuracy: 0.001)
    }
}
