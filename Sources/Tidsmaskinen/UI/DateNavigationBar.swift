import SwiftUI

/// Shared date navigation so time-scoped views use the same control
/// treatment, "jump to now" affordance and accessibility labels on the
/// otherwise icon-only chevrons. `DateNavigator` is the generic
/// ‹ title › [Now] row; Weekly and Timeline drive it with their own state.
struct DateNavigator: View {
    let title: String
    let nowLabel: String
    let prevHelp: String
    let nextHelp: String
    var titleFont: Font = .title3.bold()
    var titleMinWidth: CGFloat = 150
    var nextDisabled: Bool = false
    var nowDisabled: Bool = false
    /// Optional key equivalents (My day uses ⌘← / ⌘→ / ⌘T).
    var prevShortcut: KeyboardShortcut? = nil
    var nextShortcut: KeyboardShortcut? = nil
    var nowShortcut: KeyboardShortcut? = nil
    let onPrev: () -> Void
    let onNext: () -> Void
    let onNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPrev) { Image(systemName: "chevron.left") }
                .keyboardShortcut(prevShortcut)
                .help(prevHelp)
                .accessibilityLabel(prevHelp)

            Text(title)
                .font(titleFont)
                .frame(minWidth: titleMinWidth, alignment: .center)

            Button(action: onNext) { Image(systemName: "chevron.right") }
                .keyboardShortcut(nextShortcut)
                .help(nextHelp)
                .accessibilityLabel(nextHelp)
                .disabled(nextDisabled)

            Button(nowLabel, action: onNow)
                .keyboardShortcut(nowShortcut)
                .fixedSize()
                .disabled(nowDisabled)
        }
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

    /// e.g. "Mon" — short weekday for chart axes.
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}
