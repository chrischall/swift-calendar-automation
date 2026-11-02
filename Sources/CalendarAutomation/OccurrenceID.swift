public import Foundation

/// The id of one occurrence of a recurring event:
/// `<eventIdentifier>#occ=<occurrence start, ISO-8601 UTC>`, for example
/// `ABC:123#occ=2026-11-09T20:30:00Z`.
///
/// This type is the one place that format is written and read. Callers build
/// ids with ``init(eventIdentifier:occurrenceDate:)`` + ``string`` and split
/// them with ``init(parsing:)``; nothing else should format or parse the
/// timestamp half, so the wire format can't drift between producer and
/// consumer. Ids are handed to clients and come back later, so the format is
/// frozen: the timestamp is whole seconds in UTC with a `Z` designator, and
/// parsing still accepts every spelling earlier releases accepted.
///
/// `occurrenceDate` is EventKit's `occurrenceDate` — the occurrence's
/// *original* start, which stays put when that occurrence alone is re-timed.
public struct OccurrenceID: Hashable, Sendable, CustomStringConvertible {
    /// EventKit's `eventIdentifier`, shared by every occurrence of the series.
    public let eventIdentifier: String
    /// The occurrence's original start.
    public let occurrenceDate: Date

    private static let marker = "#occ="

    public init(eventIdentifier: String, occurrenceDate: Date) {
        self.eventIdentifier = eventIdentifier
        self.occurrenceDate = occurrenceDate
    }

    /// Split an occurrence id, or nil when `raw` isn't one.
    ///
    /// The marker is looked for from the end and only counts when a valid
    /// UTC timestamp ending in `Z` follows it and a non-empty identifier
    /// precedes it, so an identifier that happens to contain `#occ=` (CalDAV
    /// UIDs are free text) is not one, and an occurrence id whose identifier
    /// contains it still splits at the right place.
    public init?(parsing raw: String) {
        guard let r = raw.range(of: Self.marker, options: .backwards),
              !raw[..<r.lowerBound].isEmpty,
              raw[r.upperBound...].hasSuffix("Z"),
              let date = OccurrenceTimestamp.parse(raw[r.upperBound...])
        else { return nil }
        self.init(eventIdentifier: String(raw[..<r.lowerBound]), occurrenceDate: date)
    }

    /// The id as handed to clients. Sub-second precision is dropped (not
    /// rounded); matching an occurrence allows for that.
    public var string: String { eventIdentifier + Self.marker + OccurrenceTimestamp.format(occurrenceDate) }

    public var description: String { string }
}

/// The timestamp half of an ``OccurrenceID``. Private to this file: it is not
/// a general ISO-8601 parser, only the grammar occurrence ids have used.
private enum OccurrenceTimestamp {
    private static let utc = TimeZone(identifier: "UTC")!

    /// `2026-11-09T20:30:00Z` — whole seconds, UTC, `Z`.
    static func format(_ date: Date) -> String {
        date.formatted(
            .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .omitted)
        )
    }

    /// Leading whitespace (`CharacterSet.whitespaces`), then `YYYY-MM-DD`, an optional time
    /// (`T`/`t`/space, `HH:MM`, optional `:SS`, optional `.`/`,` fraction),
    /// then `Z`. Nothing may follow. Out-of-range fields are refused; a
    /// leap second (`:60`) rolls into the next minute.
    static func parse(_ s: Substring) -> Date? {
        var sc = Cursor(s.drop { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) })
        guard let year = sc.digits(4), sc.match("-"),
              let month = sc.digits(2), sc.match("-"),
              let day = sc.digits(2)
        else { return nil }

        var hour = 0, minute = 0, second = 0
        var fraction: TimeInterval = 0
        if sc.matchAny("T", "t", " ") {
            guard let h = sc.digits(2), sc.match(":"), let m = sc.digits(2) else { return nil }
            hour = h
            minute = m
            if sc.match(":") {
                guard let sec = sc.digits(2) else { return nil }
                second = sec
                if sc.matchAny(".", ",") {
                    guard let f = sc.fraction() else { return nil }
                    fraction = f
                }
            }
        }
        guard sc.match("Z"), sc.atEnd,
              (1 ... 12).contains(month), day >= 1, day <= daysInMonth(month, year),
              hour <= 23, minute <= 59, second <= 60
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = cal.date(from: comps) else { return nil }
        return fraction == 0 ? base : base.addingTimeInterval(fraction)
    }

    private static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: 0
        }
    }

    /// Forward-only cursor: every accessor consumes exactly what it matched
    /// or nothing, so `atEnd` is a trustworthy "fully parsed" check.
    private struct Cursor {
        private let chars: [Character]
        private var i = 0

        init(_ s: Substring) { chars = Array(s) }

        var atEnd: Bool { i >= chars.count }

        mutating func digits(_ n: Int) -> Int? {
            guard i + n <= chars.count else { return nil }
            var value = 0
            for k in i ..< (i + n) {
                guard chars[k].isASCII, let d = chars[k].wholeNumberValue else { return nil }
                value = value * 10 + d
            }
            i += n
            return value
        }

        mutating func match(_ c: Character) -> Bool {
            guard !atEnd, chars[i] == c else { return false }
            i += 1
            return true
        }

        mutating func matchAny(_ candidates: Character...) -> Bool {
            guard !atEnd, candidates.contains(chars[i]) else { return false }
            i += 1
            return true
        }

        /// One or more ASCII digits, as a sub-second interval.
        mutating func fraction() -> TimeInterval? {
            let start = i
            while !atEnd, chars[i].isASCII, chars[i].isNumber {
                i += 1
            }
            guard i > start else { return nil }
            return TimeInterval("0." + String(chars[start ..< i]))
        }
    }
}
