@testable import CalendarAutomation
import Foundation
import Testing

private func decode(_ json: String) throws -> Recurrence.Input {
    try JSONDecoder().decode(Recurrence.Input.self, from: Data(json.utf8))
}

private func resolveError(_ json: String) throws -> RecurrenceError? {
    let input = try decode(json)
    do { _ = try input.resolve(); return nil } catch { return error }
}

@Suite("Recurrence.Input")
struct RecurrenceInputTests {
    @Test("the percussion case")
    func percussion() throws {
        let r = try decode(#"{"frequency":"weekly","daysOfWeek":["MO"],"until":"2027-05-03"}"#).resolve()
        #expect(r == Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)],
                                end: .until(DateComponents(year: 2027, month: 5, day: 3))))
    }

    @Test("every field")
    func everyField() throws {
        let r = try decode("""
        {"frequency":"Yearly","interval":2,"daysOfWeek":["2su","-1FR","+1MO"],"daysOfMonth":[1,-1],
         "monthsOfYear":[3],"weeksOfYear":[10],"daysOfYear":[-1],"setPositions":[1],"weekStart":"su","count":4}
        """).resolve()
        #expect(r == Recurrence(
            frequency: .yearly, interval: 2,
            daysOfWeek: [.init(.SU, ordinal: 2), .init(.FR, ordinal: -1), .init(.MO, ordinal: 1)],
            daysOfMonth: [1, -1], monthsOfYear: [3], weeksOfYear: [10], daysOfYear: [-1], setPositions: [1],
            weekStart: .SU, end: .count(4)
        ))
    }

    @Test("until date-time, with and without seconds")
    func untilDateTime() throws {
        #expect(try decode(#"{"frequency":"daily","until":"2027-05-03T15:30"}"#).resolve().end
            == .until(DateComponents(year: 2027, month: 5, day: 3, hour: 15, minute: 30, second: 0)))
        #expect(try decode(#"{"frequency":"daily","until":"2027-05-03T15:30:45"}"#).resolve().end
            == .until(DateComponents(year: 2027, month: 5, day: 3, hour: 15, minute: 30, second: 45)))
    }

    @Test("until with an offset or Z is refused")
    func untilOffset() throws {
        for v in [
            "2027-05-03T15:30Z",
            "2027-05-03T15:30:00Z",
            "2027-05-03T15:30-04:00",
            "2027-05-03T15:30:00+0100",
            "2027-05-03Z",
        ] {
            #expect(try resolveError(#"{"frequency":"daily","until":"\#(v)"}"#) == .untilHasOffset(v))
        }
    }

    @Test(
        "malformed until",
        arguments: [
            "20270503",
            "2027-5-3",
            "2027-02-30",
            "2027-05-03T25:00",
            "2027-05-03T15",
            "2027-05-03 15:30",
            "tomorrow",
            "",
        ]
    )
    func badUntil(v: String) throws {
        #expect(try resolveError(#"{"frequency":"daily","until":"\#(v)"}"#) == .invalidUntil(v))
    }

    @Test("until and count together")
    func untilAndCount() throws {
        #expect(try resolveError(#"{"frequency":"daily","until":"2027-05-03","count":3}"#) == .untilAndCount)
    }

    @Test("bad strings are named")
    func badStrings() throws {
        #expect(try resolveError(#"{"frequency":"hourly"}"#) == .unsupportedFrequency("hourly"))
        #expect(
            try resolveError(#"{"frequency":"fortnightly"}"#) == .invalidValue(part: "frequency", value: "fortnightly")
        )
        #expect(try resolveError(#"{"frequency":"weekly","daysOfWeek":["MO","Monday"]}"#)
            == .invalidValue(part: "daysOfWeek", value: "Monday"))
        #expect(
            try resolveError(#"{"frequency":"weekly","weekStart":"2MO"}"#) == .invalidValue(
                part: "weekStart",
                value: "2MO"
            )
        )
    }

    @Test("unknown fields are refused, never dropped")
    func unknownField() throws {
        #expect(try resolveError(#"{"frequency":"weekly","byDay":["MO"]}"#) == .unknownField("byDay"))
        #expect(try resolveError(#"{"frequency":"weekly","rrule":"FREQ=DAILY"}"#) == .unknownField("rrule"))
    }

    @Test("frequency is required; wrong JSON types fail decoding")
    func decodingFailures() {
        #expect(throws: DecodingError.self) { try decode(#"{"interval":2}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"frequency":"daily","interval":"2"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"frequency":"daily","daysOfWeek":"MO"}"#) }
    }

    @Test("resolve does not validate semantics — that is validate()'s job")
    func resolveIsNotValidate() throws {
        #expect(try decode(#"{"frequency":"daily","interval":0}"#).resolve().interval == 0)
    }

    @Test("memberwise init for programmatic callers")
    func memberwise() throws {
        let r = try Recurrence.Input(frequency: "weekly", daysOfWeek: ["MO"], count: 3).resolve()
        #expect(r == Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .count(3)))
    }
}

