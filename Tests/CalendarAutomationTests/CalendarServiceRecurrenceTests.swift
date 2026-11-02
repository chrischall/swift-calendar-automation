@testable import CalendarAutomation
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!

@Suite("CalendarService recurrence")
struct CalendarServiceRecurrenceTests {
    private let start = fixtureDate("2026-11-09T15:30", timeZone: newYork)
    private var end: Date { start.addingTimeInterval(3600) }
    private let weeklyUntil = Recurrence(
        frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(DateComponents(year: 2027, month: 5, day: 3))
    )

    private func store(with events: [CalendarEvent] = []) -> FakeEventStore {
        let s = FakeEventStore()
        s.calendars = ["Work"]
        s.eventsByCalendar["Work"] = events
        return s
    }

    // ─── create ────────────────────────────────────────────────────────────

    @Test("create passes the rule and the time zone to the store")
    func createPassesRule() async throws {
        let s = store()
        _ = try await CalendarService(store: s).createEvent(
            title: "Percussion", startDate: start, endDate: end, calendarName: "Work",
            recurrence: weeklyUntil, timeZone: newYork
        )
        #expect(s.createdEvents.first?.recurrence == weeklyUntil)
        #expect(s.createdEvents.first?.timeZone == "America/New_York")
    }

    @Test("create without a rule is unchanged: no rule, no explicit zone")
    func createWithoutRule() async throws {
        let s = store()
        _ = try await CalendarService(store: s).createEvent(
            title: "Lunch", startDate: start, endDate: end, calendarName: "Work"
        )
        #expect(s.createdEvents.first?.recurrence == nil)
        #expect(s.createdEvents.first?.timeZone == nil)
    }

