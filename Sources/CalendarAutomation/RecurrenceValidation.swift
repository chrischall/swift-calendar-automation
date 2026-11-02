public import Foundation

public extension Recurrence {
    /// Check the rule against the event it will repeat.
    ///
    /// - `interval` and `count` are at least 1.
    /// - `until` is a real date (and time, when given — hour and minute
    ///   both), on or after the start: a date-only `until` is compared by
    ///   local day in `timeZone`, a date-time one as an instant.
    /// - `daysOfWeek` belongs to weekly, monthly and yearly rules. Weekly
    ///   days are plain (`TU`); monthly/yearly days need an ordinal (`2TU`)
    ///   unless `setPositions` picks among them.
    /// - `daysOfMonth` is monthly only; `monthsOfYear`, `weeksOfYear` and
    ///   `daysOfYear` are yearly only.
    /// - `setPositions` needs `daysOfWeek` or `daysOfMonth`, and isn't daily.
    /// - Every list is non-empty, duplicate-free and in range (see each
    ///   property).
    ///
    /// - Parameters:
    ///   - start: the series' first occurrence.
    ///   - timeZone: the event's zone; `until` is wall clock in it.
    ///   - isAllDay: whether the event is all-day. No current check depends
    ///     on it (an all-day start is midnight of its local day, which the
    ///     date-only comparison already handles); callers state it so the
    ///     contract doesn't change when one does.
    func validate(start: Date, timeZone: TimeZone, isAllDay _: Bool) throws(RecurrenceError) {
        guard interval >= 1 else { throw .invalidInterval(interval) }
        try validateLists()
        try validateCombinations()
        try validateEnd(start: start, timeZone: timeZone)
    }
}

private extension Recurrence {
    func validateLists() throws(RecurrenceError) {
        if let daysOfWeek {
            try Self.checkList(.daysOfWeek, daysOfWeek, display: \.string)
            let limit = frequency == .monthly ? 5 : 53
            for day in daysOfWeek {
                if let n = day.ordinal, n == 0 || abs(n) > limit {
                    throw .valueOutOfRange(.daysOfWeek, value: n)
                }
            }
        }
        try Self.checkInts(.daysOfMonth, daysOfMonth, max: 31, allowNegative: true)
        try Self.checkInts(.monthsOfYear, monthsOfYear, max: 12, allowNegative: false)
        try Self.checkInts(.weeksOfYear, weeksOfYear, max: 53, allowNegative: true)
        try Self.checkInts(.daysOfYear, daysOfYear, max: 366, allowNegative: true)
        try Self.checkInts(.setPositions, setPositions, max: 366, allowNegative: true)
    }

    func validateCombinations() throws(RecurrenceError) {
        if let setPositions, !setPositions.isEmpty, frequency == .daily {
            throw .setPositionsWithDaily
        }
        if daysOfWeek != nil, frequency == .daily {
            throw .partNotAllowed(.daysOfWeek, frequency: frequency)
        }
        if daysOfMonth != nil, frequency != .monthly {
            throw .partNotAllowed(.daysOfMonth, frequency: frequency)
        }
        for (field, value) in [
            (Field.monthsOfYear, monthsOfYear),
            (.weeksOfYear, weeksOfYear),
            (.daysOfYear, daysOfYear),
        ]
            where value != nil && frequency != .yearly
        {
            throw .partNotAllowed(field, frequency: frequency)
        }
        if setPositions != nil, daysOfWeek == nil, daysOfMonth == nil {
            throw .setPositionsWithoutDays
        }
        if let daysOfWeek {
            if frequency == .weekly, let ordinal = daysOfWeek.first(where: { $0.ordinal != nil }) {
                throw .ordinalWithWeekly(day: ordinal.string)
            }
            if frequency == .monthly || frequency == .yearly, setPositions == nil,
               let plain = daysOfWeek.first(where: { $0.ordinal == nil })
            {
                throw .dayNeedsPosition(day: plain.string)
            }
        }
    }

    func validateEnd(start: Date, timeZone: TimeZone) throws(RecurrenceError) {
        switch end {
        case nil:
            return
        case let .count(n):
            guard n >= 1 else { throw .invalidCount(n) }
        case let .until(c):
            let shown = RecurrenceDates.display(c)
            guard let y = c.year, let m = c.month, let d = c.day,
                  RecurrenceDates.isValidDate(year: y, month: m, day: d)
            else { throw .invalidUntil(shown) }
            if RecurrenceDates.hasTime(c) {
                guard let h = c.hour, let mi = c.minute,
                      RecurrenceDates.isValidTime(hour: h, minute: mi, second: c.second ?? 0),
                      let instant = RecurrenceDates.instant(c, in: timeZone)
                else { throw .invalidUntil(shown) }
                guard instant >= start else { throw .untilBeforeStart(until: shown) }
            } else {
                let s = RecurrenceDates.wallClock(start, in: timeZone)
                let startDay = [s.year ?? 0, s.month ?? 0, s.day ?? 0]
                guard [y, m, d].lexicographicallyPrecedes(startDay) == false else {
                    throw .untilBeforeStart(until: shown)
                }
            }
        }
    }

    static func checkList<T: Hashable>(
        _ field: Field, _ values: [T], display: (T) -> String
    ) throws(RecurrenceError) {
        guard !values.isEmpty else { throw .emptyList(field) }
        var seen = Set<T>()
        for v in values where !seen.insert(v).inserted {
            throw .duplicateValue(field, value: display(v))
        }
    }

    static func checkInts(
        _ field: Field, _ values: [Int]?, max: Int, allowNegative: Bool
    ) throws(RecurrenceError) {
        guard let values else { return }
        try checkList(field, values, display: String.init)
        for v in values {
            let ok = (1 ... max).contains(v) || (allowNegative && (-max ... -1).contains(v))
            guard ok else { throw .valueOutOfRange(field, value: v) }
        }
    }
}
