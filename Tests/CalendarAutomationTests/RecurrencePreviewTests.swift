@testable import CalendarAutomation
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!

private func ny(_ s: String) -> Date { fixtureDate(s, timeZone: newYork) }

/// Wall clock of `date` in New York as `2026-11-09T15:30`, for readable expectations.
private func local(_ date: Date, _ tz: TimeZone = newYork) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return "\(c.year!.zeroPadded(4))-\(c.month!.zeroPadded(2))-\(c.day!.zeroPadded(2))T"
        + "\(c.hour!.zeroPadded(2)):\(c.minute!.zeroPadded(2))"
}

private func offsetHours(_ date: Date) -> Int { newYork.secondsFromGMT(for: date) / 3600 }

private let mo = Recurrence.Day(.MO)
private let weekdays: [Recurrence.Day] = [.MO, .TU, .WE, .TH, .FR].map { .init($0) }
private let percussionStart = ny("2026-11-09T15:30")
private let percussion = Recurrence(
    frequency: .weekly, daysOfWeek: [mo], end: .until(DateComponents(year: 2027, month: 5, day: 3))
)

private func preview(
    _ r: Recurrence, _ start: Date, limit: Int = 10, isAllDay: Bool = false
) -> OccurrencePreview {
    r.occurrences(start: start, timeZone: newYork, isAllDay: isAllDay, limit: limit)
}

private func firstLocal(_ r: Recurrence, _ start: String, limit: Int = 10) -> [String] {
    preview(r, ny(start), limit: limit).first.map { local($0) }
}

@Suite("Recurrence occurrence preview")
struct RecurrencePreviewTests {
    @Test("percussion: weekly Monday until May 3 2027 → 26 occurrences at 15:30 local")
    func percussionCase() {
        let p = preview(percussion, percussionStart, limit: 3)
        #expect(p.first.map { local($0) } == ["2026-11-09T15:30", "2026-11-16T15:30", "2026-11-23T15:30"])
        #expect(p.total == 26)
        #expect(p.totalIsCapped == false)
        let all = preview(percussion, percussionStart, limit: 100)
        #expect(all.first.count == 26)
        #expect(all.first.last.map { local($0) } == "2027-05-03T15:30")
    }

    @Test("weekly keeps 15:30 local across the Nov 1 fall-back and the Mar 14 spring-forward")
    func dstWallClock() throws {
        let start = ny("2026-10-26T15:30")
        let dates = preview(Recurrence(frequency: .weekly), start, limit: 25).first
        #expect(dates.allSatisfy { local($0).hasSuffix("T15:30") })
        let oct26 = try #require(dates.first { local($0) == "2026-10-26T15:30" })
        let nov2 = try #require(dates.first { local($0) == "2026-11-02T15:30" })
        let mar8 = try #require(dates.first { local($0) == "2027-03-08T15:30" })
        let mar15 = try #require(dates.first { local($0) == "2027-03-15T15:30" })
        #expect(offsetHours(oct26) == -4)
        #expect(offsetHours(nov2) == -5)
        #expect(offsetHours(mar8) == -5)
        #expect(offsetHours(mar15) == -4)
        // A week apart in wall clock, not in absolute time: the fall-back week is 169h long.
        #expect(nov2.timeIntervalSince(oct26) == 169 * 3600)
    }