    @Test("create validates the rule before writing")
    func createValidates() async throws {
        let s = store()
        let bad = Recurrence(frequency: .weekly, end: .until(DateComponents(year: 2026, month: 1, day: 1)))
        await #expect(throws: RecurrenceError.untilBeforeStart(until: "2026-01-01")) {
            _ = try await CalendarService(store: s).createEvent(
                title: "X", startDate: start, endDate: end, calendarName: "Work", recurrence: bad, timeZone: newYork
            )
        }
        #expect(s.createdEvents.isEmpty)
    }

    @Test("createTarget (the preview's check) refuses an invalid rule too")
    func createTargetValidates() async throws {
        await #expect(throws: RecurrenceError.invalidInterval(0)) {
            _ = try await CalendarService(store: self.store()).createTarget(
                calendarName: "Work", startDate: self.start, endDate: self.end, isAllDay: false,
                recurrence: Recurrence(frequency: .daily, interval: 0), timeZone: newYork
            )
        }
    }

    @Test("an until is checked against the start in the event's zone, not the machine's")
    func createUsesEventZone() async throws {
        // 2026-11-10 02:00 UTC is still Nov 9 in New York, so an until of
        // Nov 9 is on the start's local day there.
        let lateStart = fixtureDate("2026-11-10T02:00:00Z")
        let rule = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 9)))
        _ = try await CalendarService(store: store()).createTarget(
            calendarName: "Work", startDate: lateStart, endDate: lateStart.addingTimeInterval(60), isAllDay: false,
            recurrence: rule, timeZone: newYork
        )
    }

    // ─── update ────────────────────────────────────────────────────────────

    private func occurrence() -> CalendarEvent {
        CalendarEvent(
            id: "S1#occ=2026-11-16T20:30:00Z", title: "Percussion", startDate: start.addingTimeInterval(7 * 86400),
            endDate: end.addingTimeInterval(7 * 86400), calendarName: "Work", isRecurring: true,
            recurrence: weeklyUntil, timeZone: "America/New_York"
        )
    }

    private func single() -> CalendarEvent {
        CalendarEvent(id: "E1", title: "One-off", startDate: start, endDate: end, calendarName: "Work")
    }

    @Test("changing the rule of an occurrence needs span futureEvents", arguments: [
        RecurrenceChange.set(Recurrence(frequency: .daily)), .remove,
    ])
    func occurrenceNeedsFutureEvents(change: RecurrenceChange) async throws {
        let s = store(with: [occurrence()])
        await #expect(throws: EventStoreError.recurrenceChangeNeedsFutureEvents("S1#occ=2026-11-16T20:30:00Z")) {
            try await CalendarService(store: s).updateEvent(
                id: "S1#occ=2026-11-16T20:30:00Z", span: .thisEvent, recurrence: change
            )
        }
        #expect(s.updates.isEmpty)
    }

    @Test("with futureEvents, an occurrence's rule change reaches the store")
    func occurrenceFutureEvents() async throws {
        let s = store(with: [occurrence()])
        let shorter = Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .count(3))
        try await CalendarService(store: s).updateEvent(
            id: "S1#occ=2026-11-16T20:30:00Z", span: .futureEvents, recurrence: .set(shorter)
        )
        #expect(s.updates.first?.recurrence == .set(shorter))
        #expect(s.updates.first?.span == .futureEvents)
    }

    @Test("a single event becomes a series with either span", arguments: EventSpan.allCases)
    func singleBecomesSeries(span: EventSpan) async throws {
        let s = store(with: [single()])
        try await CalendarService(store: s).updateEvent(id: "E1", span: span, recurrence: .set(weeklyUntil))
        #expect(s.updates.first?.recurrence == .set(weeklyUntil))
    }

    @Test("a new rule is validated against the occurrence it starts from")
    func updateValidates() async throws {
        let s = store(with: [occurrence()])
        // Until Nov 10 is before the Nov 16 occurrence the new series starts at.
        let bad = Recurrence(frequency: .weekly, end: .until(DateComponents(year: 2026, month: 11, day: 10)))
        await #expect(throws: RecurrenceError.untilBeforeStart(until: "2026-11-10")) {
            try await CalendarService(store: s).updateEvent(
                id: "S1#occ=2026-11-16T20:30:00Z", span: .futureEvents, recurrence: .set(bad)
            )
        }
        #expect(s.updates.isEmpty)
    }

    @Test("a new rule is validated against a new start when one is given")
    func updateValidatesNewStart() async throws {
        let s = store(with: [single()])
        let rule = Recurrence(frequency: .daily, end: .until(DateComponents(year: 2026, month: 11, day: 20)))
        await #expect(throws: RecurrenceError.untilBeforeStart(until: "2026-11-20")) {
            try await CalendarService(store: s).updateEvent(
                id: "E1", startDate: fixtureDate("2026-12-01T10:00", timeZone: newYork),
                endDate: fixtureDate("2026-12-01T11:00", timeZone: newYork), recurrence: .set(rule)
            )
        }
    }

    @Test("a rule change on a missing event is eventNotFound")
    func updateMissing() async throws {
        await #expect(throws: EventStoreError.eventNotFound("nope")) {
            try await CalendarService(store: self.store()).updateEvent(id: "nope", recurrence: .remove)
        }
    }

    @Test("no rule change: the store sees .unchanged")
    func updateUnchanged() async throws {
        let s = store(with: [single()])
        try await CalendarService(store: s).updateEvent(id: "E1", title: "Renamed")
        #expect(s.updates.first?.recurrence == .unchanged)
    }

    // ─── read-back ─────────────────────────────────────────────────────────

    @Test("an event's RRULE and summary use its zone and the series start")
    func readBack() {
        let ev = CalendarEvent(
            id: "S1#occ=2026-11-16T20:30:00Z", title: "Percussion", startDate: start.addingTimeInterval(7 * 86400),
            endDate: end.addingTimeInterval(7 * 86400), calendarName: "Work", isRecurring: true,
            recurrence: weeklyUntil, timeZone: "America/New_York", seriesStartDate: start
        )
        #expect(ev.rrule == "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503")
        #expect(ev.recurrenceSummary == "Weekly on Monday, until May 3, 2027 (26 occurrences)")
    }

    @Test("a one-off event has no RRULE or summary")
    func readBackSingle() {
        #expect(single().rrule == nil)
        #expect(single().recurrenceSummary == nil)
    }
}
