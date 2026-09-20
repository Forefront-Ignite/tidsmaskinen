import XCTest
@testable import Tidsmaskinen

@MainActor
final class DateScopeTests: XCTestCase {
    func testHistoricDayAnchorsAttributionBounds() throws {
        let calendar = Calendar.weekStartingMonday()
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 13, hour: 12)))
        let scope = DateScope.day(selected)
        let (start, end) = AttributionScope.today.bounds(reference: scope.referenceDate)
        XCTAssertEqual(start, calendar.startOfDay(for: selected))
        XCTAssertEqual(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selected)))
        let (weekStart, weekEnd) = AttributionScope.thisWeek.bounds(reference: scope.referenceDate)
        XCTAssertEqual(weekStart, calendar.dateInterval(of: .weekOfYear, for: selected)?.start)
        XCTAssertEqual(weekEnd, calendar.dateInterval(of: .weekOfYear, for: selected)?.end)
    }
}
