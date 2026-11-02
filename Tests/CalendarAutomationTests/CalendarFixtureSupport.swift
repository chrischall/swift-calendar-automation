@testable import CalendarAutomation
import EventKit
import Foundation
import Testing

/// Integration tests are opt-in: `CALENDAR_INTEGRATION=1 swift test`.
let integrationDisabled = ProcessInfo.processInfo.environment["CALENDAR_INTEGRATION"] != "1"

struct EventKitAccessDenied: Swift.Error {}

/// An `EKEventStore` with full access, or a recorded issue and a throw.
func authorizedEventStore() async throws -> EKEventStore {
    let store = EKEventStore()
    let granted: Bool
    do {
        granted = try await store.requestFullAccessToEvents()
    } catch {
        Issue.record("EventKit auth request failed: \(error.localizedDescription)")
        throw error
    }
    guard granted else {
        Issue.record("EventKit full access was not granted")
        throw EventKitAccessDenied()
    }
    return store
}

/// Run `body` against a fresh `AppleSwiftMCPTest-*` calendar and a service
/// over the real store, and delete the calendar afterwards in **every**
/// path — the body returning, throwing, or failing an expectation.
///
/// The delete goes through a fresh `EKEventStore` that looks the calendar up
/// again (``CalendarTestFixture/delete(identifier:title:store:)``), and a
/// failure is recorded as an issue rather than swallowed: a leaked fixture
/// calendar shows up in the user's real calendar list.
///
/// - Parameter cleanOrphans: first remove calendars left by a crashed run
///   (failures recorded). Pass false for a second fixture nested inside
///   another, which the sweep would otherwise delete.
func withFixtureCalendar<T>(
    cleanOrphans: Bool = true,
    _ body: (EKCalendar, CalendarService) async throws -> T
) async throws -> T {
    let store = try await authorizedEventStore()
    if cleanOrphans {
        for (title, reason) in CalendarTestFixture.cleanUpOrphans(store: store).failed {
            Issue.record("orphan fixture calendar \(title) could not be removed: \(reason)")
        }
    }
    let calendar = try CalendarTestFixture.create(store: store)
    let identifier = calendar.calendarIdentifier, title = calendar.title
    func tearDown() {
        do {
            try CalendarTestFixture.delete(identifier: identifier, title: title, store: EKEventStore())
        } catch {
            Issue.record("fixture calendar was not deleted: \(error)")
        }
    }
    do {
        let result = try await body(calendar, CalendarService(store: EventKitStore()))
        tearDown()
        return result
    } catch {
        tearDown()
        throw error
    }
}

/// True when a calendar titled `title` exists, read through a fresh store.
func fixtureCalendarExists(_ title: String) -> Bool {
    let store = EKEventStore()
    store.refreshSourcesIfNecessary()
    return store.calendars(for: .event).contains { $0.title == title }
}
