public import Foundation

/// Plain value type representing a calendar event. Mirrors the shape the MCP
/// tool returns to clients, decoupled from EventKit's `EKEvent` so the
/// service layer can be tested without an EventKit-backed store.
public struct CalendarEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let location: String?
    public let notes: String?
    public let startDate: Date
    public let endDate: Date
    public let calendarName: String
    public let isAllDay: Bool
    public let url: String?
    public let isRecurring: Bool
    /// The event is marked "free" rather than busy (EventKit availability).
    public let showsAsFree: Bool
    /// The organizer cancelled it.
    public let isCancelled: Bool
    /// You are an attendee and declined it.
    public let declinedByMe: Bool
    /// The series' repeat rule (EventKit's first rule), nil for a one-off
    /// event. Set on every occurrence of a series.
    public let recurrence: Recurrence?
    /// The event's time zone identifier; nil for a floating event (all-day
    /// events are floating). `until` in ``recurrence`` is wall clock in it.
    public let timeZone: String?
    /// EventKit holds more than one rule for this series; ``recurrence`` is
    /// only the first. Other apps can write several; this library never does.
    public let hasAdditionalRecurrenceRules: Bool
    /// The start of the series' first occurrence, for a recurring event —
    /// what the rule's count and until are measured from. Nil when unknown
    /// or for a one-off event.
    public let seriesStartDate: Date?

    public init(
        id: String,
        title: String,
        location: String? = nil,
        notes: String? = nil,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        isAllDay: Bool = false,
        url: String? = nil,
        isRecurring: Bool = false,
        showsAsFree: Bool = false,
        isCancelled: Bool = false,
        declinedByMe: Bool = false,
        recurrence: Recurrence? = nil,
        timeZone: String? = nil,
        hasAdditionalRecurrenceRules: Bool = false,
        seriesStartDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.url = url
        self.isRecurring = isRecurring
        self.showsAsFree = showsAsFree
        self.isCancelled = isCancelled
        self.declinedByMe = declinedByMe
        self.recurrence = recurrence
        self.timeZone = timeZone
        self.hasAdditionalRecurrenceRules = hasAdditionalRecurrenceRules
        self.seriesStartDate = seriesStartDate
    }
}

public extension CalendarEvent {
    /// The zone ``recurrence`` is read in
    /// (``Recurrence/seriesTimeZone(_:isAllDay:)``): the event's own, or the
    /// current zone for a floating or all-day event (which is where it is
    /// shown).
    var recurrenceTimeZone: TimeZone {
        Recurrence.seriesTimeZone(timeZone.flatMap(TimeZone.init(identifier:)), isAllDay: isAllDay)
    }

    /// ``recurrence`` as a canonical `RRULE` value, nil for a one-off event.
    var rrule: String? { recurrence?.rruleString(timeZone: recurrenceTimeZone) }

    /// ``recurrence`` in plain English (``Recurrence/summary(start:timeZone:isAllDay:)``),
    /// measured from ``seriesStartDate`` — or this occurrence's start when
    /// that's unknown, which can miscount an until's occurrences.
    var recurrenceSummary: String? {
        recurrence?.summary(start: seriesStartDate ?? startDate, timeZone: recurrenceTimeZone, isAllDay: isAllDay)
    }
}
