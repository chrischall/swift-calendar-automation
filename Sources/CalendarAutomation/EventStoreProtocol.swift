public import Foundation

/// Minimal abstraction over EventKit's `EKEventStore` so `CalendarService`
/// can be unit-tested with an in-memory fake. The real implementation
/// (`EventKitStore`) wraps `EKEventStore`; a test double (`FakeEventStore`)
/// lives in the test target.
///
/// Design notes:
/// - We don't expose `EKEvent`/`EKCalendar` across the boundary — the service
///   works in plain `CalendarEvent` value types. That lets tests construct
///   events without EventKit and keeps the tool layer decoupled.
/// - `move(eventID:toCalendarNamed:)` exists because, unlike AppleScript,
///   EventKit genuinely lets you reassign an event's calendar (`event.calendar
///   = dest` then `save:`) — one of the main motivations for this port.
public protocol EventStoreProtocol: Sendable {
    /// Calendar names the user can choose from.
    func listCalendarNames() async throws -> [String]

    /// Events in `[start, end)` optionally scoped to one calendar. When
    /// `calendarName` is nil, all calendars are searched.
    func events(
        from start: Date,
        to end: Date,
        calendarName: String?
    ) async throws -> [CalendarEvent]

    /// Fetch a single event by its identifier, or `nil` when none exists.
    func event(id: String) async throws -> CalendarEvent?

    /// Create a new event. Returns the newly assigned event ID.
    ///
    /// With a `recurrence`, the event becomes a series: its time zone is
    /// set explicitly (`timeZone`, else the current zone; an all-day event
    /// stays floating) and the rule is validated before saving. A `timeZone`
    /// without a rule still sets the event's zone; with neither, the event
    /// is created exactly as before.
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
    ) async throws -> String

    /// Apply partial updates to an existing event. Any nil field is left
    /// unchanged. If `calendarName` differs from the event's current
    /// calendar, the event is moved (EventKit reassignment, not copy+delete).
    ///
    /// `recurrence` changes the repeat rule. On an occurrence of a series it
    /// needs `span == .futureEvents` (else
    /// `EventStoreError.recurrenceChangeNeedsFutureEvents`): the series is
    /// split there and the new rule governs that occurrence onward. On a
    /// one-off event `.set` turns it into a series with either span.
    func updateEvent(
        id: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        calendarName: String?,
        location: String?,
        notes: String?,
        isAllDay: Bool?,
        span: EventSpan,
        recurrence: RecurrenceChange
    ) async throws

    /// Throw what `updateEvent` would for moving `id` to `calendarName` —
    /// `calendarNotFound`, `crossAccountMove` — without changing anything.
    /// The confirmation preview runs it, so a move that cannot happen is
    /// refused before it is approved.
    func checkMove(id: String, toCalendar calendarName: String) async throws

    /// Delete an event by ID.
    func deleteEvent(id: String, span: EventSpan) async throws
}

public extension EventStoreProtocol {
    /// ``createEvent(title:startDate:endDate:calendarName:location:notes:isAllDay:recurrence:timeZone:)``
    /// without a rule or zone — a one-off event, as before rules existed.
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        location: String?,
        notes: String?,
        isAllDay: Bool
    ) async throws -> String {
        try await createEvent(
            title: title, startDate: startDate, endDate: endDate, calendarName: calendarName,
            location: location, notes: notes, isAllDay: isAllDay, recurrence: nil, timeZone: nil
        )
    }

    /// ``updateEvent(id:title:startDate:endDate:calendarName:location:notes:isAllDay:span:recurrence:)``
    /// leaving the repeat rule alone.
    func updateEvent(
        id: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        calendarName: String?,
        location: String?,
        notes: String?,
        isAllDay: Bool?,
        span: EventSpan
    ) async throws {
        try await updateEvent(
            id: id, title: title, startDate: startDate, endDate: endDate, calendarName: calendarName,
            location: location, notes: notes, isAllDay: isAllDay, span: span, recurrence: .unchanged
        )
    }
}

/// What an update does to an event's repeat rule.
public enum RecurrenceChange: Sendable, Equatable, Hashable {
    /// Leave the rule (or its absence) as it is.
    case unchanged
    /// Replace the rule — or add one, turning a one-off event into a series.
    case set(Recurrence)
    /// Remove the rule. From an occurrence (span `.futureEvents`), that
    /// occurrence becomes a one-off and the series ends before it.
    case remove
}

/// Errors the store can raise into the service layer.
public enum EventStoreError: Error, Equatable, Sendable {
    case notAuthorized(String)
    case calendarNotFound(String)
    case eventNotFound(String)
    case invalidDateRange
    /// An EventKit call exceeded its time budget. Surfaced rather than
    /// waited out so one stuck account can't take the whole server down.
    case timedOut(operation: String, seconds: Double)
    /// EventKit can't move an event between calendars owned by different
    /// accounts; the caller has to recreate it instead.
    case crossAccountMove(from: String, fromAccount: String, to: String, toAccount: String)
    case recurringEventNeedsOccurrence(String)
    case occurrenceNotFound(id: String)
    /// A repeat-rule change on an occurrence of a series with span
    /// `.thisEvent`. A rule belongs to the series, so it can only change
    /// from an occurrence onward (`.futureEvents`).
    case recurrenceChangeNeedsFutureEvents(String)
}
