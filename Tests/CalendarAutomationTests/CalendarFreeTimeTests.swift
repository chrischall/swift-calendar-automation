@testable import CalendarAutomation
import Foundation
import Testing

/// Free-time search: which events count as busy, how working hours are cut
/// out of each day, and whether the answer says what it left out.
///
/// The finder is tested in a fixed zone so DST and weekday rules don't
/// depend on the machine running the suite.
@Suite("Calendar free time")
struct CalendarFreeTimeTests {
    private static let zone = TimeZone(identifier: "America/New_York")!

    /// A wall-clock time in New York.
    private func ny(_ s: String) -> Date {
        fixtureDate(s, timeZone: Self.zone)
    }

    private func query(
        _ from: String, _ to: String, notBefore: Date? = nil,
        start: String = "09:00", end: String = "17:00",
        weekdaysOnly: Bool = true, minMinutes: Int = 30, includeAllDay: Bool = false
    ) -> FreeTimeQuery {
        FreeTimeQuery(
            from: ny(from), to: ny(to), notBefore: notBefore, timeZone: Self.zone,
            workdayStart: ClockTime(parsing: start)!, workdayEnd: ClockTime(parsing: end)!,
            weekdaysOnly: weekdaysOnly, minMinutes: minMinutes, includeAllDay: includeAllDay
        )
    }

