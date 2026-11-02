@testable import CalendarAutomation
import EventKit
import Foundation
import Testing

/// End-to-end tests against the user's real EventKit store.
///
/// **Never touches existing user calendars.** Every test runs inside
/// `withFixtureCalendar`, which creates a dedicated, UUID-named
/// `AppleSwiftMCPTest-*` calendar, and deletes it whatever the test body
/// does. A crashed run (the process killed) can still leave one behind;
/// the next run's orphan sweep removes it, reporting anything it can't.
///
/// **Opt-in** via `CALENDAR_INTEGRATION=1`. Unset, every test in this
/// suite is skipped — CI and normal `swift test` runs stay
/// deterministic and never pop permission prompts.
///
/// ```bash
/// CALENDAR_INTEGRATION=1 swift test --filter CalendarServiceIntegrationTests
/// ```
///
/// **Permissions required on first run**: Calendar full access for the test
/// binary (System Settings → Privacy & Security → Calendars).
///
/// **Serialized.** The orphan sweep deletes *all* `AppleSwiftMCPTest-*`
/// calendars; in parallel the tests would delete each other's fixtures
/// mid-flight.
@Suite("CalendarService integration", .serialized, .disabled(if: integrationDisabled, "set CALENDAR_INTEGRATION=1"))
struct CalendarServiceIntegrationTests {
    // MARK: - single events

    @Test("create → list → search → update cycle stays inside the test calendar")
    func fullCycle() async throws {
        try await withFixtureCalendar { testCal, service in
            let now = Date()
            let start = now.addingTimeInterval(3600)
            let end = now.addingTimeInterval(7200)
            let dayLater = now.addingTimeInterval(86400)
            let uniqueTitle = "ITest-\(UUID().uuidString.prefix(8))"

            let id = try await service.createEvent(
                title: uniqueTitle, startDate: start, endDate: end, calendarName: testCal.title,
                location: "Test location", notes: "Test notes", isAllDay: false
            )
            #expect(!id.isEmpty)

            let listed = try await service.listEvents(from: now, to: dayLater, calendarName: testCal.title, limit: 10)
            #expect(listed.totalMatched == 1, "fixture calendar should contain only our event")
            #expect(listed.events.first?.title == uniqueTitle)
            #expect(listed.events.first?.location == "Test location")
            #expect(listed.events.first?.recurrence == nil)

            let hits = try await service.searchEvents(
                query: uniqueTitle, from: now, to: dayLater, calendarName: testCal.title
            )
            #expect(hits.totalMatched == 1)

            let newTitle = uniqueTitle + "-updated"
            try await service.updateEvent(id: id, title: newTitle, calendarName: testCal.title, notes: "Updated notes")
            let afterUpdate = try await service.listEvents(from: now, to: dayLater, calendarName: testCal.title)
            #expect(afterUpdate.events.first?.title == newTitle)
            #expect(afterUpdate.events.first?.notes == "Updated notes")
        }
    }

