#if DEBUG
public import EventKit
import Foundation

/// Debug builds only — it backs integration tests and debug-only probes (such
/// as apple-swift-mcp's `--benchmark` move probe), and `cleanUpOrphans`
/// deletes calendars by name prefix, so it must never ship in a release
/// binary (chrischall/fleet-audit#833).
///
/// Creates and tears down a dedicated EventKit calendar for tests and
/// probes. Using a fresh calendar per run means we never
/// read, write, or delete anything in the user's existing calendars.
///
/// All fixture calendars share the name prefix `AppleSwiftMCPTest-`. A
/// UUID suffix scopes each run. `cleanUpOrphans` deletes any fixture
/// calendar from a crashed prior run — matched by name prefix alone, so
/// it's safe to call at the start of any test or benchmark session.
///
/// Source selection: we prefer the `local` (on-device) source so writes
/// don't get synced to iCloud or any CalDAV account. On setups with no
/// local source, we fall back to iCloud. The fallback path is noted in
/// the thrown error so the caller can surface it meaningfully.
///
/// Requires calendar write permission (which our binary has via the
/// embedded `NSCalendarsFullAccessUsageDescription`).
public enum CalendarTestFixture {
    public static let namePrefix = "AppleSwiftMCPTest"

    public enum Error: Swift.Error, CustomStringConvertible {
        case noWritableSource
        case saveFailed(String)

        public var description: String {
            switch self {
            case .noWritableSource:
                "No writable EKSource available for creating a test calendar. " +
                    "This usually means the device has neither a local nor an iCloud " +
                    "calendar account configured."
            case let .saveFailed(m):
                "Failed to save test calendar: \(m)"
            }
        }
    }

    /// Create a new calendar with a unique name. Caller is responsible for
    /// cleanup via `delete(_:store:)` or, better, via
    /// `cleanUpOrphans(store:)` at the next session start.
    ///
    /// - Parameter store: An `EKEventStore` that has already been
    ///   authorized for `.event` full access.
    /// - Returns: The newly-saved calendar, with its `title` populated.
    public static func create(store: EKEventStore) throws -> EKCalendar {
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "\(namePrefix)-\(UUID().uuidString.prefix(8))"
        // Prefer local (non-syncing) source. Local sources only exist on
        // machines where the user has created a local calendar at some
        // point, so fall back in priority order: local → iCloud → any
        // calDAV → any source.
        let source = store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first(where: {
                $0.title.lowercased().contains("icloud")
            })
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first
        guard let source else {
            throw Error.noWritableSource
        }
        cal.source = source

        do {
            try store.saveCalendar(cal, commit: true)
        } catch {
            throw Error.saveFailed(error.localizedDescription)
        }
        return cal
    }

    /// Delete a specific fixture calendar. All its events go with it.
    public static func delete(_ calendar: EKCalendar, store: EKEventStore) throws {
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw Error.saveFailed("remove failed: \(error.localizedDescription)")
        }
    }

    /// Delete every calendar whose title starts with `namePrefix`. Useful
    /// at the start of a test run to flush calendars left over from a
    /// crashed previous run. Best-effort — swallows individual removal
    /// failures and proceeds.
    public static func cleanUpOrphans(store: EKEventStore) {
        for cal in store.calendars(for: .event) where cal.title.hasPrefix(namePrefix) {
            try? store.removeCalendar(cal, commit: true)
        }
    }
}
#endif