@Suite("Recurrence.input (read-back shape)")
struct RecurrenceInputReadBackTests {
    private static let rules: [Recurrence] = [
        Recurrence(
            frequency: .weekly,
            daysOfWeek: [.init(.MO)],
            end: .until(DateComponents(year: 2027, month: 5, day: 3))
        ),
        Recurrence(frequency: .daily, interval: 3, end: .count(10)),
        Recurrence(
            frequency: .yearly, interval: 2,
            daysOfWeek: [.init(.SU, ordinal: 2), .init(.FR, ordinal: -1)],
            daysOfMonth: [1, -1], monthsOfYear: [3], weeksOfYear: [10], daysOfYear: [-1], setPositions: [1],
            weekStart: .SU,
            end: .until(DateComponents(year: 2027, month: 5, day: 3, hour: 15, minute: 30, second: 0))
        ),
        Recurrence(frequency: .monthly),
    ]

    @Test("decode(encode(r.input)).resolve() == r", arguments: rules)
    func roundTrip(rule: Recurrence) throws {
        let data = try JSONEncoder().encode(rule.input)
        #expect(try JSONDecoder().decode(Recurrence.Input.self, from: data).resolve() == rule)
    }

    @Test("the input shape: interval omitted when 1, until as local wall clock with no offset")
    func shape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ r: Recurrence) throws -> String { try String(decoding: encoder.encode(r.input), as: UTF8.self) }

        #expect(try json(Self.rules[0]) == #"{"daysOfWeek":["MO"],"frequency":"weekly","until":"2027-05-03"}"#)
        #expect(try json(Self.rules[1]) == #"{"count":10,"frequency":"daily","interval":3}"#)
        #expect(try json(Self.rules[2]) == """
        {"daysOfMonth":[1,-1],"daysOfWeek":["2SU","-1FR"],"daysOfYear":[-1],"frequency":"yearly",\
        "interval":2,"monthsOfYear":[3],"setPositions":[1],"until":"2027-05-03T15:30:00","weekStart":"SU",\
        "weeksOfYear":[10]}
        """)
        #expect(try json(Self.rules[3]) == #"{"frequency":"monthly"}"#)
    }

    @Test("a date-time until with only some time fields still prints all three")
    func partialTime() {
        let r = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2027, month: 1, day: 2, hour: 9)))
        #expect(r.input.until == "2027-01-02T09:00:00")
    }
}

@Suite("Recurrence.seriesTimeZone")
struct SeriesTimeZoneTests {
    @Test("a timed event is read in its own zone; floating and all-day events in the current zone")
    func rule() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(Recurrence.seriesTimeZone(tokyo, isAllDay: false) == tokyo)
        #expect(Recurrence.seriesTimeZone(nil, isAllDay: false) == .current)
        #expect(Recurrence.seriesTimeZone(tokyo, isAllDay: true) == .current)
    }
}
