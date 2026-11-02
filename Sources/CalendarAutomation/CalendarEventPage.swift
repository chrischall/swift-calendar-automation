public import Foundation

/// One page of a calendar query, carrying enough context that the caller can
/// tell a genuinely empty calendar from a query that stopped early.
///
/// `listEvents`/`searchEvents` used to hand back a bare `[CalendarEvent]`.
/// That array cannot distinguish "nothing is scheduled" from "the window was
/// narrower than you asked for" or "there were 57 matches and you got the
/// first 10" — and on a scheduling tool those read the same and mean opposite
/// things. Everything needed to say which is the case travels with the
/// events, so the tool layer can't render a truncated answer as a complete
/// one by forgetting to ask.
public struct CalendarEventPage: Sendable, Equatable {
    /// The events on this page, in chronological order.
    public let events: [CalendarEvent]
    /// How many events matched inside `from ..< to`, before `limit`/`offset`.
    public let totalMatched: Int
    /// Index of the first event on this page within the full match list.
    public let offset: Int
    /// The window actually queried. Not necessarily the one requested —
    /// the tool layer refuses rather than clips, but this is the record of
    /// what was examined, and nothing outside it was.
    public let from: Date
    public let to: Date

    public init(
        events: [CalendarEvent],
        totalMatched: Int,
        offset: Int,
        from: Date,
        to: Date
    ) {
        self.events = events
        self.totalMatched = totalMatched
        self.offset = offset
        self.from = from
        self.to = to
    }

    /// True when matches exist past the end of this page.
    public var hasMore: Bool { offset + events.count < totalMatched }

    /// Matches after this page, or 0 at the end of the list.
    public var remaining: Int { max(0, totalMatched - (offset + events.count)) }

    /// The `offset` that fetches the next page, or nil when this is the last.
    public var nextOffset: Int? { hasMore ? offset + events.count : nil }
}
