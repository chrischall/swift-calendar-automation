public import Foundation

/// A wall-clock time of day, `HH:MM`, 24-hour.
public struct ClockTime: Equatable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Exactly `HH:MM` (two digits each). Anything else is nil, so a typo
    /// is refused rather than read as some other time.
    public init?(parsing raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(
                  { $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
              ),
              let h = Int(parts[0]), let m = Int(parts[1])
        else { return nil }
        self.init(hour: h, minute: m)
    }

    public var minutesIntoDay: Int { hour * 60 + minute }

    public var description: String { "\(hour.zeroPadded(2)):\(minute.zeroPadded(2))" }
}

/// What a free-time search asks for.
public struct FreeTimeQuery: Equatable, Sendable {
    public var from: Date
    public var to: Date
    /// Nothing earlier is offered — the tool passes "now", because a slot
    /// that has already begun can never be booked.
    public var notBefore: Date?
    /// The zone working hours are read in.
    public var timeZone: TimeZone
    public var workdayStart: ClockTime
    public var workdayEnd: ClockTime
    public var weekdaysOnly: Bool
    /// Shortest slot worth reporting.
    public var minMinutes: Int
    /// Let all-day events block their whole day.
    public var includeAllDay: Bool

    public init(
        from: Date, to: Date, notBefore: Date?, timeZone: TimeZone,
        workdayStart: ClockTime, workdayEnd: ClockTime,
        weekdaysOnly: Bool, minMinutes: Int, includeAllDay: Bool
    ) {
        self.from = from
        self.to = to
        self.notBefore = notBefore
        self.timeZone = timeZone
        self.workdayStart = workdayStart
        self.workdayEnd = workdayEnd
        self.weekdaysOnly = weekdaysOnly
        self.minMinutes = minMinutes
        self.includeAllDay = includeAllDay
    }
}

/// One open stretch inside a day's working hours.
public struct FreeSlot: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
}

/// A working day that was considered, and its open stretches (possibly none).
public struct FreeDay: Equatable, Sendable {
    /// The start of the day, in the zone the search ran in.
    public let day: Date
    public let slots: [FreeSlot]
    /// Set when the window starts after this day's working hours begin, so
    /// the day's first hours were not looked at (not the same as busy).
    public var windowStartsAt: Date?
    /// Set when the window ends before this day's working hours do.
    public var windowEndsAt: Date?
}

/// What a free-time search found, and what it left out and why — so an
/// empty answer can be told apart from a window it never looked at.
public struct FreeTimeResult: Equatable, Sendable {
    public let days: [FreeDay]
    /// Saturdays and Sundays skipped because `weekdaysOnly` was set.
    public let weekendDays: Int
    /// Days whose working hours fall entirely outside the window, or have
    /// already passed.
    public let outsideWindow: Int
    /// Events in the window that did not count as busy, by reason.
    public let ignored: Ignored

    public struct Ignored: Equatable, Sendable {
        public var allDay = 0
        public var shownAsFree = 0
        public var cancelled = 0
        public var declined = 0

        public init() {}
    }
}

