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
- `Recurrence` (`Recurrence*.swift`) — pure repeat-rule model, no EventKit: `Recurrence.Input` (tool JSON) → `resolve()`, `parse(rrule:timeZone:)` / `rruleString(timeZone:)`, `validate(start:timeZone:isAllDay:)`, `normalized`. Parsing/decoding are syntax-only (every part is read or refused by name, never dropped); ranges and frequency combinations live in `validate`, so any stored rule can be represented. `until` is local wall clock in the event's zone; `RecurrenceDates` is its internal date helper — not a general parser. `summary(start:timeZone:isAllDay:)` is deterministic English (fixed month/day names, never the user's locale); `occurrences(start:timeZone:isAllDay:limit:)` expands the series itself (`RecurrenceOccurrences.swift`, integer civil-day arithmetic, wall clock kept across DST, start is always occurrence #1, counting capped at `maxCountedOccurrences`). Foundation's `Calendar.RecurrenceRule` is only a test oracle: on macOS 27.2 it mis-expands `BYSETPOS`, plain monthly `BYDAY` and `BYWEEKNO`.
- `RecurrenceEventKit.swift` — `Recurrence` ⇄ `EKRecurrenceRule`. A date-only `until` is written as 23:59:59 local in the event's zone and read back as date-only; WKST Monday is EventKit's default and reads back as unset (other days are written through KVC). `EventKitStore` sets an explicit zone on a new series (all-day stays floating) and validates rules before saving; `updateEvent(…, recurrence: RecurrenceChange)` needs span `.futureEvents` for a change on an occurrence. `CalendarEvent.recurrence`/`timeZone`/`seriesStartDate` carry the rule back; `rrule`/`recurrenceSummary` render it.
- `FreeTimeFinder` — pure free-time arithmetic (busy rules, merging, working hours per wall-clock day).
- `CalendarTestFixture` — `#if DEBUG` only; creates/deletes `AppleSwiftMCPTest-*` calendars. `delete` re-fetches the calendar in the store it's given (a handle from another `EKEventStore` can't be removed — that leaked one calendar per run); `cleanUpOrphans` returns a `CleanupReport` and has `dryRun`. Integration tests use `withFixtureCalendar` (test target), which deletes in every path and records a failed delete as an issue.

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