    @Test("move between two fixture calendars: event moves, id may change")
    func moveBetweenFixtures() async throws {
        try await withFixtureCalendar { sourceCal, service in
            try await withFixtureCalendar(cleanOrphans: false) { destCal, _ in
                let now = Date()
                let title = "MoveProbe-\(UUID().uuidString.prefix(8))"
                let id = try await service.createEvent(
                    title: title, startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200),
                    calendarName: sourceCal.title
                )

                try await service.updateEvent(id: id, calendarName: destCal.title)

                let later = now.addingTimeInterval(86400)
                let inDest = try await service.listEvents(from: now, to: later, calendarName: destCal.title)
                let inSource = try await service.listEvents(from: now, to: later, calendarName: sourceCal.title)
                #expect(inDest.events.contains { $0.title == title }, "event should be in the destination")
                #expect(!inSource.events.contains { $0.title == title }, "event should have left the source")
            }
        }
    }

    // MARK: - fixture hygiene

    @Test("the orphan sweep removes a calendar a crashed run left behind")
    func orphanCleanup() async throws {
        // Simulate a crashed run: a fixture created and never deleted.
        let creator = try await authorizedEventStore()
        let orphanTitle = try CalendarTestFixture.create(store: creator).title
        #expect(fixtureCalendarExists(orphanTitle))

        try await withFixtureCalendar { cal, _ in
            #expect(!fixtureCalendarExists(orphanTitle), "the sweep should have removed the orphan")
            let report = CalendarTestFixture.cleanUpOrphans(store: EKEventStore(), dryRun: true)
            #expect(report.removed == [cal.title], "only this test's own fixture should remain")
            #expect(report.failed.isEmpty)
        }
        withExtendedLifetime(creator) {}
    }

    @Test("an empty calendar handle is refused, not silently ignored")
    func deleteEmptyHandle() {
        #expect(throws: CalendarTestFixture.Error.self) {
            try CalendarTestFixture.delete(identifier: "", title: "", store: EKEventStore())
        }
    }

    @Test("a dry run lists fixture calendars and removes nothing")
    func dryRunRemovesNothing() async throws {
        try await withFixtureCalendar { cal, _ in
            let report = CalendarTestFixture.cleanUpOrphans(store: EKEventStore(), dryRun: true)
            #expect(report.removed.contains(cal.title))
            #expect(fixtureCalendarExists(cal.title))
        }
    }

    @Test("a failing test body still deletes its calendar")
    func failingBodyStillDeletes() async throws {
        struct Boom: Error {}
        let title = Locked("")
        await #expect(throws: Boom.self) {
            try await withFixtureCalendar { cal, _ in
                title.withLock { $0 = cal.title }
                throw Boom()
            }
        }
        let leaked = title.withLock { $0 }
        #expect(!leaked.isEmpty)
        #expect(!fixtureCalendarExists(leaked), "fixture calendar \(leaked) leaked after a throwing body")
    }

    @Test("delete removes a calendar through a store other than the one that created it")
    func deleteAcrossStores() async throws {
        // The old orphanCleanup test deleted its second fixture through the
        // first fixture's store; removeCalendar refuses a calendar object
        // from another store, `try?` swallowed that, and every full run
        // left one calendar behind. The creating store is kept alive: a
        // calendar whose store is released reads back an empty title.
        let creator = try await authorizedEventStore()
        let created = try CalendarTestFixture.create(store: creator)
        let title = created.title
        #expect(fixtureCalendarExists(title))
        try await CalendarTestFixture.delete(created, store: authorizedEventStore())
        #expect(!fixtureCalendarExists(title))
        withExtendedLifetime(creator) {}
    }

    // MARK: - recurrence

    private static let newYork = TimeZone(identifier: "America/New_York")!

    private static func ny(_ s: String) -> Date { fixtureDate(s, timeZone: newYork) }

    private static func wallClock(_ d: Date) -> (hour: Int, minute: Int) {
        let c = RecurrenceDates.calendar(newYork).dateComponents([.hour, .minute], from: d)
        return (c.hour ?? -1, c.minute ?? -1)
    }

    /// Every event of `calendar` in `[from, to)`, unpaged.
    private static func all(
        _ service: CalendarService, _ calendar: EKCalendar, _ from: Date, _ to: Date
    ) async throws -> [CalendarEvent] {
        try await service.listEvents(from: from, to: to, calendarName: calendar.title, limit: 0).events
    }

    @Test("weekly until: 26 occurrences, read back structured, as RRULE and as a summary")
    func weeklyUntil() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-09T15:30")
            let rule = Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(DateComponents(
                year: 2027, month: 5, day: 3
            )))
            _ = try await service.createEvent(
                title: "Percussion", startDate: start, endDate: start.addingTimeInterval(3600),
                calendarName: cal.title, recurrence: rule, timeZone: Self.newYork
            )

            let events = try await Self.all(service, cal, Self.ny("2026-11-01"), Self.ny("2027-06-01"))
            #expect(events.count == 26)
            #expect(events.first?.startDate == start)
            #expect(events.last?.startDate == Self.ny("2027-05-03T15:30"))

            let first = try #require(events.first)
            let read = try #require(try await service.event(id: first.id))
            #expect(read.recurrence == rule)
            #expect(read.timeZone == "America/New_York")
            #expect(read.seriesStartDate == start)
            #expect(read.hasAdditionalRecurrenceRules == false)
            #expect(read.rrule == "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270503")
            #expect(read.recurrenceSummary == "Weekly on Monday, until May 3, 2027 (26 occurrences)")

            // A later occurrence reports the same rule, measured from the series start.
            let later = try #require(events.dropFirst(10).first)
            #expect(later.recurrence == rule)
            #expect(later.seriesStartDate == start)
            #expect(later.recurrenceSummary == read.recurrenceSummary)
        }
    }

    @Test("count: exactly that many occurrences")
    func countLimited() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-10T09:00")
            let rule = Recurrence(frequency: .daily, end: .count(5))
            _ = try await service.createEvent(
                title: "Five days", startDate: start, endDate: start.addingTimeInterval(1800),
                calendarName: cal.title, recurrence: rule, timeZone: Self.newYork
            )
            let events = try await Self.all(service, cal, Self.ny("2026-11-01"), Self.ny("2026-12-31"))
            #expect(events.count == 5)
            #expect(events.first?.recurrence == rule)
            #expect(events.first?.rrule == "FREQ=DAILY;COUNT=5")
            #expect(events.first?.recurrenceSummary == "Daily, 5 times")
        }
    }

    @Test("a non-Monday week start survives a save")
    func weekStartPersists() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-09T15:30")
            let rule = Recurrence(
                frequency: .weekly, interval: 2, daysOfWeek: [.init(.MO), .init(.SU)], weekStart: .SU, end: .count(6)
            )
            _ = try await service.createEvent(
                title: "WKST", startDate: start, endDate: start.addingTimeInterval(3600),
                calendarName: cal.title, recurrence: rule, timeZone: Self.newYork
            )
            let events = try await Self.all(service, cal, Self.ny("2026-11-01"), Self.ny("2027-03-01"))
            #expect(events.first?.recurrence == rule)
        }
    }

    @Test("future events from a mid-series occurrence: the new until applies from there on")
    func updateFutureEvents() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-09T15:30")
            let rule = Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .count(10))
            _ = try await service.createEvent(
                title: "Split", startDate: start, endDate: start.addingTimeInterval(3600),
                calendarName: cal.title, recurrence: rule, timeZone: Self.newYork
            )
            let window = (Self.ny("2026-11-01"), Self.ny("2027-03-01"))
            let before = try await Self.all(service, cal, window.0, window.1)
            #expect(before.count == 10)
            let fourth = try #require(before.dropFirst(3).first) // Nov 30

            var shorter = rule
            shorter.end = .until(DateComponents(year: 2026, month: 12, day: 28))

            await #expect(throws: EventStoreError.recurrenceChangeNeedsFutureEvents(fourth.id)) {
                try await service.updateEvent(id: fourth.id, span: .thisEvent, recurrence: .set(shorter))
            }

            try await service.updateEvent(id: fourth.id, span: .futureEvents, recurrence: .set(shorter))
            let after = try await Self.all(service, cal, window.0, window.1)
            // Nov 9, 16, 23 from the original series, then Nov 30 … Dec 28.
            #expect(after.map(\.startDate) == [
                "2026-11-09", "2026-11-16", "2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14", "2026-12-21",
                "2026-12-28",
            ].map { Self.ny($0 + "T15:30") })
            #expect(after.last?.recurrence?.end == .until(DateComponents(year: 2026, month: 12, day: 28)))
        }
    }

    @Test("a one-off event becomes a series through its plain id")
    func singleBecomesSeries() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-10T12:00")
            let id = try await service.createEvent(
                title: "Lunch", startDate: start, endDate: start.addingTimeInterval(3600), calendarName: cal.title
            )
            let rule = Recurrence(frequency: .daily, end: .count(3))
            try await service.updateEvent(id: id, recurrence: .set(rule))

            let events = try await Self.all(service, cal, Self.ny("2026-11-01"), Self.ny("2026-12-01"))
            #expect(
                events.map(\.startDate) == [start, start.addingTimeInterval(86400), start.addingTimeInterval(2 * 86400)]
            )
            #expect(events.allSatisfy { $0.isRecurring && $0.recurrence == rule })
        }
    }

    @Test("removing the rule from the first occurrence leaves one event")
    func removeRule() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-11-10T12:00")
            _ = try await service.createEvent(
                title: "Was weekly", startDate: start, endDate: start.addingTimeInterval(3600),
                calendarName: cal.title, recurrence: Recurrence(frequency: .weekly, end: .count(4)),
                timeZone: Self.newYork
            )
            let window = (Self.ny("2026-11-01"), Self.ny("2027-01-01"))
            let first = try #require(try await Self.all(service, cal, window.0, window.1).first)

            try await service.updateEvent(id: first.id, span: .futureEvents, recurrence: .remove)

            let after = try await Self.all(service, cal, window.0, window.1)
            #expect(after.count == 1)
            #expect(after.first?.recurrence == nil)
            #expect(after.first?.isRecurring == false)
        }
    }

    @Test("DST: a 15:30 New York series keeps 15:30 local after Nov 1 2026 and Mar 14 2027")
    func dstWallClock() async throws {
        try await withFixtureCalendar { cal, service in
            let start = Self.ny("2026-10-26T15:30")
            _ = try await service.createEvent(
                title: "DST", startDate: start, endDate: start.addingTimeInterval(3600), calendarName: cal.title,
                recurrence: Recurrence(frequency: .weekly, daysOfWeek: [.init(.MO)], end: .until(DateComponents(
                    year: 2027, month: 3, day: 22
                ))),
                timeZone: Self.newYork
            )
            let events = try await Self.all(service, cal, Self.ny("2026-10-01"), Self.ny("2027-04-01"))
            #expect(events.count == 22)
            #expect(events.allSatisfy { Self.wallClock($0.startDate) == (15, 30) })

            let afterFallBack = try #require(events.first { $0.startDate > Self.ny("2026-11-01T12:00") })
            #expect(afterFallBack.startDate == fixtureDate("2026-11-02T20:30:00Z")) // UTC-5
            let beforeSpring = try #require(events.last { $0.startDate < Self.ny("2027-03-14") })
            #expect(beforeSpring.startDate == fixtureDate("2027-03-08T20:30:00Z")) // UTC-5
            let afterSpring = try #require(events.first { $0.startDate > Self.ny("2027-03-14T12:00") })
            #expect(afterSpring.startDate == fixtureDate("2027-03-15T19:30:00Z")) // UTC-4
            #expect(events.first?.startDate == fixtureDate("2026-10-26T19:30:00Z")) // UTC-4
        }
    }
}
