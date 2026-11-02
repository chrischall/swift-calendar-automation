@testable import CalendarAutomation
import Foundation
import Testing

@Suite("CalendarService")
struct CalendarServiceTests {
    private func date(_ iso: String) -> Date { fixtureDate(iso) }

    @Test("listEvents passes the date range and calendar scope to the store")
    func listEventsDelegatesQuery() async throws {
        let store = FakeEventStore()
        store.calendars = ["Work"]
        store.eventsByCalendar["Work"] = [
            CalendarEvent(
                id: "w1", title: "Standup",
                startDate: date("2026-04-20T09:00:00.000Z"),
                endDate: date("2026-04-20T09:15:00.000Z"),
                calendarName: "Work"
            ),
        ]
        let svc = CalendarService(store: store)

        let results = try await svc.listEvents(
            from: date("2026-04-20T00:00:00.000Z"),
            to: date("2026-04-21T00:00:00.000Z"),
            calendarName: "Work"
        )

        #expect(results.events.count == 1)
        #expect(results.events[0].title == "Standup")
        #expect(store.eventsCalls.count == 1)
        #expect(store.eventsCalls[0].calendarName == "Work")
    }

    @Test("searchEvents matches against title, location, and notes case-insensitively")
    func searchEventsCaseInsensitive() async throws {
        let store = FakeEventStore()
        store.calendars = ["Kids"]
        let base = date("2026-04-20T09:00:00.000Z")
        store.eventsByCalendar["Kids"] = [
            CalendarEvent(id: "e1", title: "SOCCER practice",
                          startDate: base, endDate: base.addingTimeInterval(3600),
                          calendarName: "Kids"),
            CalendarEvent(id: "e2", title: "Dentist", location: "123 Soccer Ln",
                          startDate: base.addingTimeInterval(3600),
                          endDate: base.addingTimeInterval(7200),
                          calendarName: "Kids"),
            CalendarEvent(id: "e3", title: "Dentist", notes: "Bring Soccer cleats",
                          startDate: base.addingTimeInterval(7200),
                          endDate: base.addingTimeInterval(10800),
                          calendarName: "Kids"),
            CalendarEvent(id: "e4", title: "Haircut",
                          startDate: base.addingTimeInterval(10800),
                          endDate: base.addingTimeInterval(14400),
                          calendarName: "Kids"),
        ]
        let svc = CalendarService(store: store)

        let results = try await svc.searchEvents(
            query: "soccer",
            from: date("2026-04-20T00:00:00.000Z"),
            to: date("2026-04-21T00:00:00.000Z"),
            calendarName: "Kids"
        )

        let ids = results.events.map(\.id).sorted()
        #expect(ids == ["e1", "e2", "e3"])
    }

    @Test("searchEvents returns an empty array when nothing matches")
    func searchEventsNoMatches() async throws {
        let store = FakeEventStore()
        store.calendars = ["Kids"]
        store.eventsByCalendar["Kids"] = [
            CalendarEvent(id: "e1", title: "Birthday Party",
                          startDate: date("2026-04-20T12:00:00.000Z"),
                          endDate: date("2026-04-20T15:00:00.000Z"),
                          calendarName: "Kids"),
        ]
        let svc = CalendarService(store: store)

        let results = try await svc.searchEvents(
            query: "soccer",
            from: date("2026-04-20T00:00:00.000Z"),
            to: date("2026-04-21T00:00:00.000Z")
        )

        #expect(results.events.isEmpty)
    }

    // ─── listCalendarNames ─────────────────────────────────────────────────

    @Test("listCalendarNames returns the store's calendar names")
    func listCalendarNamesDelegates() async throws {
        let store = FakeEventStore()
        store.calendars = ["Erik", "Personal", "Work"]
        let svc = CalendarService(store: store)

        let names = try await svc.listCalendarNames()

        #expect(names == ["Erik", "Personal", "Work"])
    }

    // ─── createEvent ───────────────────────────────────────────────────────

