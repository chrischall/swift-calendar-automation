public import EventKit
public import Foundation

/// `Recurrence` ⇄ `EKRecurrenceRule`.
///
/// `until` is local wall clock in the event's zone; EventKit's
/// `EKRecurrenceEnd(end:)` is an instant. The two meet like this:
/// - a date-only `until` ("through May 3") ends at **23:59:59 local** on that
///   day, so every occurrence that day is included whatever its time, and
///   an end at 23:59:59 local reads back as date-only;
/// - a date-time `until` ends at that local instant, and any other end reads
///   back as the local date-time.
///
/// `WKST`: EventKit reports a first day of the week on every rule, Monday
/// when nobody chose one — RFC 5545's default too. So Monday (or 0) reads
/// back as "unset", and only another day is written.
public extension Recurrence {
    /// Read an EventKit rule. Never fails: every frequency and part EventKit
    /// can hold has a field here, and the result is not validated (a rule
    /// another app wrote is shown as it is, even one `validate` would
    /// refuse for a new event).
    ///
    /// - Parameter timeZone: the event's zone (the current zone for a
    ///   floating event), for turning the end instant into wall clock.
    init(ekRule: EKRecurrenceRule, timeZone: TimeZone) {
        let frequency: Frequency = switch ekRule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        @unknown default: .daily
        }
        func ints(_ values: [NSNumber]?) -> [Int]? { values.map { $0.map(\.intValue) } }
        let days: [Day]? = ekRule.daysOfTheWeek.map { list in
            list.compactMap { d in
                Weekday(calendarWeekday: d.dayOfTheWeek.rawValue).map { Day(
                    $0,
                    ordinal: d.weekNumber == 0 ? nil : d.weekNumber
                ) }
            }
        }
        let weekStart = ekRule.firstDayOfTheWeek == Weekday.MO.calendarWeekday
            ? nil : Weekday(calendarWeekday: ekRule.firstDayOfTheWeek)

        var end: End?
        if let recurrenceEnd = ekRule.recurrenceEnd {
            if let endDate = recurrenceEnd.endDate {
                let local = RecurrenceDates.wallClock(endDate, in: timeZone)
                if local.hour == 23, local.minute == 59, local.second == 59,
                   let y = local.year, let m = local.month, let d = local.day
                {
                    end = .until(RecurrenceDates.day(y, m, d))
                } else {
                    end = .until(local)
                }
            } else {
                end = .count(recurrenceEnd.occurrenceCount)
            }
        }

        self.init(
            frequency: frequency,
            interval: ekRule.interval,
            daysOfWeek: days,
            daysOfMonth: ints(ekRule.daysOfTheMonth),
            monthsOfYear: ints(ekRule.monthsOfTheYear),
            weeksOfYear: ints(ekRule.weeksOfTheYear),
            daysOfYear: ints(ekRule.daysOfTheYear),
            setPositions: ints(ekRule.setPositions),
            weekStart: weekStart,
            end: end
        )
    }

    /// The EventKit rule for this recurrence. Validate first
    /// (``validate(start:timeZone:isAllDay:)``); this maps, it doesn't check.
    ///
    /// - Parameters:
    ///   - timeZone: the event's zone (the current zone for a floating or
    ///     all-day event); `until` is wall clock in it.
    ///   - isAllDay: an all-day series ends at the end of its `until` day,
    ///     even when `until` carries a time.
    func ekRecurrenceRule(timeZone: TimeZone, isAllDay: Bool) -> EKRecurrenceRule {
        let ekFrequency: EKRecurrenceFrequency = switch frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        func numbers(_ values: [Int]?) -> [NSNumber]? { values.map { $0.map { NSNumber(value: $0) } } }
        let days = daysOfWeek.map { list in
            list.compactMap { d in
                EKWeekday(rawValue: d.weekday.calendarWeekday).map { EKRecurrenceDayOfWeek(
                    $0,
                    weekNumber: d.ordinal ?? 0
                ) }
            }
        }
        let rule = EKRecurrenceRule(
            recurrenceWith: ekFrequency,
            interval: interval,
            daysOfTheWeek: days,
            daysOfTheMonth: numbers(daysOfMonth),
            monthsOfTheYear: numbers(monthsOfYear),
            weeksOfTheYear: numbers(weeksOfYear),
            daysOfTheYear: numbers(daysOfYear),
            setPositions: numbers(setPositions),
            end: ekEnd(timeZone: timeZone, isAllDay: isAllDay)
        )
        if let weekStart, weekStart != .MO {
            // `firstDayOfTheWeek` is read-only in the SDK, but the rule has a
            // setter behind it (EventKit fills it in from the locale); KVC is
            // the only way to state WKST. Guarded so a future EventKit
            // without the setter degrades to its default instead of trapping.
            if rule.responds(to: Selector(("setFirstDayOfTheWeek:"))) {
                rule.setValue(weekStart.calendarWeekday, forKey: "firstDayOfTheWeek")
            }
        }
        return rule
    }

    private func ekEnd(timeZone: TimeZone, isAllDay: Bool) -> EKRecurrenceEnd? {
        switch end {
        case nil:
            return nil
        case let .count(n):
            return EKRecurrenceEnd(occurrenceCount: n)
        case let .until(c):
            let local = if isAllDay || !RecurrenceDates.hasTime(c) {
                RecurrenceDates.dateTime(c.year ?? 0, c.month ?? 0, c.day ?? 0, 23, 59, 59)
            } else {
                c
            }
            guard let instant = RecurrenceDates.instant(local, in: timeZone) else { return nil }
            return EKRecurrenceEnd(end: instant)
        }
    }
}
