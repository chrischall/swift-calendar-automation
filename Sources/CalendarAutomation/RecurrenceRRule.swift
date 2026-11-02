public import Foundation

public extension Recurrence {
    /// Parse one RFC 5545 `RRULE` value.
    ///
    /// Accepts the rule with or without an `RRULE:` prefix, keys and values
    /// in any case, parts in any order, and one trailing `;`. `UNTIL` may be
    /// `YYYYMMDD` (a local day), `YYYYMMDDTHHMMSS` (local wall clock) or
    /// `YYYYMMDDTHHMMSSZ` (UTC, converted to `timeZone`'s wall clock — pass
    /// the event's zone).
    ///
    /// Every part is either read or refused by name — nothing is dropped:
    /// sub-daily frequencies, `BYSECOND`/`BYMINUTE`/`BYHOUR`, `RSCALE`,
    /// `SKIP`, `X-…`, unknown or repeated parts, empty values, malformed
    /// numbers, and `DTSTART`/multi-line input all throw. Parsing is
    /// syntax-only; call ``validate(start:timeZone:isAllDay:)`` for ranges
    /// and combinations.
    static func parse(rrule raw: String, timeZone: TimeZone) throws(RecurrenceError) -> Recurrence {
        guard !raw.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { throw .multipleLines }
        var body = Substring(raw.trimmingCharacters(in: .whitespaces))
        if let colon = body.firstIndex(of: ":") {
            let property = body[..<colon]
            guard property.uppercased() == "RRULE" else { throw .notAnRRule(property: property.uppercased()) }
            body = body[body.index(after: colon)...]
        }
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyRule }

        var parts = body.split(separator: ";", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true {
            parts.removeLast()
        }

        var seen = Set<String>()
        var frequency: Frequency?
        var rule = Recurrence(frequency: .daily)
        var until: DateComponents?
        var count: Int?

        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { throw .malformedPart(String(part)) }
            let key = part[..<eq].uppercased()
            let value = String(part[part.index(after: eq)...])

            if Self.unsupportedParts.contains(key) || key.hasPrefix("X-") {
                throw .unsupportedPart(key)
            }
            guard Self.supportedParts.contains(key) else { throw .unknownPart(key) }
            guard seen.insert(key).inserted else { throw .repeatedPart(key) }
            guard !value.isEmpty else { throw .emptyValue(part: key) }

            switch key {
            case "FREQ":
                frequency = try parseFrequency(value, part: key)
            case "INTERVAL":
                rule.interval = try unsigned(value, part: key)
            case "COUNT":
                count = try unsigned(value, part: key)
            case "UNTIL":
                until = try parseUntil(value, timeZone: timeZone)
            case "BYDAY":
                rule.daysOfWeek = try list(value, part: key) { Day($0) }
            case "BYMONTHDAY":
                rule.daysOfMonth = try list(value, part: key, signed)
            case "BYMONTH":
                rule.monthsOfYear = try list(value, part: key, signed)
            case "BYWEEKNO":
                rule.weeksOfYear = try list(value, part: key, signed)
            case "BYYEARDAY":
                rule.daysOfYear = try list(value, part: key, signed)
            case "BYSETPOS":
                rule.setPositions = try list(value, part: key, signed)
            case "WKST":
                guard let day = Weekday(rawValue: value.uppercased()) else {
                    throw .invalidValue(part: key, value: value)
                }
                rule.weekStart = day
            default:
                throw .unknownPart(key) // unreachable: supportedParts is exhaustive above
            }
        }

