public import Foundation

/// A repeat rule for a calendar event: the subset of RFC 5545 `RRULE` that
/// EventKit can store (daily/weekly/monthly/yearly, with the `BY…` parts
/// below).
///
/// The value is plain data; nothing here touches EventKit. Build one
/// directly, from the tool-facing JSON shape (``Input``), or from an `RRULE`
/// string (``parse(rrule:timeZone:)``), then check it against the event it
/// will repeat with ``validate(start:timeZone:isAllDay:)``. Parsing and
/// decoding are syntax-only — an out-of-range or contradictory rule is
/// reported by `validate`, so a rule read back from a store can always be
/// represented and shown.
public struct Recurrence: Sendable, Equatable, Hashable, Codable {
    /// How often the rule repeats, before `interval` is applied.
    public enum Frequency: String, Sendable, Codable, CaseIterable {
        case daily, weekly, monthly, yearly

        /// The `FREQ=` value.
        var rruleValue: String { rawValue.uppercased() }
    }

    /// A day of the week, as RFC 5545 spells it.
    public enum Weekday: String, Sendable, Codable, CaseIterable {
        case MO, TU, WE, TH, FR, SA, SU

        /// Foundation's `Calendar` weekday number (1 = Sunday … 7 = Saturday).
        var calendarWeekday: Int {
            switch self {
            case .SU: 1
            case .MO: 2
            case .TU: 3
            case .WE: 4
            case .TH: 5
            case .FR: 6
            case .SA: 7
            }
        }

        init?(calendarWeekday: Int) {
            guard let match = Self.allCases.first(where: { $0.calendarWeekday == calendarWeekday }) else { return nil }
            self = match
        }
    }

    /// One `BYDAY` entry: a weekday, optionally with an ordinal — `MO`
    /// (every Monday), `2TU` (the second Tuesday), `-1FR` (the last Friday).
    ///
    /// Encodes as its `RRULE` spelling (`"2TU"`), the same shape ``Input``
    /// accepts.
    public struct Day: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
        public var weekday: Weekday
        /// ±1…±53 within the period (±1…±5 in a monthly rule); nil = every
        /// such weekday.
        public var ordinal: Int?

        public init(_ weekday: Weekday, ordinal: Int? = nil) {
            self.weekday = weekday
            self.ordinal = ordinal
        }

        /// Parse `MO`, `2TU`, `+3WE`, `-1FR` (case-insensitive). Nil for
        /// anything else. An ordinal of 0 parses (it is a range error, not a
        /// syntax error) and is refused by `validate`.
        public init?(_ string: String) {
            let pattern = /^([+-]?[0-9]{1,2})?([A-Za-z]{2})$/
            guard let m = string.wholeMatch(of: pattern),
                  let weekday = Weekday(rawValue: m.2.uppercased())
            else { return nil }
            if let raw = m.1 {
                guard let n = Int(raw) else { return nil }
                self.init(weekday, ordinal: n)
            } else {
                self.init(weekday)
            }
        }

        /// The `RRULE` spelling: `MO`, `2TU`, `-1FR`.
        public var string: String { (ordinal.map(String.init) ?? "") + weekday.rawValue }

        public var description: String { string }

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let day = Day(raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "not a day: \(raw)"
                ))
            }
            self = day
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(string)
        }
    }

    /// When the series stops.
    public enum End: Sendable, Equatable, Hashable, Codable {
        /// The last day (`year`/`month`/`day`) or instant (plus
        /// `hour`/`minute`/`second`) an occurrence may start, as local wall
        /// clock in the event's time zone. Inclusive. Date-times are kept
        /// with all three time fields set.
        case until(DateComponents)
        /// The total number of occurrences, the first one included.
        case count(Int)
    }

    /// The rule's parts, by their tool-facing name. Used in error messages,
    /// which name both spellings.
    public enum Field: String, Sendable, CaseIterable {
        case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
        case setPositions, weekStart, until, count

        /// The `RRULE` part name.
        public var rrulePart: String {
            switch self {
            case .frequency: "FREQ"
            case .interval: "INTERVAL"
            case .daysOfWeek: "BYDAY"
            case .daysOfMonth: "BYMONTHDAY"
            case .monthsOfYear: "BYMONTH"
            case .weeksOfYear: "BYWEEKNO"
            case .daysOfYear: "BYYEARDAY"
            case .setPositions: "BYSETPOS"
            case .weekStart: "WKST"
            case .until: "UNTIL"
            case .count: "COUNT"
            }
        }

        /// `daysOfMonth (BYMONTHDAY)`.
        var label: String { "\(rawValue) (\(rrulePart))" }
    }

    public var frequency: Frequency
    /// Every `interval` periods. At least 1.
    public var interval: Int
    /// `BYDAY`. Weekly: plain days. Monthly/yearly: ordinal days, or plain
    /// days narrowed by `setPositions`.
    public var daysOfWeek: [Day]?
    /// `BYMONTHDAY`, monthly only: 1…31 or -31…-1 (-1 = last day).
    public var daysOfMonth: [Int]?
    /// `BYMONTH`, yearly only: 1…12.
    public var monthsOfYear: [Int]?
    /// `BYWEEKNO`, yearly only: ±1…53.
    public var weeksOfYear: [Int]?
    /// `BYYEARDAY`, yearly only: ±1…366.
    public var daysOfYear: [Int]?
    /// `BYSETPOS`: ±1…366, picks from the days the other parts select in
    /// each period (`-1` = the last one).
    public var setPositions: [Int]?
    /// `WKST`: the first day of the week.
    public var weekStart: Weekday?
    /// Nil: repeats forever.
    public var end: End?

    public init(
        frequency: Frequency,
        interval: Int = 1,
        daysOfWeek: [Day]? = nil,
        daysOfMonth: [Int]? = nil,
        monthsOfYear: [Int]? = nil,
        weeksOfYear: [Int]? = nil,
        daysOfYear: [Int]? = nil,
        setPositions: [Int]? = nil,
        weekStart: Weekday? = nil,
        end: End? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.weeksOfYear = weeksOfYear
        self.daysOfYear = daysOfYear
        self.setPositions = setPositions
        self.weekStart = weekStart
        self.end = end
    }

    /// The zone a series' rule is read in — the zone its `until` is wall
    /// clock in and its occurrences are expanded in: the event's own zone,
    /// or the current zone for a floating event and for every all-day event
    /// (all-day events are floating; they are shown in whatever zone the
    /// user is in).
    ///
    /// - Parameters:
    ///   - timeZone: the event's zone; nil for a floating event.
    ///   - isAllDay: whether the event is all-day.
    public static func seriesTimeZone(_ timeZone: TimeZone?, isAllDay: Bool) -> TimeZone {
        isAllDay ? .current : timeZone ?? .current
    }

    /// The rule with implied parts made explicit: a weekly rule with no
    /// `daysOfWeek` repeats on the start's weekday (in `timeZone`), so that
    /// day is filled in. Everything else is returned unchanged.
    public func normalized(start: Date, timeZone: TimeZone) -> Recurrence {
        guard frequency == .weekly, daysOfWeek == nil else { return self }
        var copy = self
        let weekday = RecurrenceDates.calendar(timeZone).component(.weekday, from: start)
        copy.daysOfWeek = Weekday(calendarWeekday: weekday).map { [Day($0)] }
        return copy
    }
}
