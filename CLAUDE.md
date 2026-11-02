# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Swift Package Manager project (tools 6.4), macOS 27.2+, Swift 6 language mode with strict concurrency, plus the upcoming features and strict memory safety listed in `Package.swift` (`swiftSettings`). No package dependencies.

```bash
swift build               # build the library
swift build -c release    # optimised build (CalendarTestFixture compiled out)
swift test                # all unit tests (integration tests skip by default)

# Run a single test / suite (Swift Testing, not XCTest)
swift test --filter CalendarServiceTests
swift test --filter "OccurrenceID wire format"

# Formatting (config: .swiftformat)
swiftformat Sources Tests          # apply formatting
swiftformat Sources Tests --lint   # check only, non-zero exit on diffs
```

Integration tests (`CalendarServiceIntegrationTests`) run against the real EventKit store and are opt-in with `CALENDAR_INTEGRATION=1`. They need Calendar full access for the test binary, and they only create and delete their own `AppleSwiftMCPTest-<8hex>` calendars — never touch any other calendar.

## Architecture

EventKit wrapper consumed by apple-swift-mcp's calendar tools. Everything a consumer uses is `public`; the helpers copied from apple-swift-mcp (`BlockingWorkQueue`, `withTimeout`, `String.nonEmpty`, `zeroPadded`) are deliberately `internal` — implementation details, not API.

**Layering (Sources/CalendarAutomation/):**

- `CalendarService` — the public entry point. Defaults (calendar-name resolution via `defaultCalendar`), date-range guards, search filtering, sorting and paging (`CalendarEventPage`), free time.
- `EventStoreProtocol` + `EventKitStore` — the store seam. `EventKitStore` is an actor over `EKEventStore`; every synchronous EventKit call runs on a `BlockingWorkQueue` (off the cooperative pool, serial, 30s bound → `EventStoreError.timedOut`). Tests inject `FakeEventStore`.
- `OccurrenceID` / `EventReference` / `OccurrenceResolver` (`EventOccurrence.swift`, `OccurrenceID.swift`) — ids for occurrences of recurring series and resolving them back to one `EKEvent`.
- `FreeTimeFinder` — pure free-time arithmetic (busy rules, merging, working hours per wall-clock day).
- `CalendarTestFixture` — `#if DEBUG` only; creates/deletes `AppleSwiftMCPTest-*` calendars.

**Key invariants to preserve when editing:**

- **This library is the one owner of the occurrence id format.** `<eventIdentifier>#occ=<ISO-8601 UTC, whole seconds, Z>` is written and read only by `OccurrenceID`; its timestamp helper is file-private. Ids are held by clients across calls, so the format is frozen: `OccurrenceIDTests` pins literal ids (including identifiers containing `#` / `#occ=`) and the lenient spellings the original parser accepted. Don't add a general ISO-8601 argument parser here — argument parsing belongs to callers.
- **Never resolve an id with `event(withIdentifier:)` alone.** For a series it returns the first occurrence; `OccurrenceResolver` matches the named occurrence (±1s, within ±31 days, same series) or throws. A bare id on a recurring event is refused (`recurringEventNeedsOccurrence`), never guessed.
- **Pages are sorted before they are sliced**, and `limit <= 0` means unbounded — never an empty page with matches behind it.
- **Cross-account moves are refused up front** (`crossAccountMove`); `checkMove` and the save share `moveDestination`.
- **Isolation.** `NonisolatedNonsendingByDefault` is on; `withTimeout`'s work and timer are `@concurrent` so a blocked caller's actor can't stall the timeout.

**Testing conventions:** Swift Testing (`@Suite`, `@Test`, `#expect`), TDD. Fixture dates go through `fixtureDate(_:timeZone:)` in `TestDates.swift`.

<!-- pr-workflow:v3 -->
## Pull requests & release notes

Fleet policy — Conventional-Commit PR titles, labels, the auto-review /
auto-merge ladder, auto-review follow-up issues, PR timing, and release PRs —
lives in `~/.claude/CLAUDE.md`. Don't restate it here; the copies drifted.

Shared technical conventions (publishing, bundling, versioning guards,
write-verification, transport archetypes, testing traps) live in
[`chrischall/workflows`](https://github.com/chrischall/workflows):
`docs/fleet-conventions.md`, plus `README.md` for the CI pipeline contract.
