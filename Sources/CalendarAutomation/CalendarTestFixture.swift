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
        case removeFailed(title: String, reason: String)

        public var description: String {
            switch self {
            case .noWritableSource:
                "No writable EKSource available for creating a test calendar. " +
                    "This usually means the device has neither a local nor an iCloud " +
                    "calendar account configured."
            case let .saveFailed(m):
                "Failed to save test calendar: \(m)"
            case let .removeFailed(title, reason):
                "Failed to remove test calendar \(title): \(reason)"
            }
        }
    }

    /// Create a new calendar with a unique name. Caller is responsible for
    /// cleanup via `delete(_:store:)` in every path (including a throwing
    /// one); `cleanUpOrphans(store:)` at the next session start is the
    /// backstop for a crash, not the plan.
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

    /// Delete a fixture calendar. All its events go with it.
    ///
    /// The calendar is looked up again in `store` — by identifier, then by
    /// its (unique) title — and that copy is removed, never the handle
    /// passed in. A handle from another `EKEventStore` (every test used to
    /// create its second fixture through a second store, then delete it
    /// through the first) can't be removed, and an iCloud calendar's
    /// identifier can change once the server has it; both used to fail
    /// silently and leave the calendar behind. A calendar that is already
    /// gone is not an error.
    ///
    /// - Throws: `Error.removeFailed` when the calendar exists but can't be
    ///   removed.
    public static func delete(_ calendar: EKCalendar, store: EKEventStore) throws {
        try delete(identifier: calendar.calendarIdentifier, title: calendar.title, store: store)
    }

    /// ``delete(_:store:)`` by identifier and title. Prefer this when the
    /// store that created the calendar may be gone: an `EKCalendar` whose
    /// store has been released reads back an empty title and identifier.
    ///
    /// - Throws: `Error.removeFailed` when the calendar exists but can't be
    ///   removed, or when both keys are empty (nothing to look up — the
    ///   handle's store was released before it was read).
    public static func delete(identifier: String, title: String, store: EKEventStore) throws {
        guard !identifier.isEmpty || !title.isEmpty else {
            throw Error.removeFailed(
                title: "(unknown)", reason: "the calendar handle is empty; its EKEventStore was released before delete"
            )
        }
        store.refreshSourcesIfNecessary()
        let current = (identifier.isEmpty ? nil : store.calendar(withIdentifier: identifier))
            ?? (title.isEmpty ? nil : store.calendars(for: .event).first { $0.title == title })
        guard let current else { return }
        do {
            try store.removeCalendar(current, commit: true)
        } catch {
            throw Error.removeFailed(title: title, reason: error.localizedDescription)
        }
    }

    /// What ``cleanUpOrphans(store:dryRun:)`` did, or would do.
    public struct CleanupReport: Sendable {
        /// Titles removed (with `dryRun`, the ones that would be).
        public var removed: [String] = []
        /// Titles that couldn't be removed, with the reason.
        public var failed: [(title: String, reason: String)] = []

        public init(removed: [String] = [], failed: [(title: String, reason: String)] = []) {
            self.removed = removed
            self.failed = failed
        }
    }

    /// Delete every calendar whose title starts with `namePrefix`, to flush
    /// calendars left over from a crashed earlier run. Keeps going past a
    /// failure, and reports every failure instead of swallowing it.
    ///
    /// - Parameter dryRun: list what would be removed, remove nothing.
    @discardableResult
    public static func cleanUpOrphans(store: EKEventStore, dryRun: Bool = false) -> CleanupReport {
        store.refreshSourcesIfNecessary()
        var report = CleanupReport()
        for cal in store.calendars(for: .event) where cal.title.hasPrefix(namePrefix) {
            if dryRun {
                report.removed.append(cal.title)
                continue
            }
            do {
                try store.removeCalendar(cal, commit: true)
                report.removed.append(cal.title)
            } catch {
                report.failed.append((cal.title, error.localizedDescription))
            }
        }
        return report
    }
}
#endif