        guard let frequency else { throw .missingFrequency }
        rule.frequency = frequency
        switch (until, count) {
        case (.some, .some): throw .untilAndCount
        case let (.some(u), nil): rule.end = .until(u)
        case let (nil, .some(n)): rule.end = .count(n)
        case (nil, nil): break
        }
        return rule
    }

    /// The rule as a canonical `RRULE` value (no `RRULE:` prefix), parts in
    /// a fixed order: `FREQ`, `INTERVAL` (omitted when 1), `BYDAY`,
    /// `BYMONTHDAY`, `BYMONTH`, `BYWEEKNO`, `BYYEARDAY`, `BYSETPOS`, `WKST`,
    /// then `UNTIL` or `COUNT`.
    ///
    /// A date-time `until` is emitted in UTC (`…Z`, per RFC 5545), converted
    /// from wall clock in `timeZone` (the event's zone). A date-only `until`
    /// is emitted as `YYYYMMDD` — it means "through that local day" and is
    /// what an all-day series stores. `parse(rrule:timeZone:)` with the same
    /// zone reads the string back to an equal value.
    func rruleString(timeZone: TimeZone) -> String {
        var parts = ["FREQ=\(frequency.rruleValue)"]
        if interval != 1 {
            parts.append("INTERVAL=\(interval)")
        }
        if let daysOfWeek {
            parts.append("BYDAY=" + daysOfWeek.map(\.string).joined(separator: ","))
        }
        func ints(_ name: String, _ values: [Int]?) {
            if let values {
                parts.append("\(name)=" + values.map(String.init).joined(separator: ","))
            }
        }
        ints("BYMONTHDAY", daysOfMonth)
        ints("BYMONTH", monthsOfYear)
        ints("BYWEEKNO", weeksOfYear)
        ints("BYYEARDAY", daysOfYear)
        ints("BYSETPOS", setPositions)
        if let weekStart {
            parts.append("WKST=\(weekStart.rawValue)")
        }
        switch end {
        case let .count(n):
            parts.append("COUNT=\(n)")
        case let .until(c):
            if RecurrenceDates.hasTime(c), let instant = RecurrenceDates.instant(c, in: timeZone) {
                let utc = RecurrenceDates.wallClock(instant, in: RecurrenceDates.utc)
                parts.append("UNTIL=" + RecurrenceDates.basic(utc, includeTime: true) + "Z")
            } else {
                parts.append("UNTIL=" + RecurrenceDates.basic(c, includeTime: false))
            }
        case nil:
            break
        }
        return parts.joined(separator: ";")
    }
}

private extension Recurrence {
    static let supportedParts: Set<String> = [
        "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYWEEKNO", "BYYEARDAY",
        "BYSETPOS", "WKST",
    ]
    /// Real iCalendar names this library can't represent. `DTSTART` is here
    /// so `…;DTSTART=…` is named rather than called unknown.
    static let unsupportedParts: Set<String> = ["BYSECOND", "BYMINUTE", "BYHOUR", "RSCALE", "SKIP", "DTSTART"]

    static func parseFrequency(_ value: String, part: String) throws(RecurrenceError) -> Frequency {
        let upper = value.uppercased()
        if ["SECONDLY", "MINUTELY", "HOURLY"].contains(upper) {
            throw .unsupportedFrequency(value)
        }
        guard let f = Frequency(rawValue: value.lowercased()) else { throw .invalidValue(part: part, value: value) }
        return f
    }

    static func unsigned(_ value: String, part: String) throws(RecurrenceError) -> Int {
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(value) else {
            throw .invalidValue(part: part, value: value)
        }
        return n
    }

    /// `[+-]digits`, or nil.
    static func signed(_ value: String) -> Int? {
        let digits = value.first == "+" || value.first == "-" ? value.dropFirst() : Substring(value)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    /// A comma-separated list; any bad element fails the whole part, naming
    /// its full value.
    static func list<T>(
        _ value: String, part: String, _ element: (String) -> T?
    ) throws(RecurrenceError) -> [T] {
        var out: [T] = []
        for item in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let v = element(String(item)) else { throw .invalidValue(part: part, value: value) }
            out.append(v)
        }
        return out
    }

    static func parseUntil(_ value: String, timeZone: TimeZone) throws(RecurrenceError) -> DateComponents {
        let pattern = /^([0-9]{4})([0-9]{2})([0-9]{2})(?:[Tt]([0-9]{2})([0-9]{2})([0-9]{2})([Zz])?)?$/
        guard let m = value.wholeMatch(of: pattern),
              let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3),
              RecurrenceDates.isValidDate(year: y, month: mo, day: d)
        else { throw .invalidValue(part: "UNTIL", value: value) }
        guard let hs = m.4, let ms = m.5, let ss = m.6 else { return RecurrenceDates.day(y, mo, d) }
        guard let h = Int(hs), let mi = Int(ms), let s = Int(ss),
              RecurrenceDates.isValidTime(hour: h, minute: mi, second: s)
        else { throw .invalidValue(part: "UNTIL", value: value) }
        let local = RecurrenceDates.dateTime(y, mo, d, h, mi, s)
        guard m.7 != nil else { return local }
        guard let instant = RecurrenceDates.instant(local, in: RecurrenceDates.utc) else {
            throw .invalidValue(part: "UNTIL", value: value)
        }
        return RecurrenceDates.wallClock(instant, in: timeZone)
    }
}
