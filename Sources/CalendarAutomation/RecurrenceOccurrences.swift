public import Foundation

/// The first occurrences of a series and, for a series with an end, how many
/// there are in total.
public struct OccurrencePreview: Sendable, Equatable, Hashable {
    /// The earliest occurrences, the series' start first, at most the
    /// requested `limit`.
    public var first: [Date]
    /// Every occurrence of a series with an end (`until` or `count`). Nil for
    /// an open-ended series, and when the series has more than
    /// ``Recurrence/maxCountedOccurrences`` (`totalIsCapped` is then true).
    public var total: Int?
    /// True when counting stopped at ``Recurrence/maxCountedOccurrences``:
    /// the series has more occurrences than that.
    public var totalIsCapped: Bool

    public init(first: [Date], total: Int?, totalIsCapped: Bool) {
        self.first = first
        self.total = total
        self.totalIsCapped = totalIsCapped
    }
}

public extension Recurrence {
    /// The most occurrences ``occurrences(start:timeZone:isAllDay:limit:)``
    /// counts (and returns) before giving up on an exact total.
    static let maxCountedOccurrences = 1000

    /// Preview the series this rule makes from `start`.
    ///
    /// Semantics follow EventKit (and RFC 5545):
    /// - The start is always occurrence #1, even when it doesn't match the
    ///   rule (a Tuesday start of a "weekly on Monday" series), and it counts
    ///   toward `count`.
    /// - Occurrences keep the start's wall-clock time in `timeZone` across
    ///   DST changes. A time that doesn't exist on a spring-forward day moves
    ///   forward by the gap (02:30 → 03:30).
    /// - A date that doesn't exist in a period is skipped, not moved: monthly
    ///   on the 31st skips 30-day months; yearly on Feb 29 hits leap years.
    /// - `setPositions` picks from every day the other parts select in the
    ///   period — the whole period, including days before the start.
    /// - Weeks start on `weekStart`, Monday when unset (RFC 5545's default).
    ///
    /// The total is counted only for a rule with an end, and counting stops
    /// after ``maxCountedOccurrences``. An open-ended rule is never expanded
    /// past `limit`. `limit` is clamped to `0…maxCountedOccurrences`.
    ///
    /// The rule should be valid for this start
    /// (``validate(start:timeZone:isAllDay:)``); an invalid one previews as
    /// the start alone, total 1.
    ///
    /// Foundation's `Calendar.RecurrenceRule` isn't used: on macOS 27.2 it
    /// mis-expands `BYSETPOS`, plain `BYDAY` in monthly rules (only the first
    /// such weekday) and `BYWEEKNO`, and its strict matching drops
    /// spring-forward days. The unit tests check this expansion against it
    /// for the shapes it gets right.
    func occurrences(start: Date, timeZone: TimeZone, isAllDay: Bool, limit: Int) -> OccurrencePreview {
        let limit = Swift.min(Swift.max(0, limit), Self.maxCountedOccurrences)
        guard (try? validate(start: start, timeZone: timeZone, isAllDay: isAllDay)) != nil else {
            return OccurrencePreview(first: limit > 0 ? [start] : [], total: 1, totalIsCapped: false)
        }
        let expansion = Expansion(rule: normalized(start: start, timeZone: timeZone), start: start,
                                  timeZone: timeZone, isAllDay: isAllDay)
        let wanted = end == nil ? limit : Self.maxCountedOccurrences + 1
        let dates = expansion.dates(upTo: wanted)
        let first = Array(dates.prefix(limit))
        guard end != nil else { return OccurrencePreview(first: first, total: nil, totalIsCapped: false) }
        if dates.count > Self.maxCountedOccurrences {
            return OccurrencePreview(first: first, total: nil, totalIsCapped: true)
        }
        return OccurrencePreview(first: first, total: dates.count, totalIsCapped: false)
    }
}

/// A proleptic Gregorian day, as days since 1970-01-01. Day arithmetic stays
/// in plain integers, clear of time zones; only the final step to an instant
/// uses the event's zone.
struct CivilDay: Comparable, Hashable {
    var number: Int

    init(number: Int) { self.number = number }

    /// Howard Hinnant's `days_from_civil`.
    init(_ year: Int, _ month: Int, _ day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        number = era * 146_097 + doe - 719_468
    }

    /// `civil_from_days`: (year, month, day).
    var civil: (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Sunday … 6 = Saturday.
    var weekdayIndex: Int { ((number % 7) + 7 + 4) % 7 }

    static func + (lhs: CivilDay, rhs: Int) -> CivilDay { CivilDay(number: lhs.number + rhs) }
    static func - (lhs: CivilDay, rhs: Int) -> CivilDay { CivilDay(number: lhs.number - rhs) }
    static func < (lhs: CivilDay, rhs: CivilDay) -> Bool { lhs.number < rhs.number }
}

private extension Recurrence.Weekday {
    /// 0 = Sunday … 6 = Saturday, matching ``CivilDay/weekdayIndex``.
    var index: Int { calendarWeekday - 1 }
}

/// Expands a valid, normalized rule period by period.
private struct Expansion {
    let rule: Recurrence
    let start: Date
    let calendar: Calendar
    let startDay: CivilDay
    let time: (hour: Int, minute: Int, second: Int)
    let weekStart: Int

