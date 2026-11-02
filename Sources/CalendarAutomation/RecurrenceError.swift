/// Why a repeat rule was refused. Each case names the offending part and
/// says what to do about it.
public enum RecurrenceError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: RRULE syntax

    /// The rule is empty.
    case emptyRule
    /// The input has more than one line (e.g. `DTSTART` + `RRULE`).
    case multipleLines
    /// The input is a different iCalendar property (`DTSTART:…`, `EXRULE:…`).
    case notAnRRule(property: String)
    /// A part without `=`.
    case malformedPart(String)
    /// A part with nothing after `=`.
    case emptyValue(part: String)
    /// The same part given twice.
    case repeatedPart(String)
    /// A real RFC 5545 part this library can't store (`BYHOUR`, `X-…`, …).
    case unsupportedPart(String)
    /// A part that isn't in RFC 5545.
    case unknownPart(String)
    /// `SECONDLY`, `MINUTELY` or `HOURLY`.
    case unsupportedFrequency(String)
    /// A value that doesn't parse (`part` is the RRULE or JSON field name).
    case invalidValue(part: String, value: String)
    /// No `FREQ`.
    case missingFrequency

    // MARK: Structured input

    /// Both an end date and an occurrence count.
    case untilAndCount
    /// `until` carried a UTC offset or `Z`.
    case untilHasOffset(String)
    /// A JSON field this shape doesn't have.
    case unknownField(String)

    // MARK: Validation

    case invalidInterval(Int)
    case invalidCount(Int)
    /// An `until` that isn't a real date/time (the value as given).
    case invalidUntil(String)
    /// `until` falls before the series' first occurrence.
    case untilBeforeStart(until: String)
    case emptyList(Recurrence.Field)
    case duplicateValue(Recurrence.Field, value: String)
    case valueOutOfRange(Recurrence.Field, value: Int)
    /// A part used with a frequency it doesn't belong to.
    case partNotAllowed(Recurrence.Field, frequency: Recurrence.Frequency)
    /// An ordinal day (`2TU`) in a weekly rule.
    case ordinalWithWeekly(day: String)
    /// A plain day (`TU`) in a monthly/yearly rule with no `setPositions`.
    case dayNeedsPosition(day: String)
    case setPositionsWithoutDays
    case setPositionsWithDaily

    public var description: String {
        switch self {
        case .emptyRule:
            "The repeat rule is empty. Give at least FREQ, e.g. FREQ=WEEKLY;BYDAY=MO."
        case .multipleLines:
            "The repeat rule must be a single RRULE line. Pass only the RRULE (no DTSTART, EXDATE or other lines); the start comes from the event."
        case let .notAnRRule(property):
            "\(property) is not an RRULE. Pass only the rule itself, e.g. FREQ=WEEKLY;BYDAY=MO (an RRULE: prefix is optional); the start comes from the event."
        case let .malformedPart(part):
            "Repeat rule part '\(part)' is not NAME=VALUE. Separate parts with single semicolons, e.g. FREQ=WEEKLY;BYDAY=MO."
        case let .emptyValue(part):
            "Repeat rule part \(part) has no value. Give a value or leave the part out."
        case let .repeatedPart(part):
            "Repeat rule part \(part) is given more than once. Give it once, with comma-separated values if it takes a list."
        case let .unsupportedPart(part):
            "Repeat rule part \(part) isn't supported (Calendar can't store it). Remove \(part); supported parts are FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYWEEKNO, BYYEARDAY, BYSETPOS and WKST."
        case let .unknownPart(part):
            "Repeat rule part \(part) is not an RRULE part. Check the spelling; supported parts are FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYWEEKNO, BYYEARDAY, BYSETPOS and WKST."
        case let .unsupportedFrequency(value):
            "Repeat frequency \(value) isn't supported: Calendar repeats at most daily. Use daily, weekly, monthly or yearly."
        case let .invalidValue(part, value):
            "'\(value)' is not a valid value for \(part). \(Self.hint(for: part))"
        case .missingFrequency:
            "The repeat rule has no FREQ. Add FREQ=DAILY, WEEKLY, MONTHLY or YEARLY."
        case .untilAndCount:
            "A repeat rule can end on a date (until) or after a number of occurrences (count), not both. Give one."
        case let .untilHasOffset(value):
            "until '\(value)' carries a time zone offset, but until is local wall-clock time in the event's time zone; drop the offset (e.g. 2027-05-03 or 2027-05-03T15:30)."
        case let .unknownField(name):
            "Repeat rule field '\(name)' is not recognised. Use frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear, setPositions, weekStart, until or count."
        case let .invalidInterval(n):
            "interval \(n) is invalid: it must be 1 or more (1 = every period, 2 = every other one)."
        case let .invalidCount(n):
            "count \(n) is invalid: it must be 1 or more, and counts the first occurrence."
        case let .invalidUntil(value):
            "until '\(value)' is not a real date. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS] in the event's local time."
        case let .untilBeforeStart(until):
            "until \(until) is before the event's start, so the series would never repeat. Set until on or after the start."
        case let .emptyList(field):
            "\(field.label) is an empty list. Give at least one value or leave it out."
        case let .duplicateValue(field, value):
            "\(field.label) lists \(value) more than once. List each value once."
        case let .valueOutOfRange(field, value):
            "\(value) is out of range for \(field.label): \(Self.range(of: field))."
        case let .partNotAllowed(field, frequency):
            "\(field.label) can't be used in a \(frequency.rawValue) rule; it only applies to \(Self.frequencies(for: field)) rules. Remove it or change the frequency."
        case let .ordinalWithWeekly(day):
            "\(day) has an ordinal, which a weekly rule can't use. Use the plain day (e.g. TU), or a monthly/yearly rule for 'the 2nd Tuesday'."
        case let .dayNeedsPosition(day):
            "\(day) in a monthly or yearly rule needs an ordinal (e.g. 2\(day) for the second, -1\(day) for the last) or setPositions (BYSETPOS) to pick which one."
        case .setPositionsWithoutDays:
            "setPositions (BYSETPOS) picks from the days a rule selects, so it needs daysOfWeek (BYDAY) or daysOfMonth (BYMONTHDAY). Add one or remove setPositions."
        case .setPositionsWithDaily:
            "setPositions (BYSETPOS) can't be used in a daily rule. Use weekly, monthly or yearly, or remove setPositions."
        }
    }

    private static func range(of field: Recurrence.Field) -> String {
        switch field {
        case .daysOfWeek: "a day's ordinal must be 1...53 or -53...-1 (1...5 or -5...-1 in a monthly rule)"
        case .daysOfMonth: "use 1...31, or -31...-1 to count from the end of the month"
        case .monthsOfYear: "use 1...12"
        case .weeksOfYear: "use 1...53, or -53...-1 to count from the end of the year"
        case .daysOfYear: "use 1...366, or -366...-1 to count from the end of the year"
        case .setPositions: "use 1...366, or -366...-1 to count from the end (-1 = last)"
        case .interval, .count: "use 1 or more"
        case .frequency, .weekStart, .until: "see the documentation"
        }
    }

    private static func frequencies(for field: Recurrence.Field) -> String {
        switch field {
        case .daysOfWeek: "weekly, monthly or yearly"
        case .daysOfMonth: "monthly"
        case .monthsOfYear, .weeksOfYear, .daysOfYear: "yearly"
        case .setPositions: "weekly, monthly or yearly"
        default: "any"
        }
    }

    private static func hint(for part: String) -> String {
        switch part.uppercased() {
        case "FREQ", "FREQUENCY": "Use daily, weekly, monthly or yearly."
        case "INTERVAL", "COUNT": "Use a whole number, 1 or more."
        case "UNTIL": "Use YYYYMMDD, YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ."
        case "BYDAY", "DAYSOFWEEK": "Use comma-separated days like MO, 2TU or -1FR."
        case "WKST", "WEEKSTART": "Use one of MO, TU, WE, TH, FR, SA, SU."
        default: "Use comma-separated whole numbers."
        }
    }
}
