@testable import CalendarAutomation
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!
private let utc = TimeZone(identifier: "UTC")!

private func parse(_ s: String, _ tz: TimeZone = newYork) throws(RecurrenceError) -> Recurrence {
    try Recurrence.parse(rrule: s, timeZone: tz)
}

private func parseError(_ s: String, _ tz: TimeZone = newYork) -> RecurrenceError? {
    do { _ = try parse(s, tz); return nil } catch { return error }
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
    DateComponents(year: y, month: m, day: d)
}

private func dateTime(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> DateComponents {
    DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s)
}

@Suite("Recurrence.Day")
struct RecurrenceDayTests {
    @Test("parses plain and ordinal days", arguments: [
        ("MO", Recurrence.Day(.MO)),
        ("su", Recurrence.Day(.SU)),
        ("2TU", Recurrence.Day(.TU, ordinal: 2)),
        ("+3we", Recurrence.Day(.WE, ordinal: 3)),
        ("-1FR", Recurrence.Day(.FR, ordinal: -1)),
        ("53SA", Recurrence.Day(.SA, ordinal: 53)),
    ])
    func parses(raw: String, expected: Recurrence.Day) {
        #expect(Recurrence.Day(raw) == expected)
    }

    @Test("rejects malformed days", arguments: ["", "M", "MON", "XX", "2", "--1MO", "1.5MO", "MO2", " MO", "+MO", "-MO"])
    func rejects(raw: String) {
        #expect(Recurrence.Day(raw) == nil)
    }

    @Test("formats canonically")
    func formats() {
        #expect(Recurrence.Day(.MO).string == "MO")
        #expect(Recurrence.Day(.TU, ordinal: 2).string == "2TU")
        #expect(Recurrence.Day(.FR, ordinal: -1).string == "-1FR")
    }
}

@Suite("Recurrence RRULE parsing")
struct RecurrenceParseTests {
    @Test("minimal weekly rule")
    func minimal() throws {
        #expect(try parse("FREQ=WEEKLY") == Recurrence(frequency: .weekly))
    }

    @Test("accepts an RRULE: prefix, any case, parts in any order")
    func lenientSyntax() throws {
        let expected = Recurrence(frequency: .monthly, interval: 2, daysOfWeek: [.init(.TU, ordinal: 2)], end: .count(5))
        #expect(try parse("RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU;COUNT=5") == expected)
        #expect(try parse("rrule:count=5;byday=2tu;interval=2;freq=monthly") == expected)
        #expect(try parse("RRule:Freq=Monthly;ByDay=2Tu;Count=5;Interval=2") == expected)
    }

    @Test("a single trailing semicolon is tolerated")
    func trailingSemicolon() throws {
        #expect(try parse("FREQ=DAILY;") == Recurrence(frequency: .daily))
    }

