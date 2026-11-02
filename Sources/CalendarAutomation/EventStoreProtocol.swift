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
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        location: String?,
        notes: String?,
        isAllDay: Bool
    ) async throws -> String

    /// Apply partial updates to an existing event. Any nil field is left
    /// unchanged. If `calendarName` differs from the event's current
    /// calendar, the event is moved (EventKit reassignment, not copy+delete).
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
    ) async throws

    /// Throw what `updateEvent` would for moving `id` to `calendarName` —
    /// `calendarNotFound`, `crossAccountMove` — without changing anything.
    /// The confirmation preview runs it, so a move that cannot happen is
    /// refused before it is approved.
    func checkMove(id: String, toCalendar calendarName: String) async throws

    /// Delete an event by ID.
    func deleteEvent(id: String, span: EventSpan) async throws
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
}
