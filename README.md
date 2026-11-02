# CalendarAutomation

[![CI](https://github.com/chrischall/swift-calendar-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/chrischall/swift-calendar-automation/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Swift library for reading and writing Apple Calendar events on macOS through
**EventKit**: list and search a bounded window, page through the results,
create / update / move / delete events (including a single occurrence of a
recurring series), and find free time inside working hours.

Platform: **macOS 27.2+**. Pure Swift 6 with strict concurrency. No
dependencies.

Extracted from [apple-swift-mcp](https://github.com/chrischall/apple-swift-mcp),
which uses it for its calendar tools.

## Install

```swift
// Package.swift — use the latest release from the Releases page
dependencies: [
    .package(url: "https://github.com/chrischall/swift-calendar-automation.git", from: "<latest release>"),
]
```

## Permissions

EventKit needs **full** calendar access. The binary that links this library
must embed an `Info.plist` with `NSCalendarsFullAccessUsageDescription`
(for a command-line tool, via `-sectcreate __TEXT __info_plist`); without it
macOS grants write-only access and every query comes back empty.
`EventKitStore` requests access lazily on first use.

## Quickstart

```swift
import CalendarAutomation

let calendar = CalendarService(store: EventKitStore(), defaultCalendar: "Home")

let names = try await calendar.listCalendarNames()

// Every query is bounded by a window, and the page says what it held back.
let now = Date()
let page = try await calendar.listEvents(from: now, to: now.addingTimeInterval(7 * 86_400), limit: 10)
print("\(page.events.count) of \(page.totalMatched); next offset: \(String(describing: page.nextOffset))")

let id = try await calendar.createEvent(
    title: "Dentist", startDate: start, endDate: end, calendarName: nil  // falls back to "Home"
)
try await calendar.updateEvent(id: id, title: "Dentist (moved)")
```

### Recurring events and occurrence ids

Every occurrence of a recurring series shares one EventKit identifier, so
`list`/`search` give each occurrence its own id:
`<eventIdentifier>#occ=<original start, ISO-8601 UTC>`, e.g.
`ABC:123#occ=2026-11-09T20:30:00Z`. `OccurrenceID` is the only thing that
writes or reads that format — build and split ids through it, never by hand:

```swift
let occ = OccurrenceID(parsing: "ABC:123#occ=2026-11-09T20:30:00Z")
occ?.eventIdentifier   // "ABC:123"
occ?.occurrenceDate    // 2026-11-09 20:30:00 +0000
occ?.string            // the id again, byte for byte
```

Passing an occurrence id to `updateEvent` / `deleteEvent` acts on that
occurrence (`span: .futureEvents` for it and every later one). A bare series
id on a recurring event is refused rather than guessed.

### Free time

```swift
let query = FreeTimeQuery(
    from: monday, to: friday, notBefore: Date(), timeZone: .current,
    workdayStart: ClockTime(hour: 9, minute: 0)!, workdayEnd: ClockTime(hour: 17, minute: 0)!,
    weekdaysOnly: true, minMinutes: 30, includeAllDay: false
)
let free = try await calendar.freeTime(query)
```

## Testing your own code

`EventStoreProtocol` is the seam: inject an in-memory store into
`CalendarService` instead of `EventKitStore`. In debug builds,
`CalendarTestFixture` creates and deletes throwaway `AppleSwiftMCPTest-*`
calendars for end-to-end tests; it is compiled out of release builds.

## License

MIT
