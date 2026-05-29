import SwiftUI

/// Shared date-navigation primitives so every time-scoped view (Weekly Report,
/// Timeline, Discover, Calls) uses the same control treatment, button styles,
/// "jump to now" affordance, and — crucially — the same accessibility labels on
/// the otherwise icon-only chevrons.
///
/// - `DateNavigator` is the generic ‹ title › [Now] row. Weekly and Timeline
///   drive it with their own `Date` state; Discover/Calls reuse it via
///   `ScopeDayNavigator` when their scope is a single day.
/// - `RangeScopePicker` is the segmented 7 / 14 / 30 / Day control shared by
///   Discover and Calls (previously duplicated in both, binding included).
struct DateNavigator: View {
    let title: String
    let nowLabel: String
    let prevHelp: String
    let nextHelp: String
    var titleFont: Font = .title3.bold()
    var titleMinWidth: CGFloat = 200
    var nextDisabled: Bool = false
    var nowDisabled: Bool = false
    let onPrev: () -> Void
    let onNext: () -> Void
    let onNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPrev) { Image(systemName: "chevron.left") }
                .help(prevHelp)
                .accessibilityLabel(prevHelp)

            Text(title)
                .font(titleFont)
                .frame(minWidth: titleMinWidth, alignment: .leading)

            Button(action: onNext) { Image(systemName: "chevron.right") }
                .help(nextHelp)
                .accessibilityLabel(nextHelp)
                .disabled(nextDisabled)

            Button(nowLabel, action: onNow)
                .fixedSize()
                .disabled(nowDisabled)
        }
    }
}

/// Segmented range picker shared by Discover and Calls. Owns the mapping
/// between the integer tags and `DateScope` (`-1` == single-day mode).
struct RangeScopePicker: View {
    @Binding var scope: DateScope

    var body: some View {
        Picker("", selection: rangeModeBinding) {
            ForEach(DateScope.presetDayCounts, id: \.self) { n in
                Text("\(n) days").tag(n)
            }
            Text("Day").tag(-1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
        .accessibilityLabel("Time range")
    }

    private var rangeModeBinding: Binding<Int> {
        Binding(
            get: {
                switch scope {
                case .lastDays(let n): return n
                case .day: return -1
                }
            },
            set: { newValue in
                if newValue == -1 {
                    if case .day = scope { return }
                    scope = .day(Calendar.current.startOfDay(for: Date()))
                } else {
                    scope = .lastDays(newValue)
                }
            }
        )
    }
}

/// Day-by-day navigator for the `DateScope`-based views. Renders nothing unless
/// the scope is `.day`. Disables "next" and "Today" once you reach today so the
/// past-activity views can't page into empty future days.
struct ScopeDayNavigator: View {
    @Binding var scope: DateScope

    var body: some View {
        DateNavigator(
            title: dayLabel,
            nowLabel: "Today",
            prevHelp: "Previous day",
            nextHelp: "Next day",
            titleFont: .body.bold(),
            titleMinWidth: 180,
            nextDisabled: isToday,
            nowDisabled: isToday,
            onPrev: { shiftDay(-1) },
            onNext: { shiftDay(1) },
            onNow: { scope = .day(Calendar.current.startOfDay(for: Date())) }
        )
    }

    private func shiftDay(_ delta: Int) {
        guard case .day(let d) = scope,
              let next = Calendar.current.date(byAdding: .day, value: delta, to: d) else { return }
        scope = .day(next)
    }

    private var dayLabel: String {
        guard case .day(let d) = scope else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return DateFormatting.dayMonthWeekday.string(from: d)
    }

    private var isToday: Bool {
        guard case .day(let d) = scope else { return false }
        return Calendar.current.isDateInToday(d)
    }
}

/// Cached `DateFormatter`s. Building a `DateFormatter` per render (as several
/// views did in computed `title`/`header` properties) is wasteful and shows up
/// under scrolling; share these instead.
enum DateFormatting {
    /// e.g. "Wed 28 May"
    static let dayMonthWeekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    /// e.g. "Wed 28 May 2026"
    static let dayMonthWeekdayYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    /// e.g. "28 May"
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    /// e.g. "2026"
    static let year: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    /// e.g. "Wed 28/5" — weekly-grid column header.
    static let weekdayDayShortMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d/M"
        return f
    }()
}
