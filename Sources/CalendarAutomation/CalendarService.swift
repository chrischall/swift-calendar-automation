public import Foundation

/// Errors surfaced by `CalendarService` to the MCP tool layer.
public enum CalendarServiceError: Error, Equatable, Sendable {
    case noCalendarResolvable(available: [String])
    /// The ordering guard rejected the range. Carries both operands so the
    /// tool layer can show what it actually compared — an ordering error
    /// that doesn't name the dates reads like a parse error and sends
    /// people looking in the wrong place.
    case invalidDateRange(start: Date, end: Date, isAllDay: Bool)
}

/// Thin service layer over an `EventStoreProtocol`. Contains the business
/// logic (defaults, search filtering, calendar-name resolution) that doesn't
/// belong in the EventKit wrapper or in the MCP tool handler.
public struct CalendarService: Sendable {
    private let store: any EventStoreProtocol
    /// Optional default calendar, resolved at service-construction time from
    /// `APPLE_MCP_DEFAULT_CALENDAR`. Callers can still pass an explicit
    /// `calendarName` per request.
    public let defaultCalendar: String?

    public init(store: any EventStoreProtocol, defaultCalendar: String? = nil) {
        self.store = store
        self.defaultCalendar = defaultCalendar
    }

    /// List the names of all calendars the user has access to. Useful for
    /// discovery when the caller doesn't know which `calendarName` to pass.
    public func listCalendarNames() async throws -> [String] {
        try await store.listCalendarNames()
    }