/// Free-time arithmetic, kept free of EventKit so every rule is unit-tested:
/// decide which events are busy, merge them, and subtract them from each
/// day's working hours.
///
/// Working hours are built per day from the wall clock in the given zone,
/// so a DST change moves them with the clock rather than with UTC.
public enum FreeTimeFinder {
    /// The busy intervals among `events`, merged, plus a count of the events
    /// that were left out.
    ///
    /// Busy means: not shown as free, not cancelled and not declined by you.
    /// An all-day event blocks its whole day only with `includeAllDay` — by
    /// default birthdays, holidays and "working from home" markers would
    /// otherwise leave no free time at all.
    public static func busy(
        _ events: [CalendarEvent], includeAllDay: Bool, timeZone: TimeZone
    ) -> (intervals: [DateInterval], ignored: FreeTimeResult.Ignored) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var ignored = FreeTimeResult.Ignored()
        var intervals: [DateInterval] = []
        for ev in events {
            if ev.isCancelled {
                ignored.cancelled += 1; continue
            }
            if ev.declinedByMe {
                ignored.declined += 1; continue
            }
            if ev.showsAsFree {
                ignored.shownAsFree += 1; continue
            }
            if ev.isAllDay {
                guard includeAllDay else { ignored.allDay += 1; continue }
                // Whole days, however the end is spelled: EventKit reports
                // 23:59:59 of the last day, and an inclusive end == start
                // is a legitimate one-day event (see CalendarService).
                let first = cal.startOfDay(for: ev.startDate)
                let last = cal.startOfDay(for: max(ev.endDate, ev.startDate))
                let end = cal.date(byAdding: .day, value: 1, to: last).map { cal.startOfDay(for: $0) }
                    ?? last.addingTimeInterval(86400)
                intervals.append(DateInterval(start: first, end: end))
                continue
            }
            guard ev.endDate > ev.startDate else { continue }
            intervals.append(DateInterval(start: ev.startDate, end: ev.endDate))
        }
        return (merge(intervals), ignored)
    }

    /// Sort and merge overlapping or touching intervals.
    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
            } else {
                out.append(i)
            }
        }
        return out
    }

    /// Open slots per working day in the query's window, given `events`
    /// (everything the store returned for that window).
    public static func find(_ q: FreeTimeQuery, in events: [CalendarEvent]) -> FreeTimeResult {
        let (intervals, ignored) = busy(events, includeAllDay: q.includeAllDay, timeZone: q.timeZone)
        return compute(q, busy: intervals, ignored: ignored)
    }

    /// Open slots per working day in `q.from ..< q.to`, around merged `busy`
    /// intervals (see ``busy(_:includeAllDay:timeZone:)``).
    public static func compute(
        _ q: FreeTimeQuery, busy: [DateInterval], ignored: FreeTimeResult.Ignored = .init()
    ) -> FreeTimeResult {
        let (from, to) = (q.from, q.to)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = q.timeZone
        let lower = max(from, q.notBefore ?? from)
        let minSeconds = Double(q.minMinutes) * 60
        var days: [FreeDay] = []
        var weekendDays = 0
        var outsideWindow = 0
        guard to > from else {
            return FreeTimeResult(days: [], weekendDays: 0, outsideWindow: 0, ignored: ignored)
        }
        // The last day is the one holding the last instant of the window, so
        // a window ending exactly at midnight doesn't pull in the next day.
        let lastDay = cal.startOfDay(for: to.addingTimeInterval(-1))
        var day = cal.startOfDay(for: from)
        while cal.compare(day, to: lastDay, toGranularity: .day) != .orderedDescending {
            // Back onto the next day's START each step: where a DST change
            // skips midnight (Santiago, Havana, Cairo…) that day starts at
            // 01:00, and stepping by a day from there kept every later day
            // at 01:00 — past the last day's midnight, so it was dropped.
            defer {
                let next = cal.date(byAdding: .day, value: 1, to: day).map { cal.startOfDay(for: $0) }
                day = next.flatMap { $0 > day ? $0 : nil } ?? day.addingTimeInterval(86400)
            }
            let weekday = cal.component(.weekday, from: day) // 1 = Sunday, 7 = Saturday
            if q.weekdaysOnly, weekday == 1 || weekday == 7 {
                weekendDays += 1
                continue
            }
            guard let open = wallClock(q.workdayStart, on: day, in: cal),
                  let close = wallClock(q.workdayEnd, on: day, in: cal)
            else { continue }
            let start = max(open, lower)
            let end = min(close, to)
            guard end > start else {
                outsideWindow += 1
                continue
            }
            let slots = gaps(start: start, end: end, busy: busy)
                .filter { $0.end.timeIntervalSince($0.start) >= minSeconds }
            days.append(FreeDay(
                day: day, slots: slots,
                windowStartsAt: from > open ? from : nil,
                windowEndsAt: to < close ? to : nil
            ))
        }
        return FreeTimeResult(days: days, weekendDays: weekendDays, outsideWindow: outsideWindow, ignored: ignored)
    }

    /// `time` on `day`'s date, in the calendar's zone. A time that doesn't
    /// exist that day (inside the hour a spring-forward skips) is moved
    /// forward by the length of the gap — 02:30 becomes 03:30 — which is what
    /// Foundation does and what apple-icloud-mcp's zonedToInstant does too.
    private static func wallClock(_ time: ClockTime, on day: Date, in cal: Calendar) -> Date? {
        var c = cal.dateComponents([.year, .month, .day], from: day)
        c.hour = time.hour
        c.minute = time.minute
        return cal.date(from: c)
    }

    private static func gaps(start: Date, end: Date, busy: [DateInterval]) -> [FreeSlot] {
        var out: [FreeSlot] = []
        var cursor = start
        for b in busy {
            if b.end <= cursor {
                continue
            }
            if b.start >= end {
                break
            }
            if b.start > cursor {
                out.append(FreeSlot(start: cursor, end: b.start))
            }
            cursor = max(cursor, b.end)
        }
        if cursor < end {
            out.append(FreeSlot(start: cursor, end: end))
        }
        return out
    }
}