    private func event(
        _ start: String, _ end: String, allDay: Bool = false,
        free: Bool = false, cancelled: Bool = false, declined: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: "e-\(start)", title: "Busy", startDate: ny(start), endDate: ny(end),
            calendarName: "Work", isAllDay: allDay,
            showsAsFree: free, isCancelled: cancelled, declinedByMe: declined
        )
    }

    /// Each day's slots as "HH:mm-HH:mm" in New York.
    private func slots(_ r: FreeTimeResult) -> [[String]] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Self.zone
        f.dateFormat = "HH:mm"
        return r.days.map { $0.slots.map { "\(f.string(from: $0.start))-\(f.string(from: $0.end))" } }
    }

    // ─── The arithmetic ────────────────────────────────────────────────────

    @Test("overlapping and touching busy intervals merge")
    func mergeIntervals() {
        let merged = FreeTimeFinder.merge([
            DateInterval(start: ny("2030-01-07T13:00:00"), end: ny("2030-01-07T14:00:00")),
            DateInterval(start: ny("2030-01-07T10:00:00"), end: ny("2030-01-07T11:00:00")),
            DateInterval(start: ny("2030-01-07T10:30:00"), end: ny("2030-01-07T12:00:00")),
            DateInterval(start: ny("2030-01-07T12:00:00"), end: ny("2030-01-07T12:15:00")),
        ])
        #expect(merged == [
            DateInterval(start: ny("2030-01-07T10:00:00"), end: ny("2030-01-07T12:15:00")),
            DateInterval(start: ny("2030-01-07T13:00:00"), end: ny("2030-01-07T14:00:00")),
        ])
    }

    @Test("busy time is cut out of the working day, including an event that starts before it")
    func basicDay() {
        // Monday 2030-01-07.
        let r = FreeTimeFinder.find(query("2030-01-07", "2030-01-08"), in: [
            event("2030-01-07T08:00:00", "2030-01-07T09:30:00"),
            event("2030-01-07T11:00:00", "2030-01-07T12:00:00"),
            event("2030-01-07T11:30:00", "2030-01-07T13:00:00"),
            event("2030-01-07T16:45:00", "2030-01-07T18:00:00"),
        ])
        #expect(slots(r) == [["09:30-11:00", "13:00-16:45"]])
    }

    @Test("gaps shorter than minDurationMinutes are dropped, and a full day reads as a day with no slot")
    func minimumLength() {
        let r = FreeTimeFinder.find(query("2030-01-07", "2030-01-09", minMinutes: 60), in: [
            event("2030-01-07T09:00:00", "2030-01-07T12:00:00"),
            event("2030-01-07T12:45:00", "2030-01-07T17:00:00"),
            event("2030-01-08T09:00:00", "2030-01-08T17:00:00"),
        ])
        #expect(slots(r) == [[], []])
        #expect(r.days.count == 2, "a day with no slot is still listed, not dropped")
    }

    @Test("weekends are skipped and counted, or included when weekdaysOnly is false")
    func weekends() {
        // Friday 2030-01-11 through Monday 2030-01-14.
        let weekdays = FreeTimeFinder.find(query("2030-01-11", "2030-01-15"), in: [])
        #expect(weekdays.days.count == 2)
        #expect(weekdays.weekendDays == 2)
        let every = FreeTimeFinder.find(query("2030-01-11", "2030-01-15", weekdaysOnly: false), in: [])
        #expect(every.days.count == 4)
        #expect(every.weekendDays == 0)
    }

    @Test("nothing before notBefore is offered; a day already over is counted, not listed")
    func notBefore() {
        let r = FreeTimeFinder.find(
            query("2030-01-07", "2030-01-09", notBefore: ny("2030-01-07T17:30:00")), in: []
        )
        #expect(r.outsideWindow == 1)
        #expect(slots(r) == [["09:00-17:00"]])

        let midday = FreeTimeFinder.find(
            query("2030-01-07", "2030-01-08", notBefore: ny("2030-01-07T13:05:00")), in: []
        )
        #expect(slots(midday) == [["13:05-17:00"]])
    }

    @Test("a window ending at midnight does not pull in the next day")
    func windowEndsAtMidnight() {
        let r = FreeTimeFinder.find(query("2030-01-07", "2030-01-08"), in: [])
        #expect(r.days.count == 1)
    }

    @Test("a window ending mid-day cuts that day's working hours")
    func windowEndsMidDay() {
        let r = FreeTimeFinder.find(query("2030-01-07T10:00:00", "2030-01-07T15:00:00"), in: [])
        #expect(slots(r) == [["10:00-15:00"]])
    }

    @Test("working hours follow the wall clock across a DST change")
    func daylightSaving() {
        // US clocks spring forward on Sunday 2030-03-10.
        let r = FreeTimeFinder.find(
            query("2030-03-09", "2030-03-12", weekdaysOnly: false), in: []
        )
        #expect(slots(r) == [["09:00-17:00"], ["09:00-17:00"], ["09:00-17:00"]])
        let starts = r.days.map { $0.slots[0].start }
        #expect(starts[1].timeIntervalSince(starts[0]) == 23 * 3600)
        #expect(starts[2].timeIntervalSince(starts[1]) == 24 * 3600)
    }

    @Test("a DST change that skips midnight doesn't drop the window's last day")
    func midnightSkippingZone() throws {
        // Chile springs forward at 00:00 on Sunday 2026-09-06: that day starts at 01:00.
        let santiago = try #require(TimeZone(identifier: "America/Santiago"))
        func cl(_ s: String) -> Date { fixtureDate(s, timeZone: santiago) }
        let q = try FreeTimeQuery(
            from: cl("2026-09-03"), to: cl("2026-09-10"), notBefore: nil, timeZone: santiago,
            workdayStart: #require(ClockTime(hour: 9, minute: 0)),
            workdayEnd: #require(ClockTime(hour: 17, minute: 0)),
            weekdaysOnly: false, minMinutes: 30, includeAllDay: false
        )
        let r = FreeTimeFinder.find(q, in: [])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = santiago
        f.dateFormat = "yyyy-MM-dd"
        #expect(r.days.map { f.string(from: $0.day) } ==
            ["2026-09-03", "2026-09-04", "2026-09-05", "2026-09-06", "2026-09-07", "2026-09-08", "2026-09-09"])
        #expect(r.days.allSatisfy { $0.slots.count == 1 && $0.slots[0].minutes == 480 })
    }

    @Test("a day the window cuts into says which side was cut")
    func clippedDays() {
        let r = FreeTimeFinder.find(query("2030-01-07T11:00:00", "2030-01-08T13:00:00"), in: [])
        #expect(slots(r) == [["11:00-17:00"], ["09:00-13:00"]])
        #expect(r.days[0].windowStartsAt == ny("2030-01-07T11:00:00"))
        #expect(r.days[0].windowEndsAt == nil)
        #expect(r.days[1].windowStartsAt == nil)
        #expect(r.days[1].windowEndsAt == ny("2030-01-08T13:00:00"))
    }

    @Test("an all-day event with an inclusive end (end == start) still blocks its whole day")
    func inclusiveAllDayEnd() {
        let r = FreeTimeFinder.find(query("2030-01-07", "2030-01-09", includeAllDay: true), in: [
            event("2030-01-07T00:00:00", "2030-01-07T00:00:00", allDay: true),
        ])
        #expect(slots(r) == [[], ["09:00-17:00"]])
    }

    @Test("free, cancelled, declined and (by default) all-day events don't block time, and are counted")
    func busyRules() {
        let events = [
            event("2030-01-07T09:00:00", "2030-01-07T10:00:00", free: true),
            event("2030-01-07T10:00:00", "2030-01-07T11:00:00", cancelled: true),
            event("2030-01-07T11:00:00", "2030-01-07T12:00:00", declined: true),
            event("2030-01-07T00:00:00", "2030-01-07T23:59:59", allDay: true),
            event("2030-01-07T14:00:00", "2030-01-07T15:00:00"),
        ]
        let r = FreeTimeFinder.find(query("2030-01-07", "2030-01-08"), in: events)
        #expect(slots(r) == [["09:00-14:00", "15:00-17:00"]])
        #expect(r.ignored.shownAsFree == 1)
        #expect(r.ignored.cancelled == 1)
        #expect(r.ignored.declined == 1)
        #expect(r.ignored.allDay == 1)

        let blocking = FreeTimeFinder.find(query("2030-01-07", "2030-01-08", includeAllDay: true), in: events)
        #expect(slots(blocking) == [[]])
        #expect(blocking.ignored.allDay == 0)
    }

    @Test("HH:MM parsing is strict")
    func clockParsing() {
        #expect(ClockTime(parsing: "09:30") == ClockTime(hour: 9, minute: 30))
        #expect(ClockTime(parsing: "23:59") != nil)
        for bad in ["9:30", "09:3", "24:00", "09:60", "9am", "09:30:00", "", "０９:３０"] {
            #expect(ClockTime(parsing: bad) == nil, "\(bad) should be refused")
        }
    }
}
