public import EventKit
public import Foundation

/// Concrete `EventStoreProtocol` backed by `EKEventStore`.
///
/// Authorization notes:
/// - macOS 14+ requires `EKEventStore.requestFullAccessToEvents()` for
///   read+write access. Without it, queries silently return only events
///   this process itself created (WriteOnly). The calling binary's
///   `Info.plist` must declare `NSCalendarsFullAccessUsageDescription` —
///   this is the whole point of the Swift port.
/// - Authorization is requested lazily on first use. The first call will
///   block briefly while macOS shows the permission prompt; subsequent
///   calls reuse the granted authorization without prompting.
public actor EventKitStore: EventStoreProtocol {
    // nonisolated(unsafe): EKEventStore isn't formally Sendable but is
    // thread-safe. See CNContactStoreWrapper for the full rationale.
    private nonisolated(unsafe) let store = EKEventStore()
    private var authorized = false

    /// Every synchronous EventKit call runs here — never inline on the
    /// actor, which executes on the cooperative pool the MCP stdio transport
    /// also needs.
    ///
    /// Every EventKit call here is synchronous and talks to `calaccessd`
    /// over XPC; for CalDAV accounts (iCloud, Google) `save(…, commit:
    /// true)` can push to the server before returning. See
    /// `BlockingWorkQueue` for why that work must not block the pool. The
    /// 30s bound exists because a save blocked on an unreachable CalDAV
    /// server otherwise never returns, and neither does the tool call —
    /// indistinguishable, from the client, from a crash.
    private let work = BlockingWorkQueue(
        label: "com.chrischall.swift-calendar-automation.eventkit", timeout: 30
    )

    public init() {}

    /// Run blocking EventKit work on `work`, mapping an overrun to
    /// `EventStoreError.timedOut`.
    private func perform<T: Sendable>(
        _ label: String,
        _ body: @escaping @Sendable (EKEventStore) throws -> T
    ) async throws -> T {
        let box = unsafe UncheckedSendable(store)
        do {
            return try await work.run(label) { try body(box.value) }
        } catch let e as TimedOutError {
            throw EventStoreError.timedOut(operation: e.operation, seconds: e.seconds)
        }
    }

    /// Ensure we have FullAccess. Idempotent: cached after the first grant.
    private func ensureAuthorized() async throws {
        if authorized {
            return
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            authorized = true
            return
        case .denied, .restricted:
            throw EventStoreError.notAuthorized(
                "Calendar access is \(status == .denied ? "denied" : "restricted"). " +
                    "Grant in System Settings → Privacy & Security → Calendars."
            )
        case .writeOnly, .notDetermined:
            // Request full access — pops the macOS permission dialog the
            // first time the process runs.
            let granted: Bool
            do {
                granted = try unsafe await store.requestFullAccessToEvents()
            } catch {
                throw EventStoreError.notAuthorized(
                    "Calendar access request failed: \(error.localizedDescription)"
                )
            }
            guard granted else {
                throw EventStoreError.notAuthorized(
                    "Calendar full-access was denied by the user."
                )
            }
            authorized = true
        @unknown default:
            throw EventStoreError.notAuthorized("Unknown authorization status")
        }
    }

    public func listCalendarNames() async throws -> [String] {
        try await ensureAuthorized()
        return try await perform("list calendars") { store in
            store.calendars(for: .event).map(\.title)
        }
    }

    public func events(
        from start: Date,
        to end: Date,
        calendarName: String?
    ) async throws -> [CalendarEvent] {
        try await ensureAuthorized()
        guard end > start else { throw EventStoreError.invalidDateRange }

        return try await perform("query events") { store in
            let allCalendars = store.calendars(for: .event)
            let scoped: [EKCalendar]
            if let name = calendarName {
                scoped = allCalendars.filter { $0.title == name }
                guard !scoped.isEmpty else {
                    throw EventStoreError.calendarNotFound(name)
                }
            } else {
                scoped = allCalendars
            }

            let predicate = store.predicateForEvents(
                withStart: start, end: end, calendars: scoped
            )
            return store.events(matching: predicate).map { Self.toCalendarEvent($0) }
        }
    }

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        location: String?,
        notes: String?,
        isAllDay: Bool
    ) async throws -> String {
        try await ensureAuthorized()
        return try await perform("create event") { store in
            guard let cal = store.calendars(for: .event)
                .first(where: { $0.title == calendarName })
            else {
                throw EventStoreError.calendarNotFound(calendarName)
            }
            let ev = EKEvent(eventStore: store)
            ev.calendar = cal
            ev.title = title
            ev.startDate = startDate
            ev.endDate = endDate
            ev.isAllDay = isAllDay
            ev.location = location
            ev.notes = notes
            try store.save(ev, span: .thisEvent, commit: true)
            return ev.eventIdentifier ?? ""
        }
    }

    public func updateEvent(
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
        try await ensureAuthorized()
        try await perform("update event") { store in
            let ev = try Self.occurrence(id, in: store)
            if let title {
                ev.title = title
            }
            if let location {
                ev.location = location
            }
            if let notes {
                ev.notes = notes
            }
            if let startDate {
                ev.startDate = startDate
            }
            if let endDate {
                ev.endDate = endDate
            }
            if let isAllDay {
                ev.isAllDay = isAllDay
            }
            if let calendarName {
                ev.calendar = try Self.moveDestination(calendarName, for: ev, in: store)
            }
            try store.save(ev, span: Self.ekSpan(span), commit: true)
        }
    }

    public func checkMove(id: String, toCalendar calendarName: String) async throws {
        try await ensureAuthorized()
        try await perform("check event move") { store in
            _ = try Self.moveDestination(calendarName, for: Self.occurrence(id, in: store), in: store)
        }
    }

    /// The calendar `ev` can be moved to under `calendarName`. One place for
    /// the rules, so the preview's `checkMove` and the save agree.
    private static func moveDestination(
        _ calendarName: String, for ev: EKEvent, in store: EKEventStore
    ) throws -> EKCalendar {
        guard let dest = store.calendars(for: .event)
            .first(where: { $0.title == calendarName })
        else {
            throw EventStoreError.calendarNotFound(calendarName)
        }
        // EventKit can only reassign an event within one account.
        // Across sources (iCloud → Google → On My Mac) the save has
        // to delete server-side in one account and create in the
        // other; EventKit doesn't do that, and the attempt is what
        // makes a cross-account move sit there. Reject it up front
        // with an actionable message.
        if let current = ev.calendar,
           current.source?.sourceIdentifier != dest.source?.sourceIdentifier
        {
            throw EventStoreError.crossAccountMove(
                from: current.title,
                fromAccount: current.source?.title ?? "unknown account",
                to: dest.title,
                toAccount: dest.source?.title ?? "unknown account"
            )
        }
        return dest
    }

    public func deleteEvent(id: String, span: EventSpan) async throws {
        try await ensureAuthorized()
        try await perform("delete event") { store in
            let ev = try Self.occurrence(id, in: store)
            try store.remove(ev, span: Self.ekSpan(span), commit: true)
        }
    }

    public func event(id: String) async throws -> CalendarEvent? {
        try await ensureAuthorized()
        return try await perform("fetch event") { store in
            do {
                return try Self.toCalendarEvent(Self.occurrence(id, in: store))
            } catch EventStoreError.eventNotFound {
                return nil
            }
        }
    }

    /// The one occurrence `id` names. Never `store.event(withIdentifier:)`
    /// alone: for a recurring series that returns the *first* occurrence,
    /// which is how an edit to next Tuesday's standup used to land on the
    /// first standup ever. See `OccurrenceResolver` for the rules.
    private static func occurrence(_ id: String, in store: EKEventStore) throws -> EKEvent {
        try OccurrenceResolver.resolve(
            id,
            base: { store.event(withIdentifier: $0) },
            occurrences: { base, start, end in
                // Scoped to the series' own calendar: the window is wide
                // enough to catch a moved detached occurrence, and expanding
                // every calendar across it would be needless work.
                let predicate = store.predicateForEvents(
                    withStart: start, end: end,
                    calendars: base.calendar.map { [$0] }
                )
                return store.events(matching: predicate)
            }
        )
    }

    private static func ekSpan(_ span: EventSpan) -> EKSpan {
        switch span {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }

    private static func toCalendarEvent(_ ev: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: EventReference.listingID(
                eventIdentifier: ev.eventIdentifier ?? "",
                occurrenceDate: ev.occurrenceStart,
                isRecurring: ev.isRecurring
            ),
            title: ev.title ?? "",
            location: ev.location?.isEmpty == false ? ev.location : nil,
            notes: ev.notes?.isEmpty == false ? ev.notes : nil,
            startDate: ev.startDate ?? Date.distantPast,
            endDate: ev.endDate ?? Date.distantFuture,
            calendarName: ev.calendar?.title ?? "",
            isAllDay: ev.isAllDay,
            url: ev.url?.absoluteString,
            isRecurring: ev.isRecurring,
            showsAsFree: ev.availability == .free,
            isCancelled: ev.status == .canceled,
            // `hasAttendees` first: list/search map every event in up to a
            // year of recurrences, and most have no attendees to fault in.
            declinedByMe: ev.hasAttendees && (ev.attendees?.contains {
                $0.isCurrentUser && $0.participantStatus == .declined
            } ?? false)
        )
    }
}

extension EKEvent: OccurrenceCandidate {
    public var seriesIdentifier: String { eventIdentifier ?? "" }
    /// `occurrenceDate` is the occurrence's original start, unchanged when a
    /// single occurrence is re-timed; EventKit documents it as the start date
    /// for a one-off event, but it is an implicitly unwrapped optional.
    public var occurrenceStart: Date { occurrenceDate ?? startDate ?? .distantPast }
    public var isRecurring: Bool { hasRecurrenceRules || isDetached }
}
