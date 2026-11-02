import Foundation

/// Date arithmetic for repeat rules' `until`: local wall-clock components in
/// the event's zone ⇄ instants. Internal — not a general date parser.
enum RecurrenceDates {
    static let utc = TimeZone(identifier: "UTC")!

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: 0
        }
    }

    static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        (1 ... 9999).contains(year) && (1 ... 12).contains(month) && day >= 1 && day <= daysInMonth(month, year)
    }

    static func isValidTime(hour: Int, minute: Int, second: Int) -> Bool {
        (0 ... 23).contains(hour) && (0 ... 59).contains(minute) && (0 ... 59).contains(second)
    }

    /// Date-only components.
    static func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
        DateComponents(year: y, month: m, day: d)
    }

    /// Date-time components, all three time fields set.
    static func dateTime(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> DateComponents {
        DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s)
    }

    /// True when the components carry a time of day.
    static func hasTime(_ c: DateComponents) -> Bool {
        c.hour != nil || c.minute != nil || c.second != nil
    }

    /// The instant the local wall-clock `c` names in `timeZone`.
    static func instant(_ c: DateComponents, in timeZone: TimeZone) -> Date? {
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let comps = dateTime(y, m, d, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return calendar(timeZone).date(from: comps)
    }

    /// Wall-clock date-time components of `date` in `timeZone`.
    static func wallClock(_ date: Date, in timeZone: TimeZone) -> DateComponents {
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return dateTime(c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `2026-11-09` / `2026-11-09T15:30:00`, for messages.
    static func display(_ c: DateComponents) -> String {
        let date = "\((c.year ?? 0).zeroPadded(4))-\((c.month ?? 0).zeroPadded(2))-\((c.day ?? 0).zeroPadded(2))"
        guard hasTime(c) else { return date }
        return date + "T\((c.hour ?? 0).zeroPadded(2)):\((c.minute ?? 0).zeroPadded(2)):\((c.second ?? 0).zeroPadded(2))"
    }

    /// `20261109` / `20261109T153000`.
    static func basic(_ c: DateComponents, includeTime: Bool) -> String {
        let date = "\((c.year ?? 0).zeroPadded(4))\((c.month ?? 0).zeroPadded(2))\((c.day ?? 0).zeroPadded(2))"
        guard includeTime else { return date }
        return date + "T\((c.hour ?? 0).zeroPadded(2))\((c.minute ?? 0).zeroPadded(2))\((c.second ?? 0).zeroPadded(2))"
    }
}
