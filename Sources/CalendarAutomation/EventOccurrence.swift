public import Foundation

/// How far an update/delete on a recurring event reaches. Mirrors EventKit's
/// `EKSpan` without importing EventKit into the service layer.
public enum EventSpan: String, Sendable, Equatable, CaseIterable {
    /// Only the occurrence the id names.
    case thisEvent
    /// That occurrence and every later one in its series.
    case futureEvents
}

/// The id `list`/`search` hand out, split back into the parts needed to
/// find the event again.
///
/// Every occurrence of a recurring series shares one EventKit
/// `eventIdentifier`, and `EKEventStore.event(withIdentifier:)` answers it
/// with the series' *first* occurrence. So a bare identifier can't say which
/// occurrence was meant — "move Tuesday's standup" used to move the first
/// standup ever. A recurring occurrence is therefore listed as
/// `<eventIdentifier>#occ=<occurrence date>` (an ``OccurrenceID``), and the
/// occurrence date is what pins it down.
///
/// The occurrence date is EventKit's `occurrenceDate`: the *original* start
/// of that occurrence, which stays put when a single occurrence is re-timed.
/// That keeps the id stable across the very update it is used for.
///
/// One-off events keep the bare identifier, so ids already held by callers
/// (and the id `create` returns) keep working.
public struct EventReference: Equatable, Sendable {
    public let eventIdentifier: String
    /// Nil for a bare identifier.
    public let occurrenceDate: Date?

    public init(eventIdentifier: String, occurrenceDate: Date?) {
        self.eventIdentifier = eventIdentifier
        self.occurrenceDate = occurrenceDate
    }

    /// Split an id from `listingID`: an ``OccurrenceID`` when `raw` is one,
    /// otherwise the whole string as a bare identifier. See
    /// ``OccurrenceID/init(parsing:)`` for what counts — an identifier that
    /// merely contains `#occ=` (CalDAV UIDs are free text) is read back
    /// whole rather than mangled.
    public init(parsing raw: String) {
        if let occurrence = OccurrenceID(parsing: raw) {
            self.init(eventIdentifier: occurrence.eventIdentifier, occurrenceDate: occurrence.occurrenceDate)
        } else {
            self.init(eventIdentifier: raw, occurrenceDate: nil)
        }
    }

    /// The id to show for an event: occurrence-qualified when it belongs to a
    /// recurring series, bare otherwise.
    public static func listingID(
        eventIdentifier: String, occurrenceDate: Date, isRecurring: Bool
    ) -> String {
        guard isRecurring else { return eventIdentifier }
        return OccurrenceID(eventIdentifier: eventIdentifier, occurrenceDate: occurrenceDate).string
    }
}

/// What the resolver needs to know about one EventKit occurrence. `EKEvent`
/// conforms in `EventKitStore`; tests use plain values, since real EventKit
/// can't be driven without a Calendar grant.
public protocol OccurrenceCandidate {
    /// EventKit's `eventIdentifier` — shared by every occurrence of a series.
    var seriesIdentifier: String { get }
    /// EventKit's `occurrenceDate` (the start date for a one-off event).
    var occurrenceStart: Date { get }
    /// Part of a recurring series (has rules, or is a detached occurrence).
    var isRecurring: Bool { get }
}

/// Turns an id from `list`/`search` into the one occurrence it names.
public enum OccurrenceResolver {
    /// How far either side of the occurrence date to expand the series when
    /// looking for it. A detached occurrence can have been moved off its
    /// original date, but EventKit only returns it for a window containing
    /// its *current* start, so the window has slack; it is scoped to the
    /// event's own calendar, so a month either way stays cheap. An
    /// occurrence moved further than this is reported not found — never
    /// swapped for another one.
    public static let searchRadius: TimeInterval = 31 * 86400

    /// Timestamps round-trip through whole-second ISO strings.
    static let tolerance: TimeInterval = 1

    /// - Parameters:
    ///   - rawID: the id the caller passed.
    ///   - base: `EKEventStore.event(withIdentifier:)` — for a series, its
    ///     first occurrence.
    ///   - occurrences: expand the base event's calendar over a window.
    /// - Throws: `eventNotFound` when the series is gone,
    ///   `occurrenceNotFound` when the named occurrence is,
    ///   `recurringEventNeedsOccurrence` for a bare id on a recurring
    ///   series — acting on "the first occurrence" there is exactly the bug
    ///   this replaces, so it is refused rather than guessed.
    public static func resolve<C: OccurrenceCandidate>(
        _ rawID: String,
        base: (String) throws -> C?,
        occurrences: (C, Date, Date) throws -> [C]
    ) throws -> C {
        let ref = EventReference(parsing: rawID)
        guard let first = try base(ref.eventIdentifier) else {
            throw EventStoreError.eventNotFound(rawID)
        }
        guard let when = ref.occurrenceDate else {
            if first.isRecurring {
                throw EventStoreError.recurringEventNeedsOccurrence(rawID)
            }
            return first
        }
        let candidates = try occurrences(
            first, when.addingTimeInterval(-searchRadius), when.addingTimeInterval(searchRadius)
        )
        guard let match = candidates.first(where: {
            $0.seriesIdentifier == ref.eventIdentifier
                && abs($0.occurrenceStart.timeIntervalSince(when)) < tolerance
        }) else {
            throw EventStoreError.occurrenceNotFound(id: rawID)
        }
        return match
    }
}
