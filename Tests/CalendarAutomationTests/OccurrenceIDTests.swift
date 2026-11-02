@testable import CalendarAutomation
import Foundation
import Testing

/// The occurrence id is a wire format: clients hold ids from earlier `list`
/// and `search` calls and pass them back later. Every literal here was
/// produced by (or fed to) the implementation this library replaced, in
/// apple-swift-mcp, so an id a client already holds keeps resolving to the
/// same event and the same instant, byte for byte.
@Suite("OccurrenceID wire format")
struct OccurrenceIDTests {
    /// 2026-11-09T20:30:00Z.
    private let nov9 = Date(timeIntervalSince1970: 1_794_256_200)
    /// 2026-01-06T14:00:00Z.
    private let jan6 = Date(timeIntervalSince1970: 1_767_708_000)

    // MARK: - formatting

    @Test("formats as <eventIdentifier>#occ=<UTC ISO-8601, whole seconds, Z>")
    func formats() {
        #expect(OccurrenceID(eventIdentifier: "ABC:123", occurrenceDate: nov9).string
            == "ABC:123#occ=2026-11-09T20:30:00Z")
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: Date(timeIntervalSince1970: 1_793_651_400)).string
            == "X#occ=2026-11-02T20:30:00Z")
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: Date(timeIntervalSince1970: 0)).string
            == "X#occ=1970-01-01T00:00:00Z")
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: Date(timeIntervalSince1970: -1)).string
            == "X#occ=1969-12-31T23:59:59Z")
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: Date(timeIntervalSince1970: 4_102_444_800)).string
            == "X#occ=2100-01-01T00:00:00Z")
    }

    @Test("fractional seconds are dropped, not rounded")
    func truncatesFraction() {
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: jan6.addingTimeInterval(0.75)).string
            == "X#occ=2026-01-06T14:00:00Z")
    }

    @Test("formatting does not depend on the process time zone")
    func zoneIndependent() {
        // A UTC instant whose local date differs from its UTC date almost
        // everywhere west of Greenwich.
        let lateUTC = Date(timeIntervalSince1970: 1_794_268_799) // 2026-11-09T23:59:59Z
        #expect(OccurrenceID(eventIdentifier: "X", occurrenceDate: lateUTC).string == "X#occ=2026-11-09T23:59:59Z")
    }

    // MARK: - parsing: ids clients already hold

    @Test("parses ids the previous implementation emitted", arguments: [
        ("ABC:123#occ=2026-11-09T20:30:00Z", "ABC:123", 1_794_256_200.0),
        ("040000008200E00074C5B7101A82E008#occ=2026-01-06T14:00:00Z", "040000008200E00074C5B7101A82E008", 1_767_708_000),
        ("x@google.com#occ=2026-01-06T14:00:00Z", "x@google.com", 1_767_708_000),
        // An identifier that itself contains the marker: only the LAST one counts.
        (
            "CAL:abc#occ=not-a-date@google.com#occ=2026-01-06T14:00:00Z",
            "CAL:abc#occ=not-a-date@google.com",
            1_767_708_000
        ),
        ("A#occ=2026-01-06T14:00:00Z#occ=2026-01-07T14:00:00Z", "A#occ=2026-01-06T14:00:00Z", 1_767_794_400),
        ("#occ=#occ=2026-11-09T20:30:00Z", "#occ=", 1_794_256_200),
    ])
    func parsesEmittedIDs(raw: String, identifier: String, seconds: Double) throws {
        let id = try #require(OccurrenceID(parsing: raw))
        #expect(id.eventIdentifier == identifier)
        #expect(id.occurrenceDate == Date(timeIntervalSince1970: seconds))
        #expect(id.string == raw)
    }

    @Test("accepts the same lenient timestamp spellings the previous parser did", arguments: [
        ("A#occ=2026-11-09T20:30Z", 1_794_256_200.0),
        ("A#occ=2026-11-09T20:30:00.5Z", 1_794_256_200.5),
        ("A#occ=2026-11-09T20:30:00,25Z", 1_794_256_200.25),
        ("A#occ=2026-11-09Z", 1_794_182_400),
        ("A#occ=2026-11-09t20:30:00Z", 1_794_256_200),
        ("A#occ=2026-11-09 20:30:00Z", 1_794_256_200),
        ("A#occ= 2026-11-09T20:30:00Z", 1_794_256_200),
        ("A#occ=\t2026-11-09T20:30:00Z", 1_794_256_200),
        ("A#occ=2028-02-29T00:00:00Z", 1_835_395_200),
        ("A#occ=2026-11-09T23:59:60Z", 1_794_268_800),
    ])
    func lenientSpellings(raw: String, seconds: Double) throws {
        let id = try #require(OccurrenceID(parsing: raw))
        #expect(id.eventIdentifier == "A")
        #expect(id.occurrenceDate == Date(timeIntervalSince1970: seconds))
    }

    @Test("anything else is not an occurrence id", arguments: [
        "ABC:123", "", "#occ=2026-11-09T20:30:00Z",
        "CAL:abc#occ=not-a-date@google.com",
        "A#occ=2026-01-06T14:00:00Z#occ=junk",
        "A#occ=2026-11-09T20:30:00Z ", "A#occ=2026-11-09T20:30:00z", "A#occ=2026-11-09T20:30:00+00:00",
        "A#occ=2026-11-09T20:30:00", "A#occ=2026-11-09",
        "A#occ=2026-02-29T00:00:00Z", "A#occ=2026-11-09T24:00:00Z", "A#occ=2026-13-09T20:30:00Z",
        "A#occ=2026-11-31T20:30:00Z", "A#occ=2026-11-09T20:30:00.Z", "A#occ=２026-11-09T20:30:00Z",
        "A#occ=2026-11-09T20:3:00Z", "A#occ=99999-11-09T20:30:00Z", "A#OCC=2026-11-09T20:30:00Z",
        "A#occ=2026-11-09T20:30:00ZZ",
    ])
    func notAnOccurrenceID(raw: String) {
        #expect(OccurrenceID(parsing: raw) == nil)
        let ref = EventReference(parsing: raw)
        #expect(ref.eventIdentifier == raw)
        #expect(ref.occurrenceDate == nil)
    }

    // MARK: - EventReference and listingID go through OccurrenceID

    @Test("EventReference splits an occurrence id exactly as OccurrenceID does")
    func eventReferenceAgrees() {
        let ref = EventReference(parsing: "ABC:123#occ=2026-11-09T20:30:00Z")
        #expect(ref == EventReference(eventIdentifier: "ABC:123", occurrenceDate: nov9))
    }

    @Test("listingID emits the occurrence id for a recurring event and the bare id otherwise")
    func listingID() {
        #expect(EventReference.listingID(eventIdentifier: "ABC:123", occurrenceDate: nov9, isRecurring: true)
            == "ABC:123#occ=2026-11-09T20:30:00Z")
        #expect(EventReference.listingID(eventIdentifier: "ABC:123", occurrenceDate: nov9, isRecurring: false)
            == "ABC:123")
    }

    @Test("round-trips whole-second dates for identifiers containing the marker")
    func roundTrip() throws {
        for ident in ["CAL:abc#occ=not-a-date@google.com", "A#occ=2026-01-06T14:00:00Z", "#", "#occ="] {
            let s = OccurrenceID(eventIdentifier: ident, occurrenceDate: jan6).string
            let back = try #require(OccurrenceID(parsing: s))
            #expect(back == OccurrenceID(eventIdentifier: ident, occurrenceDate: jan6))
        }
    }
}