    /// Scanning stops after this many periods, or past year 9999, whichever
    /// comes first — a rule whose parts never match again ends there.
    static let maxPeriods = 100_000

    init(rule: Recurrence, start: Date, timeZone: TimeZone, isAllDay: Bool) {
        self.rule = rule
        self.start = start
        calendar = RecurrenceDates.calendar(timeZone)
        let c = RecurrenceDates.wallClock(start, in: timeZone)
        startDay = CivilDay(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        time = isAllDay ? (0, 0, 0) : (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        weekStart = (rule.weekStart ?? .MO).index
    }

    func dates(upTo wanted: Int) -> [Date] {
        guard wanted > 0 else { return [] }
        var out = [start]
        let untilDay: CivilDay? = switch rule.end {
        case let .until(c) where !RecurrenceDates.hasTime(c): CivilDay(c.year ?? 0, c.month ?? 0, c.day ?? 0)
        default: nil
        }
        let untilInstant: Date? = switch rule.end {
        case let .until(c) where RecurrenceDates.hasTime(c): RecurrenceDates.instant(c, in: calendar.timeZone)
        default: nil
        }
        let count: Int? = if case let .count(n) = rule.end {
            n
        } else {
            nil
        }
        if let count, out.count >= count {
            return out
        }

        for period in 0 ..< Self.maxPeriods {
            guard let (earliest, days) = candidates(period: period) else { break }
            if let untilDay, earliest > untilDay {
                break
            }
            for day in days {
                if let untilDay, day > untilDay {
                    return out
                }
                guard let instant = instant(day), instant > start else { continue }
                if let untilInstant, instant > untilInstant {
                    return out
                }
                out.append(instant)
                if out.count >= wanted {
                    return out
                }
                if let count, out.count >= count {
                    return out
                }
            }
        }
        return out
    }

    func instant(_ day: CivilDay) -> Date? {
        let (y, m, d) = day.civil
        return calendar.date(from: RecurrenceDates.dateTime(y, m, d, time.hour, time.minute, time.second))
    }

    /// The period's earliest possible day (for the `until` cut-off) and its
    /// selected days, sorted. Nil once the period is past year 9999.
    func candidates(period k: Int) -> (CivilDay, [CivilDay])? {
        let step = k * rule.interval
        let (sy, sm, _) = startDay.civil
        let earliest: CivilDay
        let days: [CivilDay]
        switch rule.frequency {
        case .daily:
            earliest = startDay + step
            days = [earliest]
        case .weekly:
            earliest = startDay - (startDay.weekdayIndex - weekStart + 7) % 7 + 7 * step
            let offsets = (rule.daysOfWeek ?? []).map { ($0.weekday.index - weekStart + 7) % 7 }
            days = offsets.map { earliest + $0 }
        case .monthly:
            let months = (sm - 1) + step
            let (y, m) = (sy + months / 12, months % 12 + 1)
            earliest = CivilDay(y, m, 1)
            days = monthDays(y, m)
        case .yearly:
            let y = sy + step
            earliest = CivilDay(y, 1, 1) - 7 // week 1 can start in late December
            days = yearDays(y)
        }
        guard earliest.civil.year <= 9999 else { return nil }
        return (earliest, applySetPositions(Array(Set(days)).sorted()))
    }

    func applySetPositions(_ days: [CivilDay]) -> [CivilDay] {
        guard let positions = rule.setPositions, !days.isEmpty else { return days }
        let picked = positions.compactMap { n -> CivilDay? in
            let i = n > 0 ? n - 1 : days.count + n
            return days.indices.contains(i) ? days[i] : nil
        }
        return Array(Set(picked)).sorted()
    }

    // MARK: monthly

    func monthDays(_ y: Int, _ m: Int) -> [CivilDay] {
        let length = RecurrenceDates.daysInMonth(m, y)
        let first = CivilDay(y, m, 1)
        let range = first ... first + (length - 1)
        let byMonthDay = rule.daysOfMonth.map { resolveDaysOfMonth($0, first: first, length: length) }
        let byDay = rule.daysOfWeek.map { expand($0, in: range) }
        switch (byMonthDay, byDay) {
        case let (.some(a), .some(b)): return a.filter(Set(b).contains)
        case let (.some(a), nil): return a
        case let (nil, .some(b)): return b
        case (nil, nil):
            let d = startDay.civil.day
            return d <= length ? [first + (d - 1)] : []
        }
    }

    func resolveDaysOfMonth(_ values: [Int], first: CivilDay, length: Int) -> [CivilDay] {
        values.compactMap { n in
            let d = n > 0 ? n : length + n + 1
            return (1 ... length).contains(d) ? first + (d - 1) : nil
        }
    }

    /// Every day in `range` a `BYDAY` list selects: all such weekdays for a
    /// plain day, the nth (from the end when negative) for an ordinal one.
    func expand(_ list: [Recurrence.Day], in range: ClosedRange<CivilDay>) -> [CivilDay] {
        list.flatMap { day -> [CivilDay] in
            let firstMatch = range.lowerBound + (day.weekday.index - range.lowerBound.weekdayIndex + 7) % 7
            let all = Array(stride(from: firstMatch.number, through: range.upperBound.number, by: 7))
                .map(CivilDay.init(number:))
            guard let n = day.ordinal else { return all }
            let i = n > 0 ? n - 1 : all.count + n
            return all.indices.contains(i) ? [all[i]] : []
        }
    }

    // MARK: yearly

    func yearDays(_ y: Int) -> [CivilDay] {
        let jan1 = CivilDay(y, 1, 1)
        let length = CivilDay(y + 1, 1, 1).number - jan1.number
        let months = rule.monthsOfYear.map(Set.init)
        let weekdays = rule.daysOfWeek.map { Set($0.map(\.weekday.index)) }
        func inMonths(_ d: CivilDay) -> Bool { months?.contains(d.civil.month) ?? true }
        func onWeekdays(_ d: CivilDay) -> Bool { weekdays?.contains(d.weekdayIndex) ?? true }

        if let daysOfYear = rule.daysOfYear {
            // BYWEEKNO narrows BYYEARDAY (RFC 5545 applies both): keep only
            // the days that fall in one of those weeks.
            let inWeeks = rule.weeksOfYear.map { Set(weekDays($0, year: y).map(\.number)) }
            return daysOfYear.compactMap { n -> CivilDay? in
                let d = n > 0 ? n : length + n + 1
                return (1 ... length).contains(d) ? jan1 + (d - 1) : nil
            }.filter { inMonths($0) && onWeekdays($0) && (inWeeks?.contains($0.number) ?? true) }
        }
        if let weeks = rule.weeksOfYear {
            let wanted = weekdays ?? [startDay.weekdayIndex]
            return weekDays(weeks, year: y).filter { wanted.contains($0.weekdayIndex) && inMonths($0) }
        }
        let monthList = rule.monthsOfYear ?? (rule.daysOfWeek == nil && rule.daysOfMonth == nil
            ? [startDay.civil.month] : Array(1 ... 12))
        if let daysOfWeek = rule.daysOfWeek {
            let selected: [CivilDay] = if rule.monthsOfYear != nil {
                monthList.flatMap { m in
                    let first = CivilDay(y, m, 1)
                    return expand(daysOfWeek, in: first ... first + (RecurrenceDates.daysInMonth(m, y) - 1))
                }
            } else {
                expand(daysOfWeek, in: jan1 ... jan1 + (length - 1))
            }
            guard let daysOfMonth = rule.daysOfMonth else { return selected }
            return selected.filter { d in
                let (yy, mm, dd) = d.civil
                let len = RecurrenceDates.daysInMonth(mm, yy)
                return daysOfMonth.contains { ($0 > 0 ? $0 : len + $0 + 1) == dd }
            }
        }
        return monthList.flatMap { m -> [CivilDay] in
            let first = CivilDay(y, m, 1)
            let len = RecurrenceDates.daysInMonth(m, y)
            return resolveDaysOfMonth(rule.daysOfMonth ?? [startDay.civil.day], first: first, length: len)
        }
    }

    /// Every day of the given `BYWEEKNO` weeks of year `y` (±1…53; a week
    /// the year doesn't have is skipped), in the order the weeks are listed.
    func weekDays(_ weeks: [Int], year y: Int) -> [CivilDay] {
        let week1 = weekOneStart(y)
        let count = (weekOneStart(y + 1).number - week1.number) / 7
        return weeks.flatMap { n -> [CivilDay] in
            let w = n > 0 ? n : count + n + 1
            guard (1 ... count).contains(w) else { return [] }
            let first = week1 + 7 * (w - 1)
            return (0 ..< 7).map { first + $0 }
        }
    }

    /// The first day of week 1 (RFC 5545 / ISO 8601: the first week with at
    /// least four days in the year), weeks starting on `weekStart`.
    func weekOneStart(_ y: Int) -> CivilDay {
        let jan1 = CivilDay(y, 1, 1)
        let delta = (jan1.weekdayIndex - weekStart + 7) % 7
        return delta <= 3 ? jan1 - delta : jan1 + (7 - delta)
    }
}
