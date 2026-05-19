import Foundation

/// Date filter used by Discover and Calls. Either a rolling window of the last
/// N days ending now, or a single calendar day (matching the Timeline's UX).
enum DateScope: Equatable, Hashable {
    case lastDays(Int)
    case day(Date)

    static let presetDayCounts: [Int] = [7, 14, 30]

    /// Half-open [start, end) interval ready to feed into database queries.
    var interval: DateInterval {
        let cal = Calendar.current
        switch self {
        case .lastDays(let n):
            let end = Date()
            let start = cal.date(byAdding: .day, value: -n, to: end) ?? end
            return DateInterval(start: start, end: end)
        case .day(let d):
            let start = cal.startOfDay(for: d)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        }
    }

    var isDay: Bool {
        if case .day = self { return true }
        return false
    }
}