    /// Search for events whose title, location, or notes contain `query`
    /// (case-insensitive). Bounded by a date range for efficiency.
    public func searchEvents(
        query: String,
        from: Date,
        to: Date,
        calendarName: String? = nil,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> CalendarEventPage {
        let events = try await store.events(from: from, to: to, calendarName: calendarName)
        let needle = query.lowercased()
        let matches = events.filter { ev in
            ev.title.lowercased().contains(needle)
                || (ev.location?.lowercased().contains(needle) ?? false)
                || (ev.notes?.lowercased().contains(needle) ?? false)
        }
        return Self.page(matches, from: from, to: to, limit: limit, offset: offset)
    }

    /// List events in a date range. When `calendarName` is nil, all
    /// calendars are searched. When provided, only that calendar.
    public func listEvents(
        from: Date,
        to: Date,
        calendarName: String? = nil,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> CalendarEventPage {
        let events = try await store.events(from: from, to: to, calendarName: calendarName)
        return Self.page(events, from: from, to: to, limit: limit, offset: offset)
    }

    /// Open slots within working hours across the calendars in scope (one
    /// calendar with `calendarName`, else all of them). The busy/free rules
    /// are `FreeTimeFinder`'s.
    public func freeTime(_ query: FreeTimeQuery, calendarName: String? = nil) async throws -> FreeTimeResult {
        let events = try await store.events(from: query.from, to: query.to, calendarName: calendarName)
        return FreeTimeFinder.find(query, in: events)
    }

    /// Sort, count, and slice one window's matches into a page.
    ///
    /// The sort is not cosmetic. EventKit's `events(matching:)` promises no
    /// ordering, and when several calendars are in scope it yields them
    /// calendar by calendar — so an unsorted `prefix(limit)` returned the
    /// first calendar's events and called that "the next 10", which is both
    /// the wrong 10 and unstable to page through. `totalMatched` is taken
    /// before the slice so the tool layer can say how much it is holding
    /// back.
    ///
    /// A `limit` of zero or less means **unbounded**, not "return nothing".
    /// Returning nothing would build a page that is empty while
    /// `totalMatched` is positive — a state whose only honest reading is
    /// "you paged past the end", which the caller did not do. The tool layer
    /// refuses such a `limit` outright; this is the library-level contract
    /// behind that, so no caller can construct the phantom page.
    private static func page(
        _ matches: [CalendarEvent], from: Date, to: Date, limit: Int, offset: Int
    ) -> CalendarEventPage {
        let ordered = matches.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            if $0.title != $1.title {
                return $0.title < $1.title
            }
            return $0.id < $1.id
        }
        let start = min(max(0, offset), ordered.count)
        // `start + min(limit, remaining)`, never `start + limit`: with
        // `limit: Int.max` the plain sum overflowed and trapped the server.
        let end = limit <= 0 ? ordered.count : start + min(limit, ordered.count - start)
        return CalendarEventPage(
            events: Array(ordered[start ..< end]),
            totalMatched: ordered.count,
            offset: start,
            from: from,
            to: to
        )
    }

    /// Fetch a single event by id, or `nil` when no event matches. Useful
    /// for retrieving an event's full detail after a list/search.
    public func event(id: String) async throws -> CalendarEvent? {
        try await store.event(id: id)
    }

    /// Create an event. `calendarName` precedence:
    ///   1. Explicit argument
    ///   2. `defaultCalendar` on the service
    ///   3. Error with the list of available calendars
    ///
    /// With a `recurrence` the event is a series, validated against
    /// `startDate` in `timeZone` (the current zone when nil, and for an
    /// all-day event, which stays floating) before anything is written.
    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String?,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false,
        recurrence: Recurrence? = nil,
        timeZone: TimeZone? = nil
    ) async throws -> String {
        let target = try await createTarget(
            calendarName: calendarName, startDate: startDate, endDate: endDate, isAllDay: isAllDay,
            recurrence: recurrence, timeZone: timeZone
        )
        return try await store.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarName: target,
            location: location,
            notes: notes,
            isAllDay: isAllDay,
            recurrence: recurrence,
            timeZone: timeZone
        )
    }

    /// Everything `createEvent` checks before writing, and the calendar it
    /// would write to. The confirmation preview runs this first, so a
    /// request that would fail is refused rather than approved.
    public func createTarget(
        calendarName: String?, startDate: Date, endDate: Date, isAllDay: Bool,
        recurrence: Recurrence? = nil, timeZone: TimeZone? = nil
    ) async throws -> String {
        // Both operands are real, parsed dates by the time they get here —
        // the tool layer fails parse errors before calling in. All-day
        // events use `>=` because EventKit treats an all-day event's end
        // date as inclusive, so a single-day all-day event legitimately has
        // end == start.
        guard isAllDay ? endDate >= startDate : endDate > startDate else {
            throw CalendarServiceError.invalidDateRange(
                start: startDate, end: endDate, isAllDay: isAllDay
            )
        }
        try recurrence?.validate(
            start: startDate, timeZone: Self.seriesZone(timeZone, isAllDay: isAllDay), isAllDay: isAllDay
        )
        let resolved = calendarName?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? defaultCalendar?.trimmingCharacters(in: .whitespaces).nonEmpty
        let available = try await store.listCalendarNames()
        guard let target = resolved else {
            throw CalendarServiceError.noCalendarResolvable(available: available)
        }
        // The store matches the title exactly; so does this.
        guard available.contains(target) else {
            throw EventStoreError.calendarNotFound(target)
        }
        return target
    }

    /// The zone a series' rule is read in: the event's, or the current zone
    /// for a floating (incl. every all-day) event. Shared with the store.
    static func seriesZone(_ timeZone: TimeZone?, isAllDay: Bool) -> TimeZone {
        isAllDay ? .current : timeZone ?? .current
    }

    /// Throw what `updateEvent` would for moving `id` to `calendarName`
    /// (unknown calendar, another account), without changing anything.
    public func checkMove(id: String, toCalendar calendarName: String) async throws {
        try await store.checkMove(id: id, toCalendar: calendarName)
    }

    /// Apply partial updates. When `calendarName` differs from the event's
    /// current calendar, the store is expected to perform a true reassign
    /// (EventKit supports this natively, unlike AppleScript). `nil` fields
    /// are preserved.
    ///
    /// `recurrence` changes the repeat rule; see
    /// ``checkRecurrenceChange(id:recurrence:startDate:isAllDay:span:)`` for
    /// what is refused. `.unchanged` (the default) costs nothing extra.
    public func updateEvent(
        id: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarName: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool? = nil,
        span: EventSpan = .thisEvent,
        recurrence: RecurrenceChange = .unchanged
    ) async throws {
        try await checkRecurrenceChange(
            id: id, recurrence: recurrence, startDate: startDate, isAllDay: isAllDay, span: span
        )
        if let s = startDate, let e = endDate {
            // A nil `isAllDay` means "leave it as it is", so the inclusive-end
            // rule has to come from the event's *current* value rather than a
            // default of false — otherwise re-dating an existing all-day event
            // onto a single day is rejected for an ordering problem it doesn't
            // have. Only costs a fetch when both dates change and the caller
            // didn't say.
            let allDay: Bool = if let isAllDay {
                isAllDay
            } else {
                await ((try? store.event(id: id)) ?? nil)?.isAllDay ?? false
            }
            guard allDay ? e >= s : e > s else {
                throw CalendarServiceError.invalidDateRange(
                    start: s, end: e, isAllDay: allDay
                )
            }
        }
        try await store.updateEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            location: location,
            notes: notes,
            isAllDay: isAllDay,
            span: span,
            recurrence: recurrence
        )
    }

    /// Throw what `updateEvent` would for this repeat-rule change, without
    /// changing anything — the confirmation preview runs it.
    ///
    /// - On an occurrence of a series, any change needs `span ==
    ///   .futureEvents` (`EventStoreError.recurrenceChangeNeedsFutureEvents`).
    /// - A new rule is validated against the start it will repeat from: the
    ///   new `startDate` when given, else the occurrence's (or one-off
    ///   event's) start, in the event's zone.
    /// - `.unchanged` checks nothing and fetches nothing.
    public func checkRecurrenceChange(
        id: String, recurrence: RecurrenceChange, startDate: Date? = nil, isAllDay: Bool? = nil,
        span: EventSpan
    ) async throws {
        guard recurrence != .unchanged else { return }
        guard let current = try await store.event(id: id) else { throw EventStoreError.eventNotFound(id) }
        if current.isRecurring, span != .futureEvents {
            throw EventStoreError.recurrenceChangeNeedsFutureEvents(id)
        }
        if case let .set(rule) = recurrence {
            let allDay = isAllDay ?? current.isAllDay
            let zone = Self.seriesZone(current.timeZone.flatMap(TimeZone.init(identifier:)), isAllDay: allDay)
            try rule.validate(start: startDate ?? current.startDate, timeZone: zone, isAllDay: allDay)
        }
    }

    /// Delete a single event by id. Store-level errors (not authorized,
    /// event not found) are surfaced as-is so the tool layer can render
    /// them verbatim.
    public func deleteEvent(id: String, span: EventSpan = .thisEvent) async throws {
        try await store.deleteEvent(id: id, span: span)
    }
}
