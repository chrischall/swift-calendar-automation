import Foundation

public extension Recurrence {
    /// The repeat rule as a tool's JSON argument:
    ///
    /// ```json
    /// {"frequency": "weekly", "interval": 2, "daysOfWeek": ["MO", "2TU", "-1FR"],
    ///  "daysOfMonth": [1, -1], "monthsOfYear": [3], "weeksOfYear": [10],
    ///  "daysOfYear": [100], "setPositions": [-1], "weekStart": "MO",
    ///  "until": "2027-05-03" | "2027-05-03T15:30[:00]", "count": 10}
    /// ```
    ///
    /// Only `frequency` is required. Strings are case-insensitive. `until` is
    /// local wall clock in the event's time zone, inclusive, with no offset.
    /// Decoding keeps the raw values; ``resolve()`` turns them into a
    /// ``Recurrence``, refusing unknown fields rather than ignoring them.
    struct Input: Decodable, Sendable, Equatable {
        public var frequency: String
        public var interval: Int?
        public var daysOfWeek: [String]?
        public var daysOfMonth: [Int]?
        public var monthsOfYear: [Int]?
        public var weeksOfYear: [Int]?
        public var daysOfYear: [Int]?
        public var setPositions: [Int]?
        public var weekStart: String?
        public var until: String?
        public var count: Int?
        /// JSON keys this shape doesn't have, in order; `resolve` refuses them.
        var unknownFields: [String] = []

        public init(
            frequency: String,
            interval: Int? = nil,
            daysOfWeek: [String]? = nil,
            daysOfMonth: [Int]? = nil,
            monthsOfYear: [Int]? = nil,
            weeksOfYear: [Int]? = nil,
            daysOfYear: [Int]? = nil,
            setPositions: [Int]? = nil,
            weekStart: String? = nil,
            until: String? = nil,
            count: Int? = nil
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
            self.until = until
            self.count = count
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
            case setPositions, weekStart, until, count
        }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frequency = try c.decode(String.self, forKey: .frequency)
            interval = try c.decodeIfPresent(Int.self, forKey: .interval)
            daysOfWeek = try c.decodeIfPresent([String].self, forKey: .daysOfWeek)
            daysOfMonth = try c.decodeIfPresent([Int].self, forKey: .daysOfMonth)
            monthsOfYear = try c.decodeIfPresent([Int].self, forKey: .monthsOfYear)
            weeksOfYear = try c.decodeIfPresent([Int].self, forKey: .weeksOfYear)
            daysOfYear = try c.decodeIfPresent([Int].self, forKey: .daysOfYear)
            setPositions = try c.decodeIfPresent([Int].self, forKey: .setPositions)
            weekStart = try c.decodeIfPresent(String.self, forKey: .weekStart)
            until = try c.decodeIfPresent(String.self, forKey: .until)
            count = try c.decodeIfPresent(Int.self, forKey: .count)
            unknownFields = try decoder.container(keyedBy: AnyKey.self).allKeys
                .map(\.stringValue)
                .filter { CodingKeys(stringValue: $0) == nil }
                .sorted()
        }

        /// The ``Recurrence`` this input describes. Throws for unknown
        /// fields, unparseable strings, `until` and `count` together, and an
        /// `until` carrying an offset. Ranges and combinations are left to
        /// ``Recurrence/validate(start:timeZone:isAllDay:)``.
        public func resolve() throws(RecurrenceError) -> Recurrence {
            if let unknown = unknownFields.first {
                throw .unknownField(unknown)
            }

            let lower = frequency.lowercased()
            if ["secondly", "minutely", "hourly"].contains(lower) {
                throw .unsupportedFrequency(frequency)
            }
            guard let freq = Frequency(rawValue: lower) else {
                throw .invalidValue(part: "frequency", value: frequency)
            }

            var days: [Day]?
            if let daysOfWeek {
                var parsed: [Day] = []
                for raw in daysOfWeek {
                    guard let day = Day(raw) else { throw .invalidValue(part: "daysOfWeek", value: raw) }
                    parsed.append(day)
                }
                days = parsed
            }

            var wkst: Weekday?
            if let weekStart {
                guard let w = Weekday(rawValue: weekStart.uppercased()) else {
                    throw .invalidValue(part: "weekStart", value: weekStart)
                }
                wkst = w
            }

            let end: End?
            switch (until, count) {
            case (.some, .some): throw .untilAndCount
            case let (.some(u), nil): end = try .until(Self.parseUntil(u))
            case let (nil, .some(n)): end = .count(n)
            case (nil, nil): end = nil
            }

            return Recurrence(
                frequency: freq, interval: interval ?? 1, daysOfWeek: days, daysOfMonth: daysOfMonth,
                monthsOfYear: monthsOfYear, weeksOfYear: weeksOfYear, daysOfYear: daysOfYear,
                setPositions: setPositions, weekStart: wkst, end: end
            )
        }

        /// `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS]`, local wall clock.
        private static func parseUntil(_ value: String) throws(RecurrenceError) -> DateComponents {
            let pattern = /^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[Tt]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?$/
            guard let m = value.wholeMatch(of: pattern) else {
                let offset = /^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]+)?)?)?(?:[Zz]|[+-][0-9]{2}(?::?[0-9]{2})?)$/
                if value.wholeMatch(of: offset) != nil {
                    throw .untilHasOffset(value)
                }
                throw .invalidUntil(value)
            }
            guard let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3),
                  RecurrenceDates.isValidDate(year: y, month: mo, day: d)
            else { throw .invalidUntil(value) }
            guard let hs = m.4, let ms = m.5 else { return RecurrenceDates.day(y, mo, d) }
            guard let h = Int(hs), let mi = Int(ms), let s = Int(m.6 ?? "00"),
                  RecurrenceDates.isValidTime(hour: h, minute: mi, second: s)
            else { throw .invalidUntil(value) }
            return RecurrenceDates.dateTime(y, mo, d, h, mi, s)
        }
    }
}