    @Test("every supported part is read")
    func everyPart() throws {
        let r = try parse(
            "FREQ=YEARLY;INTERVAL=3;BYDAY=MO,-1FR;BYMONTHDAY=1,-1;BYMONTH=3,11;BYWEEKNO=1,-53;BYYEARDAY=100,-366;BYSETPOS=1,-1;WKST=SU;COUNT=7"
        )
        #expect(r == Recurrence(
            frequency: .yearly, interval: 3,
            daysOfWeek: [.init(.MO), .init(.FR, ordinal: -1)],
            daysOfMonth: [1, -1], monthsOfYear: [3, 11], weeksOfYear: [1, -53], daysOfYear: [100, -366],
            setPositions: [1, -1], weekStart: .SU, end: .count(7)
        ))
    }

    @Test("signed numbers accept a leading +")
    func plusSign() throws {
        #expect(try parse("FREQ=MONTHLY;BYMONTHDAY=+15").daysOfMonth == [15])
    }

    @Test("UNTIL date-only is a local day")
    func untilDate() throws {
        #expect(try parse("FREQ=WEEKLY;UNTIL=20270503").end == .until(day(2027, 5, 3)))
    }

    @Test("UNTIL floating date-time is local wall clock")
    func untilFloating() throws {
        #expect(try parse("FREQ=WEEKLY;UNTIL=20270503T153000").end == .until(dateTime(2027, 5, 3, 15, 30, 0)))
    }

    @Test("UNTIL in UTC is converted to the event's time zone")
    func untilUTC() throws {
        // 19:30Z on May 3 2027 is 15:30 EDT.
        #expect(try parse("FREQ=WEEKLY;UNTIL=20270503T193000Z").end == .until(dateTime(2027, 5, 3, 15, 30, 0)))
        // 03:59:59Z on Nov 10 2026 is 22:59:59 EST the day before.
        #expect(try parse("FREQ=WEEKLY;UNTIL=20261110T035959Z").end == .until(dateTime(2026, 11, 9, 22, 59, 59)))
        #expect(try parse("FREQ=WEEKLY;UNTIL=20261110T035959Z", utc).end == .until(dateTime(2026, 11, 10, 3, 59, 59)))
    }

    // MARK: - rejections

    @Test("empty input")
    func empty() {
        #expect(parseError("") == .emptyRule)
        #expect(parseError("RRULE:") == .emptyRule)
        #expect(parseError("   ") == .emptyRule)
    }

    @Test("multi-line input and DTSTART are refused")
    func multiLine() {
        #expect(parseError("DTSTART:20261109T153000\nRRULE:FREQ=WEEKLY") == .multipleLines)
        #expect(parseError("FREQ=WEEKLY\r\n") == .multipleLines)
        #expect(parseError("DTSTART:20261109T153000") == .notAnRRule(property: "DTSTART"))
        #expect(parseError("EXRULE:FREQ=WEEKLY") == .notAnRRule(property: "EXRULE"))
        #expect(parseError("FREQ=WEEKLY;DTSTART=20261109") == .unsupportedPart("DTSTART"))
    }

    @Test("unsupported frequencies are named", arguments: ["SECONDLY", "MINUTELY", "HOURLY"])
    func subDaily(freq: String) {
        #expect(parseError("FREQ=\(freq)") == .unsupportedFrequency(freq))
    }

    @Test("an unknown frequency is an invalid value")
    func unknownFrequency() {
        #expect(parseError("FREQ=FORTNIGHTLY") == .invalidValue(part: "FREQ", value: "FORTNIGHTLY"))
    }

    @Test(
        "unsupported parts are named",
        arguments: [
            "BYSECOND=0",
            "BYMINUTE=30",
            "BYHOUR=9",
            "RSCALE=GREGORIAN",
            "SKIP=FORWARD",
            "X-NAME=foo",
            "x-apple-thing=1"
        ]
    )
    func unsupported(part: String) {
        let name = String(part.prefix { $0 != "=" }).uppercased()
        #expect(parseError("FREQ=DAILY;\(part)") == .unsupportedPart(name))
    }

    @Test("an unknown part is named, never dropped")
    func unknownPart() {
        #expect(parseError("FREQ=DAILY;BYFOO=1") == .unknownPart("BYFOO"))
    }

    @Test("repeated parts are refused")
    func repeated() {
        #expect(parseError("FREQ=DAILY;FREQ=WEEKLY") == .repeatedPart("FREQ"))
        #expect(parseError("FREQ=WEEKLY;BYDAY=MO;byday=TU") == .repeatedPart("BYDAY"))
    }

    @Test("empty values and malformed parts are refused")
    func emptyValues() {
        #expect(parseError("FREQ=WEEKLY;BYDAY=") == .emptyValue(part: "BYDAY"))
        #expect(parseError("FREQ=") == .emptyValue(part: "FREQ"))
        #expect(parseError("FREQ=WEEKLY;BYDAY") == .malformedPart("BYDAY"))
        #expect(parseError("FREQ=WEEKLY;;BYDAY=MO") == .malformedPart(""))
        #expect(parseError("FREQ=WEEKLY;BYDAY=MO,,TU") == .invalidValue(part: "BYDAY", value: "MO,,TU"))
    }

    @Test("missing FREQ")
    func missingFreq() {
        #expect(parseError("BYDAY=MO") == .missingFrequency)
    }

    @Test("malformed numbers", arguments: [
        ("INTERVAL", "two"), ("INTERVAL", "-1"), ("INTERVAL", "+2"), ("COUNT", "1.5"),
        ("COUNT", "99999999999999999999"),
        ("BYMONTHDAY", "1,x"), ("BYMONTH", "3-4"), ("BYSETPOS", "--1"), ("BYYEARDAY", "+"),
        ("BYWEEKNO", " 1"), ("BYDAY", "MO,2"), ("WKST", "2MO"), ("WKST", "MONDAY"),
    ])
    func malformed(part: String, value: String) {
        #expect(parseError("FREQ=YEARLY;\(part)=\(value)") == .invalidValue(part: part, value: value))
    }

    @Test("malformed UNTIL values", arguments: [
        "2027-05-03", "20270503T1530", "20270230", "20271303", "20270503T250000", "20270503T153000+0100", "2027050",
        "20270503Z",
    ])
    func malformedUntil(value: String) {
        #expect(parseError("FREQ=WEEKLY;UNTIL=\(value)") == .invalidValue(part: "UNTIL", value: value))
    }

    @Test("UNTIL and COUNT together")
    func untilAndCount() {
        #expect(parseError("FREQ=WEEKLY;COUNT=3;UNTIL=20270503") == .untilAndCount)
    }

    @Test("parsing is syntax only: out-of-range values are left to validate()")
    func syntaxOnly() throws {
        #expect(try parse("FREQ=YEARLY;BYMONTH=13").monthsOfYear == [13])
        #expect(try parse("FREQ=DAILY;INTERVAL=0").interval == 0)
    }
}

