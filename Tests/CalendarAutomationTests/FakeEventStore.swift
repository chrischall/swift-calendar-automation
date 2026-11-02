@testable import CalendarAutomation
import Foundation

/// In-memory test double for `EventStoreProtocol`. Each test constructs a
/// fresh instance, seeds it with calendar names and events, and inspects
/// the recorded calls afterward.
final class FakeEventStore: EventStoreProtocol, LockedFake {
    /// Recorded calls so tests can assert what the service asked for.
    struct EventsCall: Equatable {
        let start: Date
        let end: Date
        let calendarName: String?
    }

    struct State {
        /// Seedable fixtures.
        var calendars: [String] = []
        var eventsByCalendar: [String: [CalendarEvent]] = [:]
        var authorized: Bool = true
        /// When set, update/delete/get throw this instead of succeeding.
        var failWith: EventStoreError?
        /// The account behind each calendar, for cross-account moves. A
        /// calendar not listed here shares one default account.
        var accountByCalendar: [String: String] = [:]

        var eventsCalls: [EventsCall] = []
        var createdEvents: [CalendarEvent] = []
        var updates: [
            (
                id: String, calendarName: String?, startDate: Date?, endDate: Date?, isAllDay: Bool?,
                span: EventSpan, recurrence: RecurrenceChange
            )
        ] = []
        var deletes: [(id: String, span: EventSpan)] = []

        func requireAuthorized() throws {
            if !authorized {
                throw EventStoreError.notAuthorized("fake store")
            }
        }

        func event(id: String) -> CalendarEvent? {
            eventsByCalendar.values.flatMap(\.self).first { $0.id == id }
        }
    }

    let state = Locked(State())

    func listCalendarNames() async throws -> [String] {
        try state.withLock { s in
            try s.requireAuthorized()
            return s.calendars
        }
    }

    func events(
        from start: Date,
        to end: Date,
        calendarName: String?
    ) async throws -> [CalendarEvent] {
        try state.withLock { s in
            try s.requireAuthorized()
            s.eventsCalls.append(.init(start: start, end: end, calendarName: calendarName))
            let pool: [CalendarEvent] = if let name = calendarName {
                s.eventsByCalendar[name] ?? []
            } else {
                s.eventsByCalendar.values.flatMap(\.self)
            }
            return pool.filter { $0.startDate >= start && $0.startDate < end }
        }
    }

    func event(id: String) async throws -> CalendarEvent? {
        try state.withLock { s in
            try s.requireAuthorized()
            if let failWith = s.failWith {
                throw failWith
            }
            return s.event(id: id)
        }
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        location: String?,
        notes: String?,
        isAllDay: Bool,
        recurrence: Recurrence?,
        timeZone: TimeZone?
    ) async throws -> String {
        try state.withLock { s in
            try s.requireAuthorized()
            guard s.calendars.contains(calendarName) else {
                throw EventStoreError.calendarNotFound(calendarName)
            }
            let id = "fake-\(UUID().uuidString)"
            let ev = CalendarEvent(
                id: id, title: title, location: location, notes: notes,
                startDate: startDate, endDate: endDate,
                calendarName: calendarName, isAllDay: isAllDay, isRecurring: recurrence != nil,
                recurrence: recurrence, timeZone: timeZone?.identifier
            )
            s.eventsByCalendar[calendarName, default: []].append(ev)
            s.createdEvents.append(ev)
            return id
        }
    }

    func updateEvent(
        id: String,
        title _: String?,
        startDate: Date?,
        endDate: Date?,
        calendarName: String?,
        location _: String?,
        notes _: String?,
        isAllDay: Bool?,
        span: EventSpan,
        recurrence: RecurrenceChange
    ) async throws {
        try state.withLock { s in
            try s.requireAuthorized()
            if let failWith = s.failWith {
                throw failWith
            }
            s.updates.append((
                id: id, calendarName: calendarName,
                startDate: startDate, endDate: endDate, isAllDay: isAllDay, span: span,
                recurrence: recurrence
            ))
        }
    }

    func checkMove(id: String, toCalendar calendarName: String) async throws {
        try state.withLock { s in
            try s.requireAuthorized()
            if let failWith = s.failWith {
                throw failWith
            }
            guard s.calendars.contains(calendarName) else {
                throw EventStoreError.calendarNotFound(calendarName)
            }
            guard let current = s.event(id: id) else { throw EventStoreError.eventNotFound(id) }
            let from = s.accountByCalendar[current.calendarName] ?? "default"
            let to = s.accountByCalendar[calendarName] ?? "default"
            if from != to {
                throw EventStoreError.crossAccountMove(
                    from: current.calendarName, fromAccount: from, to: calendarName, toAccount: to
                )
            }
        }
    }

    func deleteEvent(id: String, span: EventSpan) async throws {
        try state.withLock { s in
            try s.requireAuthorized()
            if let failWith = s.failWith {
                throw failWith
            }
            s.deletes.append((id: id, span: span))
        }
    }
}