    @Test("createEvent delegates to the store and returns the new id")
    func createEventDelegates() async throws {
        let store = FakeEventStore()
        store.calendars = ["Personal"]
        let svc = CalendarService(store: store)

        let id = try await svc.createEvent(
            title: "Lunch",
            startDate: date("2026-04-22T12:00:00.000Z"),
            endDate: date("2026-04-22T13:00:00.000Z"),
            calendarName: "Personal"
        )

        #expect(id.hasPrefix("fake-"))
        #expect(store.createdEvents.count == 1)
        #expect(store.createdEvents[0].title == "Lunch")
        #expect(store.createdEvents[0].calendarName == "Personal")
    }

    @Test("createEvent falls back to defaultCalendar when no calendarName is given")
    func createEventUsesDefault() async throws {
        let store = FakeEventStore()
        store.calendars = ["Erik"]
        let svc = CalendarService(store: store, defaultCalendar: "Erik")

        _ = try await svc.createEvent(
            title: "Practice",
            startDate: date("2026-04-22T18:00:00.000Z"),
            endDate: date("2026-04-22T19:30:00.000Z"),
            calendarName: nil
        )

        #expect(store.createdEvents.count == 1)
        #expect(store.createdEvents[0].calendarName == "Erik")
    }

    @Test("createEvent errors when no calendar is resolvable")
    func createEventNoCalendarError() async throws {
        let store = FakeEventStore()
        store.calendars = ["A", "B"]
        let svc = CalendarService(store: store, defaultCalendar: nil)

        await #expect(throws: CalendarServiceError.self) {
            _ = try await svc.createEvent(
                title: "Nope",
                startDate: self.date("2026-04-22T12:00:00.000Z"),
                endDate: self.date("2026-04-22T13:00:00.000Z"),
                calendarName: nil
            )
        }
    }

    @Test("createEvent rejects end date <= start date")
    func createEventInvalidRange() async throws {
        let store = FakeEventStore()
        store.calendars = ["Personal"]
        let svc = CalendarService(store: store)

        await #expect(throws: CalendarServiceError.self) {
            _ = try await svc.createEvent(
                title: "Bad",
                startDate: self.date("2026-04-22T13:00:00.000Z"),
                endDate: self.date("2026-04-22T12:00:00.000Z"),
                calendarName: "Personal"
            )
        }
    }

    // ─── updateEvent ───────────────────────────────────────────────────────

    @Test("updateEvent passes provided fields through to the store")
    func updateEventDelegates() async throws {
        let store = FakeEventStore()
        store.calendars = ["Work"]
        let svc = CalendarService(store: store)

        try await svc.updateEvent(
            id: "evt-1",
            title: "Renamed",
            calendarName: "Work"
        )

        #expect(store.updates.count == 1)
        #expect(store.updates[0].id == "evt-1")
        #expect(store.updates[0].calendarName == "Work")
    }

    @Test("updateEvent rejects end date <= start date when both are provided")
    func updateEventInvalidRange() async throws {
        let store = FakeEventStore()
        store.calendars = ["Work"]
        let svc = CalendarService(store: store)

        await #expect(throws: CalendarServiceError.self) {
            try await svc.updateEvent(
                id: "evt-1",
                startDate: self.date("2026-04-22T14:00:00.000Z"),
                endDate: self.date("2026-04-22T13:00:00.000Z")
            )
        }
    }

    // ─── deleteEvent ───────────────────────────────────────────────────────

    @Test("deleteEvent forwards the id to the store")
    func deleteEventDelegates() async throws {
        let store = FakeEventStore()
        let svc = CalendarService(store: store)

        try await svc.deleteEvent(id: "evt-1")

        #expect(store.deletes.map(\.id) == ["evt-1"])
    }

    @Test("deleteEvent surfaces store errors (e.g. event not found)")
    func deleteEventPropagatesStoreError() async throws {
        let store = FakeEventStore()
        store.authorized = false
        let svc = CalendarService(store: store)

        await #expect(throws: EventStoreError.self) {
            try await svc.deleteEvent(id: "anything")
        }
    }

    @Test("listEvents honors the limit across events the store returns")
    func listEventsRespectsLimit() async throws {
        let store = FakeEventStore()
        store.calendars = ["Personal"]
        let base = date("2026-04-20T09:00:00.000Z")
        store.eventsByCalendar["Personal"] = (0 ..< 5).map { i in
            CalendarEvent(
                id: "e\(i)", title: "Event \(i)",
                startDate: base.addingTimeInterval(Double(i) * 3600),
                endDate: base.addingTimeInterval(Double(i) * 3600 + 1800),
                calendarName: "Personal"
            )
        }
        let svc = CalendarService(store: store)

        let results = try await svc.listEvents(
            from: date("2026-04-20T00:00:00.000Z"),
            to: date("2026-04-21T00:00:00.000Z"),
            calendarName: "Personal",
            limit: 2
        )

        #expect(results.events.count == 2)
    }

    @Test("a limit of zero or less means unbounded, never an empty page with matches behind it")
    func listEventsTreatsNonPositiveLimitAsUnbounded() async throws {
        let store = FakeEventStore()
        store.calendars = ["Personal"]
        let base = date("2026-04-20T09:00:00.000Z")
        store.eventsByCalendar["Personal"] = (0 ..< 5).map { i in
            CalendarEvent(
                id: "e\(i)", title: "Event \(i)",
                startDate: base.addingTimeInterval(Double(i) * 3600),
                endDate: base.addingTimeInterval(Double(i) * 3600 + 1800),
                calendarName: "Personal"
            )
        }
        let svc = CalendarService(store: store)

        for limit in [0, -1] {
            let results = try await svc.listEvents(
                from: date("2026-04-20T00:00:00.000Z"),
                to: date("2026-04-21T00:00:00.000Z"),
                calendarName: "Personal",
                limit: limit
            )

            // The alternative — an empty `events` with `totalMatched` 5 — is a
            // page that renders as "you have paged past the end" about a
            // caller who never paged at all.
            #expect(results.events.count == 5)
            #expect(results.totalMatched == 5)
            #expect(results.hasMore == false)
            #expect(results.nextOffset == nil)
        }
    }

    @Test("pages are in chronological order across calendars, whatever order the store returns")
    func pagesAreChronological() async throws {
        let store = FakeEventStore()
        store.calendars = ["A", "B"]
        let base = date("2026-09-07T00:00:00Z")
        // Two calendars interleaved in time; the fake concatenates them, so
        // an unsorted `prefix(limit)` would return all of one calendar first.
        store.eventsByCalendar["A"] = (0 ..< 5).map { i in
            let s = base.addingTimeInterval(Double(i) * 2 * 3600)
            return CalendarEvent(id: "a\(i)", title: "A\(i)", startDate: s,
                                 endDate: s.addingTimeInterval(600), calendarName: "A")
        }
        store.eventsByCalendar["B"] = (0 ..< 5).map { i in
            let s = base.addingTimeInterval(Double(i) * 2 * 3600 + 3600)
            return CalendarEvent(id: "b\(i)", title: "B\(i)", startDate: s,
                                 endDate: s.addingTimeInterval(600), calendarName: "B")
        }
        let svc = CalendarService(store: store)

        let first = try await svc.listEvents(from: base, to: base.addingTimeInterval(86400), limit: 4)
        #expect(first.events.map(\.title) == ["A0", "B0", "A1", "B1"])
        #expect(first.totalMatched == 10)
        #expect(first.nextOffset == 4)

        let last = try await svc.listEvents(from: base, to: base.addingTimeInterval(86400), limit: 4, offset: 8)
        #expect(last.events.map(\.title) == ["A4", "B4"])
        #expect(last.hasMore == false)
        #expect(last.remaining == 0)
    }
}
