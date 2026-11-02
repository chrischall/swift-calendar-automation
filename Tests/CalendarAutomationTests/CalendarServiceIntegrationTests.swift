@testable import CalendarAutomation
import EventKit
import Foundation
import Testing

/// End-to-end tests against the user's real EventKit store.
///
/// **Never touches existing user calendars.** Every test creates a
/// dedicated, UUID-named test calendar via `CalendarTestFixture`, runs
/// assertions entirely within it, and deletes it at the end. A crashed
/// run leaves behind an obviously-named `AppleSwiftMCPTest-*` calendar
/// that the next run's `cleanUpOrphans` call will remove before doing
/// anything else.
///
/// **Opt-in** via `CALENDAR_INTEGRATION=1`. Unset, every test in this
/// suite is skipped — CI and normal `swift test` runs stay
/// deterministic and never pop permission prompts.
///
/// ```bash
/// CALENDAR_INTEGRATION=1 swift test
/// ```
///
/// **Permissions required on first run**:
/// - Calendar (System Settings → Privacy & Security → Calendars → grant
///   full access to the test binary)
/// **Serialized.** Every test's `setUp` calls
/// `CalendarTestFixture.cleanUpOrphans`, which deletes *all*
/// `AppleSwiftMCPTest-*` calendars. Run in parallel (swift-testing's
/// default) the tests delete each other's fixtures mid-flight and fail
/// with `calendarNotFound` / "Object not found. It may have been
/// deleted." — a suite-level race, not a product bug.
@Suite("CalendarService integration", .serialized)
struct CalendarServiceIntegrationTests {
    // MARK: - fixtures

    /// Per-test setup: requests EventKit authorization, cleans up any
    /// orphan fixture calendars left by a prior run, creates a fresh
    /// one, and returns both the raw EKCalendar handle and the service
    /// bound to the store that owns it.
    private static func setUp() async throws -> (EKCalendar, CalendarService, EKEventStore) {
        let store = EKEventStore()

        let authorized: Bool
        do {
            authorized = try await store.requestFullAccessToEvents()
        } catch {
            Issue.record("EventKit auth request failed: \(error.localizedDescription)")
            throw error
        }
        guard authorized else {
            Issue.record("EventKit full access was not granted")
            struct AuthDenied: Swift.Error {}
            throw AuthDenied()
        }

        // Clean up any orphans from a prior crashed run before creating
        // a new fixture.
        CalendarTestFixture.cleanUpOrphans(store: store)

        let testCal = try CalendarTestFixture.create(store: store)
        let service = CalendarService(store: EventKitStore())
        return (testCal, service, store)
    }

    private static func tearDown(_ calendar: EKCalendar, store: EKEventStore) {
        try? CalendarTestFixture.delete(calendar, store: store)
    }

    // MARK: - tests

    @Test("create → list → search → update → move cycle stays inside the test calendar",
          .disabled(if: ProcessInfo.processInfo.environment["CALENDAR_INTEGRATION"] != "1",
                    "set CALENDAR_INTEGRATION=1"))
    func fullCycle() async throws {
        let (testCal, service, store) = try await Self.setUp()
        defer { Self.tearDown(testCal, store: store) }

        let now = Date()
        let start = try #require(Calendar.current.date(byAdding: .hour, value: 1, to: now))
        let end = try #require(Calendar.current.date(byAdding: .hour, value: 2, to: now))
        let uniqueTitle = "ITest-\(UUID().uuidString.prefix(8))"

        // Create in the fixture calendar
        let id = try await service.createEvent(
            title: uniqueTitle,
            startDate: start,
            endDate: end,
            calendarName: testCal.title,
            location: "Test location",
            notes: "Test notes",
            isAllDay: false
        )
        #expect(!id.isEmpty)

        // List the fixture calendar only — should see exactly the event we made
        let listed = try await service.listEvents(
            from: now, to: #require(Calendar.current.date(byAdding: .day, value: 1, to: now)),
            calendarName: testCal.title, limit: 10
        )
        #expect(listed.totalMatched == 1, "fixture calendar should contain only our event")
        #expect(listed.events.first?.title == uniqueTitle)
        #expect(listed.events.first?.location == "Test location")

        // Search scoped to the fixture
        let hits = try await service.searchEvents(
            query: uniqueTitle,
            from: now, to: #require(Calendar.current.date(byAdding: .day, value: 1, to: now)),
            calendarName: testCal.title
        )
        #expect(hits.totalMatched == 1)

        // Update title + notes in place
        let newTitle = uniqueTitle + "-updated"
        try await service.updateEvent(
            id: id,
            title: newTitle,
            calendarName: testCal.title,
            notes: "Updated notes"
        )
        let afterUpdate = try await service.listEvents(
            from: now, to: #require(Calendar.current.date(byAdding: .day, value: 1, to: now)),
            calendarName: testCal.title
        )
        #expect(afterUpdate.events.first?.title == newTitle)
        #expect(afterUpdate.events.first?.notes == "Updated notes")
    }

    @Test("move between two fixture calendars: event moves, id may change",
          .disabled(if: ProcessInfo.processInfo.environment["CALENDAR_INTEGRATION"] != "1",
                    "set CALENDAR_INTEGRATION=1"))
    func moveBetweenFixtures() async throws {
        let (sourceCal, service, store) = try await Self.setUp()
        // A second fixture as the destination. Clean up both on exit.
        let destCal = try CalendarTestFixture.create(store: store)
        defer {
            Self.tearDown(sourceCal, store: store)
            Self.tearDown(destCal, store: store)
        }

        let now = Date()
        let start = try #require(Calendar.current.date(byAdding: .hour, value: 1, to: now))
        let end = try #require(Calendar.current.date(byAdding: .hour, value: 2, to: now))
        let title = "MoveProbe-\(UUID().uuidString.prefix(8))"

        let id = try await service.createEvent(
            title: title, startDate: start, endDate: end,
            calendarName: sourceCal.title
        )

        // Native reassignment via EventKit — the thing AppleScript can't do.
        try await service.updateEvent(id: id, calendarName: destCal.title)

        // Verify it landed in dest and left source
        let range = try now ... #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let inDest = try await service.listEvents(
            from: range.lowerBound, to: range.upperBound,
            calendarName: destCal.title
        )
        let stillInSource = try await service.listEvents(
            from: range.lowerBound, to: range.upperBound,
            calendarName: sourceCal.title
        )
        #expect(inDest.events.contains(where: { $0.title == title }),
                "event should be in destination fixture after move")
        #expect(!stillInSource.events.contains(where: { $0.title == title }),
                "event should be gone from source fixture after move")
    }

    @Test("cleanUpOrphans removes any lingering test calendars before new ones are created",
          .disabled(if: ProcessInfo.processInfo.environment["CALENDAR_INTEGRATION"] != "1",
                    "set CALENDAR_INTEGRATION=1"))
    func orphanCleanup() async throws {
        let (firstCal, _, store) = try await Self.setUp()
        // Intentionally don't delete — simulate a crashed previous run
        _ = firstCal

        // Second setUp should kill the first (plus any other orphans) and
        // leave us with just one fresh fixture calendar.
        let (secondCal, _, _) = try await Self.setUp()
        defer { Self.tearDown(secondCal, store: store) }

        let testCals = store.calendars(for: .event).filter {
            $0.title.hasPrefix(CalendarTestFixture.namePrefix)
        }
        #expect(testCals.count == 1, "expected exactly one fixture calendar after orphan cleanup, got \(testCals.count)")
    }
}
