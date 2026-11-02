@testable import CalendarAutomation
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!
/// Mon 2026-11-09 15:30 America/New_York.
private let start = fixtureDate("2026-11-09T15:30", timeZone: newYork)

private func summary(_ r: Recurrence, start: Date = start, isAllDay: Bool = false) -> String {
    r.summary(start: start, timeZone: newYork, isAllDay: isAllDay)
}

private func day(_ w: Recurrence.Weekday, _ n: Int? = nil) -> Recurrence.Day { .init(w, ordinal: n) }
private let weekdays: [Recurrence.Day] = [.MO, .TU, .WE, .TH, .FR].map { day($0) }

@Suite("Recurrence summary")
struct RecurrenceSummaryTests {
    @Test("percussion case")
    func percussion() {
        let r = Recurrence(
            frequency: .weekly, daysOfWeek: [day(.MO)], end: .until(DateComponents(year: 2027, month: 5, day: 3))
        )
        #expect(summary(r) == "Weekly on Monday, until May 3, 2027 (26 occurrences)")
    }

    @Test("fixed forms", arguments: [
        (Recurrence(frequency: .daily), "Daily"),
        (Recurrence(frequency: .daily, interval: 3), "Every 3 days"),
        (Recurrence(frequency: .weekly), "Weekly on Monday"),
        (Recurrence(frequency: .weekly, daysOfWeek: [day(.MO)]), "Weekly on Monday"),
        (Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [day(.MO), day(.WE)]),
         "Every 2 weeks on Monday and Wednesday"),
        (Recurrence(frequency: .weekly, daysOfWeek: [day(.FR), day(.MO), day(.WE)]),
         "Weekly on Monday, Wednesday and Friday"),
        (Recurrence(frequency: .weekly, daysOfWeek: weekdays), "Weekly on weekdays"),
        (Recurrence(frequency: .monthly), "Monthly on day 9"),
        (Recurrence(frequency: .monthly, daysOfMonth: [15]), "Monthly on day 15"),
        (Recurrence(frequency: .monthly, daysOfMonth: [15, 1]), "Monthly on days 1 and 15"),
        (Recurrence(frequency: .monthly, daysOfMonth: [-1]), "Monthly on the last day"),
        (Recurrence(frequency: .monthly, daysOfMonth: [1, -2]), "Monthly on day 1 and the 2nd-to-last day"),
        (Recurrence(frequency: .monthly, interval: 3, daysOfMonth: [1]), "Every 3 months on day 1"),
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.TU, 2)]), "Monthly on the 2nd Tuesday"),
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.TU)], setPositions: [2]), "Monthly on the 2nd Tuesday"),
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.FR, -1)]), "Monthly on the last Friday"),
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.MO, 1), day(.MO, 3)]),
         "Monthly on the 1st Monday and the 3rd Monday"),
        (Recurrence(frequency: .monthly, daysOfWeek: weekdays, setPositions: [-1]), "Monthly on the last weekday"),
        (Recurrence(frequency: .monthly, daysOfWeek: weekdays, setPositions: [1, -1]),
         "Monthly on the 1st and last weekday"),
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.SA), day(.SU)], setPositions: [1]),
         "Monthly on the 1st weekend day"),
        (Recurrence(frequency: .yearly), "Yearly on November 9"),
        (Recurrence(frequency: .yearly, monthsOfYear: [3]), "Yearly in March on day 9"),
        (Recurrence(frequency: .yearly, monthsOfYear: [11]), "Yearly on November 9"),
        (Recurrence(frequency: .yearly, interval: 2, daysOfWeek: [day(.SU, 2)], monthsOfYear: [3]),
         "Every 2 years in March on the 2nd Sunday"),
        (Recurrence(frequency: .yearly, daysOfWeek: weekdays, monthsOfYear: [3, 6], setPositions: [-1]),
         "Yearly in March and June on the last weekday"),
        (Recurrence(frequency: .yearly, daysOfYear: [100]), "Yearly on day 100 of the year"),
        (Recurrence(frequency: .yearly, daysOfYear: [-1]), "Yearly on the last day of the year"),
        (Recurrence(frequency: .yearly, daysOfYear: [1, 100], weekStart: .SU), "Yearly on days 1 and 100 of the year"),
    ])
    func fixedForms(r: Recurrence, expected: String) {
        #expect(summary(r) == expected)
    }

    @Test("yearly from a March 15 start")
    func yearlyMarch15() {
        let march15 = fixtureDate("2027-03-15T09:00", timeZone: newYork)
        #expect(summary(Recurrence(frequency: .yearly), start: march15) == "Yearly on March 15")
        #expect(summary(Recurrence(frequency: .yearly, monthsOfYear: [3]), start: march15) == "Yearly on March 15")
    }

    @Test("end suffixes")
    func endSuffixes() {
        #expect(summary(Recurrence(frequency: .daily, end: .count(10))) == "Daily, 10 times")
        #expect(summary(Recurrence(frequency: .daily, end: .count(1))) == "Daily, once")
        let one = Recurrence(frequency: .weekly, end: .until(DateComponents(year: 2026, month: 11, day: 9)))
        #expect(summary(one) == "Weekly on Monday, until November 9, 2026 (1 occurrence)")
        let timed = Recurrence(frequency: .daily, end: .until(RecurrenceDates.dateTime(2026, 11, 11, 15, 30, 0)))
        #expect(summary(timed) == "Daily, until November 11, 2026 at 3:30 PM (3 occurrences)")
        let morning = Recurrence(frequency: .daily, end: .until(RecurrenceDates.dateTime(2026, 11, 12, 0, 5, 0)))
        #expect(summary(morning) == "Daily, until November 12, 2026 at 12:05 AM (3 occurrences)")
        let long = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2030, month: 1, day: 1)))
        #expect(summary(long) == "Daily, until January 1, 2030 (1000+ occurrences)")
    }

    @Test("week start is stated when it changes which days a rule hits")
    func weekStart() {
        let biweekly = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [day(.MO), day(.SU)], weekStart: .SU)
        #expect(summary(biweekly) == "Every 2 weeks on Monday and Sunday (weeks start on Sunday)")
        // Weekly every week: the week start can't change anything, so it isn't mentioned.
        #expect(summary(Recurrence(frequency: .weekly, weekStart: .SU)) == "Weekly on Monday")
    }

    @Test("anything else falls back to a phrase naming every part", arguments: [
        (Recurrence(frequency: .monthly, daysOfWeek: [day(.TU)], daysOfMonth: [1, 2, 3, 4, 5, 6, 7]),
         "Monthly on Tuesday; days of the month: 1, 2, 3, 4, 5, 6 and 7"),
        (Recurrence(frequency: .monthly, daysOfMonth: [1, 2, 3], setPositions: [1]),
         "Monthly; days of the month: 1, 2 and 3; positions: 1st"),
        (Recurrence(frequency: .yearly, daysOfWeek: [day(.MO)], weeksOfYear: [20], setPositions: [1]),
         "Yearly on Monday; weeks of the year: 20; positions: 1st"),
        (Recurrence(frequency: .yearly, daysOfWeek: [day(.MO, 20)]), "Yearly on the 20th Monday"),
        (Recurrence(frequency: .yearly, daysOfWeek: [day(.MO)], weeksOfYear: [1], setPositions: [1], weekStart: .SU),
         "Yearly on Monday; weeks of the year: 1; positions: 1st (weeks start on Sunday)"),
        (Recurrence(frequency: .daily, daysOfWeek: [day(.MO)]), "Daily on Monday"),
        (Recurrence(frequency: .weekly, daysOfWeek: [day(.MO, 2)]), "Weekly on the 2nd Monday"),
        (Recurrence(frequency: .yearly, monthsOfYear: [3, 6], daysOfYear: [100]),
         "Yearly in March and June; days of the year: 100"),
    ])
    func fallback(r: Recurrence, expected: String) {
        #expect(summary(r) == expected)
    }

    @Test("ordinal words")
    func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101].map(RecurrenceSummary.ordinal) == [
            "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st",
        ])
        #expect([-1, -2, -3].map(RecurrenceSummary.ordinal) == ["last", "2nd-to-last", "3rd-to-last"])
    }

    @Test("all-day: no time in the until")
    func allDay() {
        let s = fixtureDate("2026-11-09", timeZone: newYork)
        let r = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 10)))
        #expect(summary(r, start: s, isAllDay: true) == "Daily, until November 10, 2026 (2 occurrences)")
    }
}
