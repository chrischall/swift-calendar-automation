@testable import CalendarAutomation
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!
/// Mon 2026-11-09 15:30 America/New_York.
private let start = fixtureDate("2026-11-09T15:30", timeZone: newYork)

private func validationError(_ r: Recurrence, isAllDay: Bool = false) -> RecurrenceError? {
    do { try r.validate(start: start, timeZone: newYork, isAllDay: isAllDay); return nil } catch { return error }
}

@Suite("Recurrence validation")
struct RecurrenceValidationTests {
    @Test("valid rules pass", arguments: [
        Recurrence(frequency: .daily),
        Recurrence(frequency: .daily, interval: 3, end: .count(10)),
        Recurrence(frequency: .weekly),
        Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(.MO), .init(.WE)]),
        Recurrence(
            frequency: .weekly,
            daysOfWeek: [.init(.MO)],
            end: .until(DateComponents(year: 2027, month: 5, day: 3))
        ),
        Recurrence(frequency: .monthly, daysOfMonth: [15]),
        Recurrence(frequency: .monthly, daysOfMonth: [1, 15, -1]),
        Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU, ordinal: 2)]),
        Recurrence(frequency: .monthly, daysOfWeek: [.init(.FR, ordinal: -1)]),
        Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU)], setPositions: [2]),
        Recurrence(frequency: .monthly, daysOfWeek: [.MO, .TU, .WE, .TH, .FR].map { .init($0) }, setPositions: [-1]),
        Recurrence(frequency: .monthly, daysOfMonth: [1, 2, 3], setPositions: [1]),
        Recurrence(frequency: .yearly),
        Recurrence(frequency: .yearly, monthsOfYear: [3]),
        Recurrence(frequency: .yearly, interval: 2, daysOfWeek: [.init(.SU, ordinal: 2)], monthsOfYear: [3]),
        Recurrence(frequency: .yearly, daysOfWeek: [.init(.MO)], weeksOfYear: [1, -53], setPositions: [1]),
        Recurrence(frequency: .yearly, daysOfYear: [1, 366, -366]),
        Recurrence(frequency: .yearly, daysOfWeek: [.init(.MO, ordinal: 53), .init(.MO, ordinal: -53)]),
        Recurrence(frequency: .weekly, weekStart: .SU),
    ])
    func valid(r: Recurrence) {
        #expect(validationError(r) == nil)
    }

    @Test("interval must be at least 1")
    func interval() {
        #expect(validationError(Recurrence(frequency: .daily, interval: 0)) == .invalidInterval(0))
        #expect(validationError(Recurrence(frequency: .daily, interval: -2)) == .invalidInterval(-2))
    }

    @Test("count must be at least 1")
    func count() {
        #expect(validationError(Recurrence(frequency: .daily, end: .count(0))) == .invalidCount(0))
    }

    @Test("date-only until compares by local day")
    func untilDateOnly() {
        // Same local day as the start: fine (inclusive).
        #expect(
            validationError(Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 9)))) == nil
        )
        #expect(validationError(
            Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 8)))
        )
            == .untilBeforeStart(until: "2026-11-08"))
    }

    @Test("date-time until must be at or after the start instant")
    func untilDateTime() {
        let at = DateComponents(year: 2026, month: 11, day: 9, hour: 15, minute: 30, second: 0)
        #expect(validationError(Recurrence(frequency: .daily, end: .until(at))) == nil)
        let before = DateComponents(year: 2026, month: 11, day: 9, hour: 15, minute: 29, second: 59)
        #expect(validationError(Recurrence(frequency: .daily, end: .until(before)))
            == .untilBeforeStart(until: "2026-11-09T15:29:59"))
    }

    @Test("an all-day series compares a date-only until by day")
    func allDayUntil() {
        let allDayStart = fixtureDate("2026-11-09", timeZone: newYork)
        let r = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 9)))
        #expect(throws: Never.self) { try r.validate(start: allDayStart, timeZone: newYork, isAllDay: true) }
    }

    @Test("malformed until components", arguments: [
        DateComponents(year: 2027, month: 2, day: 30),
        DateComponents(year: 2027, month: 13, day: 1),
        DateComponents(month: 5, day: 3),
        DateComponents(year: 2027, month: 5, day: 3, hour: 24, minute: 0, second: 0),
        DateComponents(year: 2027, month: 5, day: 3, hour: 9),
        DateComponents(year: 2027, month: 5, day: 3, hour: 9, minute: 60, second: 0),
        DateComponents(year: 2027, month: 5, day: 3, minute: 30),
    ])
    func malformedUntil(c: DateComponents) {
        guard case .invalidUntil = validationError(Recurrence(frequency: .daily, end: .until(c))) else {
            Issue.record("expected invalidUntil for \(c)")
            return
        }
    }

    @Test("empty lists are refused")
    func emptyLists() {
        #expect(validationError(Recurrence(frequency: .weekly, daysOfWeek: [])) == .emptyList(.daysOfWeek))
        #expect(validationError(Recurrence(frequency: .monthly, daysOfMonth: [])) == .emptyList(.daysOfMonth))
        #expect(validationError(Recurrence(frequency: .yearly, monthsOfYear: [])) == .emptyList(.monthsOfYear))
        #expect(validationError(Recurrence(frequency: .yearly, weeksOfYear: [])) == .emptyList(.weeksOfYear))
        #expect(validationError(Recurrence(frequency: .yearly, daysOfYear: [])) == .emptyList(.daysOfYear))
        #expect(
            validationError(Recurrence(frequency: .monthly, daysOfMonth: [1], setPositions: [])) == .emptyList(
                .setPositions
            )
        )
    }

    @Test("duplicates are refused")
    func duplicates() {
        #expect(validationError(Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO), .init(.MO)]))
            == .duplicateValue(.daysOfWeek, value: "MO"))
        #expect(
            validationError(Recurrence(frequency: .monthly, daysOfMonth: [1, 15, 1])) == .duplicateValue(
                .daysOfMonth,
                value: "1"
            )
        )
        #expect(
            validationError(Recurrence(frequency: .yearly, monthsOfYear: [3, 3])) == .duplicateValue(
                .monthsOfYear,
                value: "3"
            )
        )
        #expect(validationError(Recurrence(frequency: .monthly, daysOfMonth: [1], setPositions: [1, 1]))
            == .duplicateValue(.setPositions, value: "1"))
    }

    @Test("values out of range", arguments: [
        (Recurrence(frequency: .monthly, daysOfMonth: [0]), RecurrenceError.valueOutOfRange(.daysOfMonth, value: 0)),
        (Recurrence(frequency: .monthly, daysOfMonth: [32]), .valueOutOfRange(.daysOfMonth, value: 32)),
        (Recurrence(frequency: .monthly, daysOfMonth: [-32]), .valueOutOfRange(.daysOfMonth, value: -32)),
        (Recurrence(frequency: .yearly, monthsOfYear: [0]), .valueOutOfRange(.monthsOfYear, value: 0)),
        (Recurrence(frequency: .yearly, monthsOfYear: [13]), .valueOutOfRange(.monthsOfYear, value: 13)),
        (Recurrence(frequency: .yearly, monthsOfYear: [-1]), .valueOutOfRange(.monthsOfYear, value: -1)),
        (Recurrence(frequency: .yearly, weeksOfYear: [54]), .valueOutOfRange(.weeksOfYear, value: 54)),
        (Recurrence(frequency: .yearly, weeksOfYear: [0]), .valueOutOfRange(.weeksOfYear, value: 0)),
        (Recurrence(frequency: .yearly, daysOfYear: [367]), .valueOutOfRange(.daysOfYear, value: 367)),
        (Recurrence(frequency: .yearly, daysOfYear: [0]), .valueOutOfRange(.daysOfYear, value: 0)),
        (Recurrence(frequency: .monthly, daysOfMonth: [1], setPositions: [0]), .valueOutOfRange(.setPositions, value: 0)),
        (
            Recurrence(frequency: .monthly, daysOfMonth: [1], setPositions: [367]),
            .valueOutOfRange(.setPositions, value: 367)
        ),
        (Recurrence(frequency: .yearly, daysOfWeek: [.init(.MO, ordinal: 54)]), .valueOutOfRange(.daysOfWeek, value: 54)),
        (Recurrence(frequency: .yearly, daysOfWeek: [.init(.MO, ordinal: 0)]), .valueOutOfRange(.daysOfWeek, value: 0)),
        // A monthly ordinal past ±5 can never match.
        (Recurrence(frequency: .monthly, daysOfWeek: [.init(.MO, ordinal: 6)]), .valueOutOfRange(.daysOfWeek, value: 6)),
        (
            Recurrence(frequency: .monthly, daysOfWeek: [.init(.MO, ordinal: -6)]),
            .valueOutOfRange(.daysOfWeek, value: -6)
        ),
    ])
    func outOfRange(r: Recurrence, expected: RecurrenceError) {
        #expect(validationError(r) == expected)
    }

    @Test("parts are tied to frequencies")
    func frequencyCombos() {
        #expect(validationError(Recurrence(frequency: .daily, daysOfWeek: [.init(.MO)]))
            == .partNotAllowed(.daysOfWeek, frequency: .daily))
        #expect(validationError(Recurrence(frequency: .weekly, daysOfMonth: [1]))
            == .partNotAllowed(.daysOfMonth, frequency: .weekly))
        #expect(validationError(Recurrence(frequency: .yearly, daysOfMonth: [1]))
            == .partNotAllowed(.daysOfMonth, frequency: .yearly))
        #expect(validationError(Recurrence(frequency: .monthly, monthsOfYear: [1]))
            == .partNotAllowed(.monthsOfYear, frequency: .monthly))
        #expect(validationError(Recurrence(frequency: .weekly, weeksOfYear: [1]))
            == .partNotAllowed(.weeksOfYear, frequency: .weekly))
        #expect(validationError(Recurrence(frequency: .daily, daysOfYear: [1]))
            == .partNotAllowed(.daysOfYear, frequency: .daily))
    }

    @Test("ordinal days are not allowed in a weekly rule")
    func weeklyOrdinal() {
        #expect(validationError(Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO), .init(.TU, ordinal: 2)]))
            == .ordinalWithWeekly(day: "2TU"))
    }

    @Test("plain days in a monthly/yearly rule need an ordinal or setPositions")
    func plainDays() {
        #expect(
            validationError(Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU)])) == .dayNeedsPosition(day: "TU")
        )
        #expect(validationError(Recurrence(frequency: .yearly, daysOfWeek: [.init(.SU, ordinal: 2), .init(.MO)]))
            == .dayNeedsPosition(day: "MO"))
    }

    @Test("setPositions needs daysOfWeek or daysOfMonth, and not daily")
    func setPositions() {
        #expect(validationError(Recurrence(frequency: .monthly, setPositions: [1])) == .setPositionsWithoutDays)
        #expect(
            validationError(Recurrence(frequency: .yearly, monthsOfYear: [3], setPositions: [1])) == .setPositionsWithoutDays
        )
        #expect(validationError(Recurrence(frequency: .daily, setPositions: [1])) == .setPositionsWithDaily)
    }

    @Test("every error explains itself and names what to do")
    func descriptions() {
        let errors: [RecurrenceError] = [
            .emptyRule, .multipleLines, .notAnRRule(property: "DTSTART"), .malformedPart("BYDAY"),
            .emptyValue(part: "BYDAY"), .repeatedPart("FREQ"), .unsupportedPart("BYHOUR"), .unknownPart("BYFOO"),
            .unsupportedFrequency("HOURLY"), .invalidValue(part: "BYDAY", value: "XX"), .missingFrequency,
            .untilAndCount, .untilHasOffset("2027-05-03T15:30Z"), .unknownField("byDay"),
            .invalidInterval(0), .invalidCount(0), .invalidUntil("2027-02-30"), .untilBeforeStart(until: "2026-11-08"),
            .emptyList(.daysOfWeek), .duplicateValue(.daysOfMonth, value: "1"),
            .valueOutOfRange(.monthsOfYear, value: 13),
            .partNotAllowed(.daysOfMonth, frequency: .weekly), .ordinalWithWeekly(day: "2TU"),
            .dayNeedsPosition(day: "TU"), .setPositionsWithoutDays, .setPositionsWithDaily,
        ]
        var seen = Set<String>()
        for e in errors {
            #expect(!e.description.isEmpty)
            #expect(seen.insert(e.description).inserted, "duplicate message: \(e.description)")
        }
        #expect(RecurrenceError.untilHasOffset("x").description.contains("drop the offset"))
        #expect(RecurrenceError.unsupportedPart("BYHOUR").description.contains("BYHOUR"))
        #expect(RecurrenceError.valueOutOfRange(.monthsOfYear, value: 13).description.contains("monthsOfYear"))
        #expect(RecurrenceError.valueOutOfRange(.monthsOfYear, value: 13).description.contains("BYMONTH"))
    }
}

@Suite("Recurrence normalization")
struct RecurrenceNormalizationTests {
    @Test("a weekly rule with no days takes the start's weekday in the event's zone")
    func weeklyFillsDay() throws {
        #expect(Recurrence(frequency: .weekly).normalized(start: start, timeZone: newYork).daysOfWeek == [.init(.MO)])
        // 2026-11-10T02:00Z is Monday evening in New York but Tuesday in UTC.
        let late = fixtureDate("2026-11-10T02:00Z")
        #expect(Recurrence(frequency: .weekly).normalized(start: late, timeZone: newYork).daysOfWeek == [.init(.MO)])
        #expect(try Recurrence(frequency: .weekly).normalized(
            start: late,
            timeZone: #require(TimeZone(identifier: "UTC"))
        ).daysOfWeek
            == [.init(.TU)])
    }

    @Test("explicit days and other frequencies are left alone")
    func unchanged() {
        let days = Recurrence(frequency: .weekly, daysOfWeek: [.init(.WE)])
        #expect(days.normalized(start: start, timeZone: newYork) == days)
        let monthly = Recurrence(frequency: .monthly)
        #expect(monthly.normalized(start: start, timeZone: newYork) == monthly)
    }
}
