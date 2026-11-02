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
        declinedByMe: Bool = false
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
    }
}
