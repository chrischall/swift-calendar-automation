@testable import CalendarAutomation
import Foundation
import Testing

/// Stand-in for an `EKEvent` occurrence. EventKit can't be driven from unit
/// tests (no TCC grant on CI), so the occurrence-resolution logic is written
/// against `OccurrenceCandidate` and exercised here with plain values.
private struct Occ: OccurrenceCandidate, Equatable {
    let seriesIdentifier: String
    let occurrenceStart: Date
    let isRecurring: Bool
    let label: String
}

/// fleet-audit#6: every occurrence of a recurring series shares one
/// `eventIdentifier`, and `EKEventStore.event(withIdentifier:)` returns the
/// series' FIRST occurrence. update/delete/get resolved list/search ids that
/// way, so "move Tuesday's standup" moved (or deleted) the first standup
/// ever, and reported success.
@Suite("Calendar recurring-event occurrences")
struct CalendarRecurrenceTests {
    private let week: TimeInterval = 7 * 86400
    /// 2026-01-06T14:00:00Z, a Tuesday.
    private let firstStandup = Date(timeIntervalSince1970: 1_767_708_000)

    /// A weekly series of `count` occurrences sharing one identifier.
    private func weeklySeries(_ id: String = "CAL:standup", count: Int = 40) -> [Occ] {
        (0 ..< count).map { i in
            Occ(seriesIdentifier: id,
                occurrenceStart: firstStandup.addingTimeInterval(Double(i) * week),
                isRecurring: true, label: "week \(i)")
        }
    }

    // MARK: - EventReference

    @Test("a recurring occurrence is listed under an id naming that occurrence")
    func recurringListingIDNamesOccurrence() {
        let occ = firstStandup.addingTimeInterval(38 * week)
        let id = EventReference.listingID(
            eventIdentifier: "CAL:standup", occurrenceDate: occ, isRecurring: true
        )
        #expect(id != "CAL:standup")
        let ref = EventReference(parsing: id)
        #expect(ref.eventIdentifier == "CAL:standup")
        #expect(ref.occurrenceDate == occ)
    }

    @Test("a one-off event keeps its bare EventKit identifier")
    func oneOffListingIDIsBare() {
        let id = EventReference.listingID(
            eventIdentifier: "CAL:dentist", occurrenceDate: firstStandup, isRecurring: false
        )
        #expect(id == "CAL:dentist")
        let ref = EventReference(parsing: id)
        #expect(ref.eventIdentifier == "CAL:dentist")
        #expect(ref.occurrenceDate == nil)
    }

    @Test("identifiers containing the separator characters survive a round trip")
    func separatorInIdentifier() {
        let raw = "CAL:abc#occ=not-a-date@google.com"
        #expect(EventReference(parsing: raw).eventIdentifier == raw)
        #expect(EventReference(parsing: raw).occurrenceDate == nil)

        let id = EventReference.listingID(
            eventIdentifier: raw, occurrenceDate: firstStandup, isRecurring: true
        )
        let ref = EventReference(parsing: id)
        #expect(ref.eventIdentifier == raw)
        #expect(ref.occurrenceDate == firstStandup)
    }

    // MARK: - OccurrenceResolver

    @Test("an occurrence id resolves to that occurrence, not the series' first")
    func resolvesTheListedOccurrence() throws {
        let series = weeklySeries()
        let target = series[38]
        let id = EventReference.listingID(
            eventIdentifier: target.seriesIdentifier,
            occurrenceDate: target.occurrenceStart, isRecurring: true
        )

        var windows: [(Date, Date)] = []
        let resolved = try OccurrenceResolver.resolve(
            id,
            // What EKEventStore.event(withIdentifier:) does: the first one.
            base: { ident in series.first { $0.seriesIdentifier == ident } },
            occurrences: { _, start, end in
                windows.append((start, end))
                return series.filter { $0.occurrenceStart >= start && $0.occurrenceStart < end }
            }
        )

        #expect(resolved == target)
        #expect(resolved != series[0])
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.0 <= target.occurrenceStart && target.occurrenceStart < window.1)
    }

    @Test("another series' occurrence at the same instant is never picked")
    func ignoresOtherSeriesAtSameTime() throws {
        let mine = weeklySeries("CAL:standup")
        let theirs = weeklySeries("CAL:other")
        let target = mine[5]
        let id = EventReference.listingID(
            eventIdentifier: "CAL:standup", occurrenceDate: target.occurrenceStart,
            isRecurring: true
        )
        let resolved = try OccurrenceResolver.resolve(
            id,
            base: { ident in (mine + theirs).first { $0.seriesIdentifier == ident } },
            occurrences: { _, s, e in
                (theirs + mine).filter { $0.occurrenceStart >= s && $0.occurrenceStart < e }
            }
        )
        #expect(resolved == target)
    }

    @Test("a bare id on a recurring series is refused rather than guessed")
    func bareIDOnRecurringIsRefused() {
        let series = weeklySeries()
        #expect(throws: EventStoreError.recurringEventNeedsOccurrence("CAL:standup")) {
            try OccurrenceResolver.resolve(
                "CAL:standup",
                base: { ident in series.first { $0.seriesIdentifier == ident } },
                occurrences: { _, _, _ in series }
            )
        }
    }

    @Test("a bare id on a one-off event resolves to it directly")
    func bareIDOnOneOff() throws {
        let dentist = Occ(seriesIdentifier: "CAL:dentist", occurrenceStart: firstStandup,
                          isRecurring: false, label: "dentist")
        var queried = false
        let resolved = try OccurrenceResolver.resolve(
            "CAL:dentist",
            base: { _ in dentist },
            occurrences: { _, _, _ in queried = true; return [] }
        )
        #expect(resolved == dentist)
        #expect(queried == false)
    }

    @Test("an occurrence that no longer exists is not found — never the first one instead")
    func missingOccurrenceIsNotFound() {
        let series = weeklySeries()
        let gone = firstStandup.addingTimeInterval(12 * week)
        let remaining = series.filter { $0.occurrenceStart != gone }
        let id = EventReference.listingID(
            eventIdentifier: "CAL:standup", occurrenceDate: gone, isRecurring: true
        )
        #expect(throws: EventStoreError.occurrenceNotFound(id: id)) {
            try OccurrenceResolver.resolve(
                id,
                base: { ident in remaining.first { $0.seriesIdentifier == ident } },
                occurrences: { _, s, e in
                    remaining.filter { $0.occurrenceStart >= s && $0.occurrenceStart < e }
                }
            )
        }
    }

    @Test("an occurrence id whose series is gone is event-not-found")
    func missingSeriesIsNotFound() {
        let id = EventReference.listingID(
            eventIdentifier: "CAL:deleted", occurrenceDate: firstStandup, isRecurring: true
        )
        #expect(throws: EventStoreError.eventNotFound(id)) {
            try OccurrenceResolver.resolve(
                id,
                base: { (_: String) -> Occ? in nil },
                occurrences: { _, _, _ in [] }
            )
        }
    }
}