    @Test("a time that doesn't exist on the spring-forward day moves forward by the gap")
    func springForwardGap() {
        let r = Recurrence(frequency: .daily, end: .count(4))
        #expect(firstLocal(r, "2027-03-12T02:30") == [
            "2027-03-12T02:30", "2027-03-13T02:30", "2027-03-14T03:30", "2027-03-15T02:30",
        ])
    }

    @Test("count-limited: exactly count occurrences, total == count")
    func countLimited() {
        let p = preview(Recurrence(frequency: .daily, interval: 3, end: .count(5)), ny("2026-11-09T09:00"))
        #expect(p.first.map { local($0) } == [
            "2026-11-09T09:00", "2026-11-12T09:00", "2026-11-15T09:00", "2026-11-18T09:00", "2026-11-21T09:00",
        ])
        #expect(p.total == 5)
        #expect(p.totalIsCapped == false)
    }

    @Test("first is capped at limit even when total is larger")
    func limitCapsFirst() {
        let p = preview(Recurrence(frequency: .daily, end: .count(40)), ny("2026-11-09T09:00"), limit: 3)
        #expect(p.first.count == 3)
        #expect(p.total == 40)
    }

    @Test("open-ended: no total, not capped, only limit dates")
    func openEnded() {
        let p = preview(Recurrence(frequency: .weekly), percussionStart, limit: 4)
        #expect(p.first.count == 4)
        #expect(p.total == nil)
        #expect(p.totalIsCapped == false)
    }

    @Test("more than maxCountedOccurrences: total nil, capped")
    func thousandPlus() {
        #expect(Recurrence.maxCountedOccurrences == 1000)
        let long = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2030, month: 1, day: 1)))
        let p = preview(long, ny("2026-11-09T09:00"), limit: 2)
        #expect(p.first.count == 2)
        #expect(p.total == nil)
        #expect(p.totalIsCapped == true)
        let exact = preview(Recurrence(frequency: .daily, end: .count(1000)), ny("2026-11-09T09:00"), limit: 1)
        #expect(exact.total == 1000)
        #expect(exact.totalIsCapped == false)
        let over = preview(Recurrence(frequency: .daily, end: .count(1001)), ny("2026-11-09T09:00"), limit: 1)
        #expect(over.total == nil)
        #expect(over.totalIsCapped == true)
    }

    @Test("monthly on the 31st skips months without one", arguments: [
        Recurrence(frequency: .monthly),
        Recurrence(frequency: .monthly, daysOfMonth: [31]),
    ])
    func monthly31st(r: Recurrence) {
        #expect(firstLocal(r, "2026-01-31T10:00", limit: 7) == [
            "2026-01-31T10:00", "2026-03-31T10:00", "2026-05-31T10:00", "2026-07-31T10:00",
            "2026-08-31T10:00", "2026-10-31T10:00", "2026-12-31T10:00",
        ])
    }

    @Test("yearly on Feb 29 only lands in leap years")
    func yearlyLeapDay() {
        #expect(firstLocal(Recurrence(frequency: .yearly), "2028-02-29T09:00", limit: 3) == [
            "2028-02-29T09:00", "2032-02-29T09:00", "2036-02-29T09:00",
        ])
    }

    @Test("the start is occurrence #1 even when it doesn't match the rule, and counts toward COUNT")
    func startAlwaysCounts() {
        // Tue 2026-11-10, weekly on Monday ×3: the Tuesday, then two Mondays (EventKit semantics).
        let r = Recurrence(frequency: .weekly, daysOfWeek: [mo], end: .count(3))
        let p = preview(r, ny("2026-11-10T15:30"))
        #expect(p.first.map { local($0) } == ["2026-11-10T15:30", "2026-11-16T15:30", "2026-11-23T15:30"])
        #expect(p.total == 3)
    }

    @Test("count 1 is just the start")
    func countOne() {
        let p = preview(Recurrence(frequency: .weekly, end: .count(1)), percussionStart)
        #expect(p.first == [percussionStart])
        #expect(p.total == 1)
    }

    @Test("until with a time is inclusive of that instant")
    func untilDateTime() {
        let r = Recurrence(frequency: .daily, end: .until(RecurrenceDates.dateTime(2026, 11, 11, 9, 0, 0)))
        #expect(preview(r, ny("2026-11-09T09:00")).total == 3)
        let before = Recurrence(frequency: .daily, end: .until(RecurrenceDates.dateTime(2026, 11, 11, 8, 59, 59)))
        #expect(preview(before, ny("2026-11-09T09:00")).total == 2)
    }

    @Test("all-day: date-only until includes its day")
    func allDay() {
        let r = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 3)))
        let p = preview(r, ny("2026-11-01"), isAllDay: true)
        #expect(p.first.map { local($0) } == ["2026-11-01T00:00", "2026-11-02T00:00", "2026-11-03T00:00"])
        #expect(p.total == 3)
    }

    @Test("biweekly on Monday and Wednesday")
    func biweekly() {
        let r = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [mo, .init(.WE)])
        #expect(firstLocal(r, "2026-11-09T09:00", limit: 4) == [
            "2026-11-09T09:00", "2026-11-11T09:00", "2026-11-23T09:00", "2026-11-25T09:00",
        ])
    }

    @Test("week start decides which weeks a biweekly rule hits")
    func weekStart() {
        let days: [Recurrence.Day] = [mo, .init(.SU)]
        let mondayWeeks = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: days)
        #expect(firstLocal(mondayWeeks, "2026-11-09T09:00", limit: 4) == [
            "2026-11-09T09:00", "2026-11-15T09:00", "2026-11-23T09:00", "2026-11-29T09:00",
        ])
        let sundayWeeks = Recurrence(frequency: .weekly, interval: 2, daysOfWeek: days, weekStart: .SU)
        #expect(firstLocal(sundayWeeks, "2026-11-09T09:00", limit: 4) == [
            "2026-11-09T09:00", "2026-11-22T09:00", "2026-11-23T09:00", "2026-12-06T09:00",
        ])
    }

    @Test("monthly on the 2nd Tuesday, by ordinal or by set position")
    func secondTuesday() {
        let expected = ["2026-11-10T09:00", "2026-12-08T09:00", "2027-01-12T09:00"]
        let ordinal = Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU, ordinal: 2)])
        #expect(firstLocal(ordinal, "2026-11-10T09:00", limit: 3) == expected)
        let setPos = Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU)], setPositions: [2])
        #expect(firstLocal(setPos, "2026-11-10T09:00", limit: 3) == expected)
    }

    @Test("monthly on the last weekday")
    func lastWeekday() {
        let r = Recurrence(frequency: .monthly, daysOfWeek: weekdays, setPositions: [-1])
        #expect(firstLocal(r, "2026-11-30T09:00", limit: 4) == [
            "2026-11-30T09:00", "2026-12-31T09:00", "2027-01-29T09:00", "2027-02-26T09:00",
        ])
    }

    @Test("set positions count from the start of the start's period, not from the start")
    func setPositionsWholePeriod() {
        // First weekday of the month; the series starts mid-November, so November's first weekday is past.
        let r = Recurrence(frequency: .monthly, daysOfWeek: weekdays, setPositions: [1])
        #expect(firstLocal(r, "2026-11-02T09:00", limit: 3) == [
            "2026-11-02T09:00", "2026-12-01T09:00", "2027-01-01T09:00",
        ])
        #expect(firstLocal(r, "2026-11-10T09:00", limit: 3) == [
            "2026-11-10T09:00", "2026-12-01T09:00", "2027-01-01T09:00",
        ])
    }

    @Test("monthly on the last Friday and on the last day")
    func lastFridayAndLastDay() {
        let friday = Recurrence(frequency: .monthly, daysOfWeek: [.init(.FR, ordinal: -1)])
        #expect(firstLocal(friday, "2026-11-27T09:00", limit: 3) == [
            "2026-11-27T09:00", "2026-12-25T09:00", "2027-01-29T09:00",
        ])
        let lastDay = Recurrence(frequency: .monthly, daysOfMonth: [-1])
        #expect(firstLocal(lastDay, "2026-11-30T09:00", limit: 4) == [
            "2026-11-30T09:00", "2026-12-31T09:00", "2027-01-31T09:00", "2027-02-28T09:00",
        ])
    }

    @Test("monthly on days 1 and 15")
    func monthlyDays() {
        let r = Recurrence(frequency: .monthly, daysOfMonth: [15, 1])
        #expect(firstLocal(r, "2026-11-01T09:00", limit: 4) == [
            "2026-11-01T09:00", "2026-11-15T09:00", "2026-12-01T09:00", "2026-12-15T09:00",
        ])
    }

    @Test("every 2 years in March on the 2nd Sunday")
    func yearlySecondSunday() {
        let r = Recurrence(frequency: .yearly, interval: 2, daysOfWeek: [.init(.SU, ordinal: 2)], monthsOfYear: [3])
        #expect(firstLocal(r, "2027-03-14T09:00", limit: 3) == [
            "2027-03-14T09:00", "2029-03-11T09:00", "2031-03-09T09:00",
        ])
    }

    @Test("yearly by week number and by day of year")
    func yearlyWeekAndDay() {
        // ISO week 20 Monday: 2027-05-17, 2028-05-15, 2029-05-14.
        let week = Recurrence(frequency: .yearly, daysOfWeek: [mo], weeksOfYear: [20], setPositions: [1])
        #expect(firstLocal(week, "2027-05-17T09:00", limit: 3) == [
            "2027-05-17T09:00", "2028-05-15T09:00", "2029-05-14T09:00",
        ])
        let day = Recurrence(frequency: .yearly, daysOfYear: [100, -1])
        #expect(firstLocal(day, "2026-04-10T09:00", limit: 4) == [
            "2026-04-10T09:00", "2026-12-31T09:00", "2027-04-10T09:00", "2027-12-31T09:00",
        ])
    }

    @Test("a rule that never matches again yields only the start, and terminates")
    func neverMatches() {
        // 2026 + 400k is never a leap year, so day 366 never comes; the open-ended scan still stops.
        let r = Recurrence(frequency: .yearly, interval: 400, daysOfYear: [366])
        let p = preview(r, ny("2026-04-10T09:00"), limit: 3)
        #expect(p.first == [ny("2026-04-10T09:00")])
        #expect(p.total == nil)
    }

    @Test("an invalid rule previews only the start")
    func invalidRule() {
        let p = preview(Recurrence(frequency: .daily, interval: 0), percussionStart)
        #expect(p.first == [percussionStart])
        #expect(p.total == 1)
    }

    @Test("agrees with Foundation's Calendar.RecurrenceRule where that is correct", arguments: [
        (Recurrence(frequency: .daily, interval: 2), "2026-10-20T15:30"),
        (Recurrence(frequency: .weekly, daysOfWeek: [mo]), "2026-10-26T15:30"),
        (Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [mo, .init(.TH)]), "2026-10-26T15:30"),
        (Recurrence(frequency: .monthly, daysOfMonth: [31]), "2026-01-31T10:00"),
        (Recurrence(frequency: .monthly, daysOfMonth: [-1]), "2026-01-31T10:00"),
        (Recurrence(frequency: .monthly, daysOfWeek: [.init(.TU, ordinal: 2)]), "2026-11-10T09:00"),
        (Recurrence(frequency: .monthly, daysOfWeek: [.init(.FR, ordinal: -1)]), "2026-11-27T09:00"),
        (Recurrence(frequency: .yearly), "2026-03-15T09:00"),
        (Recurrence(frequency: .yearly, interval: 2, daysOfWeek: [.init(.SU, ordinal: 2)], monthsOfYear: [3]),
         "2027-03-14T09:00"),
        (Recurrence(frequency: .yearly, daysOfYear: [100, -1]), "2026-04-10T09:00"),
    ])
    func matchesFoundation(r: Recurrence, start: String) {
        let s = ny(start)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        cal.firstWeekday = 2
        var rule = Calendar.RecurrenceRule(calendar: cal, frequency: {
            switch r.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        }(), interval: r.interval)
        rule.weekdays = (r.daysOfWeek ?? []).map { day in
            let w: Locale.Weekday = switch day.weekday {
            case .MO: .monday
            case .TU: .tuesday
            case .WE: .wednesday
            case .TH: .thursday
            case .FR: .friday
            case .SA: .saturday
            case .SU: .sunday
            }
            return day.ordinal.map { .nth($0, w) } ?? .every(w)
        }
        rule.daysOfTheMonth = r.daysOfMonth ?? []
        rule.months = (r.monthsOfYear ?? []).map { Calendar.RecurrenceRule.Month($0) }
        rule.daysOfTheYear = r.daysOfYear ?? []
        let foundation = Array(rule.recurrences(of: s).prefix(20))
        #expect(preview(r, s, limit: 20).first == foundation)
    }
}