@Suite("Recurrence RRULE serialization")
struct RecurrenceSerializeTests {
    @Test("canonical part order, INTERVAL omitted when 1")
    func canonical() {
        let r = Recurrence(
            frequency: .yearly, interval: 2,
            daysOfWeek: [.init(.SU, ordinal: 2)], daysOfMonth: [1], monthsOfYear: [3], weeksOfYear: [10],
            daysOfYear: [-1], setPositions: [1], weekStart: .MO, end: .count(4)
        )
        #expect(r.rruleString(timeZone: newYork)
            == "FREQ=YEARLY;INTERVAL=2;BYDAY=2SU;BYMONTHDAY=1;BYMONTH=3;BYWEEKNO=10;BYYEARDAY=-1;BYSETPOS=1;WKST=MO;COUNT=4")
        #expect(Recurrence(frequency: .daily).rruleString(timeZone: newYork) == "FREQ=DAILY")
        #expect(Recurrence(frequency: .daily, interval: 1).rruleString(timeZone: newYork) == "FREQ=DAILY")
    }

    @Test("date-time UNTIL is emitted in UTC")
    func untilUTC() {
        let r = Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(dateTime(2027, 5, 3, 15, 30, 0)))
        #expect(r.rruleString(timeZone: newYork) == "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503T193000Z")
        // Before the November fall-back the offset is -4, after it -5.
        let winter = Recurrence(frequency: .daily, end: .until(dateTime(2026, 12, 1, 9, 0, 0)))
        #expect(winter.rruleString(timeZone: newYork) == "FREQ=DAILY;UNTIL=20261201T140000Z")
    }

    @Test("date-only UNTIL is emitted as YYYYMMDD")
    func untilDate() {
        let r = Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(day(2027, 5, 3)))
        #expect(r.rruleString(timeZone: newYork) == "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503")
    }

    /// Rules as Calendar.app writes them, read and written back unchanged.
    @Test("Calendar.app rules round-trip", arguments: [
        "FREQ=WEEKLY;BYDAY=MO",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
        "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
        "FREQ=MONTHLY;BYMONTHDAY=15",
        "FREQ=MONTHLY;BYMONTHDAY=-1",
        "FREQ=MONTHLY;BYDAY=2TU",
        "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2",
        "FREQ=MONTHLY;BYDAY=-1FR",
        "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
        "FREQ=YEARLY",
        "FREQ=YEARLY;BYMONTH=3",
        "FREQ=YEARLY;INTERVAL=2;BYDAY=2SU;BYMONTH=3",
        "FREQ=DAILY;INTERVAL=3;COUNT=10",
        "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503T193000Z",
        "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503",
        "FREQ=WEEKLY;BYDAY=MO;WKST=SU",
    ])
    func stringRoundTrip(rule: String) throws {
        let r = try parse(rule)
        #expect(r.rruleString(timeZone: newYork) == rule)
        #expect(try parse(r.rruleString(timeZone: newYork)) == r)
    }

    @Test("parse(serialize(x)) == x for structured values")
    func structuredRoundTrip() throws {
        let values: [Recurrence] = [
            Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(day(2027, 5, 3))),
            Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(dateTime(2027, 5, 3, 15, 30, 0))),
            Recurrence(frequency: .monthly, interval: 4, daysOfWeek: [.init(.TU, ordinal: 2)], end: .count(12)),
            Recurrence(frequency: .yearly, daysOfMonth: [-1], monthsOfYear: [2], weekStart: .SU),
        ]
        for r in values {
            for tz in try [newYork, utc, #require(TimeZone(identifier: "Asia/Kolkata"))] {
                #expect(try Recurrence.parse(rrule: r.rruleString(timeZone: tz), timeZone: tz) == r)
            }
        }
    }

    @Test("a floating UNTIL read from RRULE re-serializes in UTC")
    func floatingToUTC() throws {
        let r = try parse("FREQ=DAILY;UNTIL=20270503T153000")
        #expect(r.rruleString(timeZone: newYork) == "FREQ=DAILY;UNTIL=20270503T193000Z")
    }

    @Test("Codable round trip")
    func codable() throws {
        let r = Recurrence(frequency: .monthly, daysOfWeek: [.init(.FR, ordinal: -1)], end: .until(day(2027, 5, 3)))
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(Recurrence.self, from: data) == r)
    }
}
