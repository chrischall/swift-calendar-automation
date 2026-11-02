@testable import CalendarAutomation
import EventKit
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!

private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
    DateComponents(year: y, month: m, day: d)
}

private func dateTime(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> DateComponents {
    DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s)
}

/// Building and reading `EKRecurrenceRule`s needs no Calendar grant, so the
/// mapping is unit-tested against real EventKit objects.
@Suite("Recurrence ⇄ EKRecurrenceRule")
struct RecurrenceEventKitTests {
    // MARK: Recurrence → EKRecurrenceRule

    @Test("weekly rule: frequency, interval and plain days")
    func weeklyToEK() {
        let rule = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(.MO), .init(.WE)])
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(rule.frequency == .weekly)
        #expect(rule.interval == 2)
        #expect(rule.daysOfTheWeek?.map(\.dayOfTheWeek) == [.monday, .wednesday])
        #expect(rule.daysOfTheWeek?.map(\.weekNumber) == [0, 0])
        #expect(rule.recurrenceEnd == nil)
    }

    @Test("ordinal days carry their week number")
    func ordinalDays() {
        let rule = Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU, ordinal: 2), .init(.FR, ordinal: -1)])
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(rule.daysOfTheWeek?.map(\.dayOfTheWeek) == [.tuesday, .friday])
        #expect(rule.daysOfTheWeek?.map(\.weekNumber) == [2, -1])
    }

    @Test("numeric BY parts map one for one")
    func numericParts() {
        let monthly = Recurrence(frequency: .monthly, daysOfMonth: [1, -1])
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(monthly.daysOfTheMonth == [1, -1])

        let yearly = Recurrence(
            frequency: .yearly, monthsOfYear: [3, 9], weeksOfYear: [10, -1], daysOfYear: [100, -1],
            setPositions: [1, -1]
        ).ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(yearly.monthsOfTheYear == [3, 9])
        #expect(yearly.weeksOfTheYear == [10, -1])
        #expect(yearly.daysOfTheYear == [100, -1])
        #expect(yearly.setPositions == [1, -1])
    }

    @Test("count becomes an occurrence-count end")
    func countEnd() {
        let rule = Recurrence(frequency: .daily, end: .count(10)).ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(rule.recurrenceEnd?.occurrenceCount == 10)
        #expect(rule.recurrenceEnd?.endDate == nil)
    }

    @Test("a date-only until ends at 23:59:59 local that day, in the event's zone")
    func dateOnlyUntil() {
        let rule = Recurrence(frequency: .weekly, end: .until(day(2027, 5, 3)))
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(rule.recurrenceEnd?.endDate == fixtureDate("2027-05-03T23:59:59", timeZone: newYork))
    }

    @Test("a date-time until ends at that local wall-clock instant")
    func dateTimeUntil() {
        let rule = Recurrence(frequency: .weekly, end: .until(dateTime(2027, 5, 3, 15, 30, 0)))
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(rule.recurrenceEnd?.endDate == fixtureDate("2027-05-03T15:30:00", timeZone: newYork))
    }

    @Test("an all-day series ends at the end of its until day, even with a time given")
    func allDayUntil() {
        let rule = Recurrence(frequency: .daily, end: .until(dateTime(2027, 5, 3, 9, 0, 0)))
            .ekRecurrenceRule(timeZone: newYork, isAllDay: true)
        #expect(rule.recurrenceEnd?.endDate == fixtureDate("2027-05-03T23:59:59", timeZone: newYork))
    }

    @Test("a non-Monday week start is written; Monday (the RFC default) is left implicit")
    func weekStartWritten() {
        let sunday = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(.MO), .init(.SU)], weekStart: .SU)
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(sunday.firstDayOfTheWeek == 1)
    }

    // MARK: EKRecurrenceRule → Recurrence

    @Test("reads every part back from a rule EventKit built")
    func readsParts() {
        let ek = EKRecurrenceRule(
            recurrenceWith: .yearly, interval: 2,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.sunday, weekNumber: 2)],
            daysOfTheMonth: nil, monthsOfTheYear: [3], weeksOfTheYear: [10], daysOfTheYear: [70],
            setPositions: [1], end: EKRecurrenceEnd(occurrenceCount: 4)
        )
        let r = Recurrence(ekRule: ek, timeZone: newYork)
        #expect(r == Recurrence(
            frequency: .yearly, interval: 2, daysOfWeek: [.init(.SU, ordinal: 2)], monthsOfYear: [3],
            weeksOfYear: [10], daysOfYear: [70], setPositions: [1], end: .count(4)
        ))
    }

    @Test("an end at 23:59:59 local reads back as a date-only until")
    func readsDateOnlyUntil() {
        let ek = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: EKRecurrenceEnd(end: fixtureDate("2027-05-03T23:59:59", timeZone: newYork))
        )
        #expect(Recurrence(ekRule: ek, timeZone: newYork).end == .until(day(2027, 5, 3)))
    }

    @Test("any other end reads back as that local wall-clock date-time")
    func readsDateTimeUntil() {
        let ek = EKRecurrenceRule(
            recurrenceWith: .daily, interval: 1,
            end: EKRecurrenceEnd(end: fixtureDate("2027-05-03T19:30:00Z"))
        )
        #expect(Recurrence(ekRule: ek, timeZone: newYork).end == .until(dateTime(2027, 5, 3, 15, 30, 0)))
    }

    @Test("EventKit's default Monday week start reads back as unset")
    func defaultWeekStartIsUnset() {
        let ek = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        #expect(Recurrence(ekRule: ek, timeZone: newYork).weekStart == nil)
    }

    // MARK: Round trips

    @Test("Recurrence → EK → Recurrence is lossless", arguments: [
        Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(day(2027, 5, 3))),
        Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(.TU), .init(.TH)], end: .count(10)),
        Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(.MO), .init(.SU)], weekStart: .SU),
        Recurrence(frequency: .daily, interval: 3, end: .until(dateTime(2027, 1, 15, 8, 0, 0))),
        Recurrence(frequency: .monthly, daysOfMonth: [15]),
        Recurrence(frequency: .monthly, daysOfMonth: [-1]),
        Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU, ordinal: 2)]),
        Recurrence(frequency: .monthly, daysOfWeek: [.init(.FR, ordinal: -1)]),
        Recurrence(
            frequency: .monthly,
            daysOfWeek: [.init(.MO), .init(.TU), .init(.WE), .init(.TH), .init(.FR)],
            setPositions: [-1]
        ),
        Recurrence(frequency: .yearly, monthsOfYear: [3]),
        Recurrence(frequency: .yearly, interval: 2, daysOfWeek: [.init(.SU, ordinal: 2)], monthsOfYear: [3]),
    ])
    func roundTrip(rule: Recurrence) {
        let ek = rule.ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        #expect(Recurrence(ekRule: ek, timeZone: newYork) == rule)
    }

    @Test("the RRULE of a read-back rule matches EventKit's own, part for part")
    func rruleMatchesEventKit() throws {
        let ek = Recurrence(frequency: .monthly, interval: 2, daysOfWeek: [.init(.TU, ordinal: 2)], end: .count(5))
            .ekRecurrenceRule(timeZone: newYork, isAllDay: false)
        let ours = Set(Recurrence(ekRule: ek, timeZone: newYork).rruleString(timeZone: newYork).split(separator: ";"))
        // EventKit's description: "EKRecurrenceRule <0x…> RRULE FREQ=…;…".
        let theirs = try #require(ek.description.split(separator: " ").last)
        #expect(ours == Set(theirs.split(separator: ";")))
    }
}
