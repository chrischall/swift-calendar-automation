public import Foundation

public extension Recurrence {
    /// A deterministic English description of the series, for previews and
    /// read-backs — not localized (month and day names are fixed English, so
    /// output doesn't depend on the user's locale).
    ///
    /// Common rules get a fixed phrase: `Daily`, `Every 3 days`,
    /// `Weekly on Monday and Wednesday`, `Weekly on weekdays`,
    /// `Monthly on day 15`, `Monthly on the last day`,
    /// `Monthly on the 2nd Tuesday`, `Monthly on the last weekday`,
    /// `Yearly on March 15`, `Every 2 years in March on the 2nd Sunday`, …
    /// Anything else gets a generic phrase that names every part. The week
    /// start is mentioned when it changes which days the rule hits (weekly
    /// every N > 1 weeks on several days, or week numbers).
    ///
    /// The end is a suffix: `, until May 3, 2027 (26 occurrences)` (with
    /// `at 3:30 PM` for a date-time until; `1000+` past
    /// ``maxCountedOccurrences``), `, 10 times`, `, once`, or nothing for an
    /// open-ended series. Parts left implicit (a weekly rule's day, a
    /// monthly/yearly rule's date) are taken from `start` in `timeZone`.
    func summary(start: Date, timeZone: TimeZone, isAllDay: Bool) -> String {
        let rule = normalized(start: start, timeZone: timeZone)
        let s = RecurrenceDates.wallClock(start, in: timeZone)
        let builder = RecurrenceSummary(rule: rule, startMonth: s.month ?? 1, startDay: s.day ?? 1)
        var text = builder.fixedPhrase() ?? builder.genericPhrase()
        if builder.weekStartMatters, let weekStart = rule.weekStart {
            text += " (weeks start on \(RecurrenceSummary.dayName(weekStart)))"
        }
        switch end {
        case nil:
            break
        case let .count(n):
            text += n == 1 ? ", once" : ", \(n) times"
        case let .until(c):
            let preview = occurrences(start: start, timeZone: timeZone, isAllDay: isAllDay, limit: 0)
            let total = switch (preview.total, preview.totalIsCapped) {
            case (_, true): "\(Self.maxCountedOccurrences)+ occurrences"
            case (1, _): "1 occurrence"
            case let (n?, _): "\(n) occurrences"
            case (nil, false): "occurrences unknown"
            }
            text += ", until \(RecurrenceSummary.until(c)) (\(total))"
        }
        return text
    }
}

/// Phrase building for ``Recurrence/summary(start:timeZone:isAllDay:)``.
struct RecurrenceSummary {
    let rule: Recurrence
    let startMonth: Int
    let startDay: Int

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    static func monthName(_ m: Int) -> String { monthNames.indices.contains(m - 1) ? monthNames[m - 1] : "month \(m)" }

    static func dayName(_ w: Recurrence.Weekday) -> String {
        switch w {
        case .MO: "Monday"
        case .TU: "Tuesday"
        case .WE: "Wednesday"
        case .TH: "Thursday"
        case .FR: "Friday"
        case .SA: "Saturday"
        case .SU: "Sunday"
        }
    }

    /// `1st`, `2nd`, `23rd`, `last`, `2nd-to-last`.
    static func ordinal(_ n: Int) -> String {
        if n == -1 {
            return "last"
        }
        if n < 0 {
            return ordinal(-n) + "-to-last"
        }
        let suffix = switch (n % 10, n % 100) {
        case (_, 11 ... 13): "th"
        case (1, _): "st"
        case (2, _): "nd"
        case (3, _): "rd"
        default: "th"
        }
        return "\(n)\(suffix)"
    }

    /// `A`, `A and B`, `A, B and C`.
    static func list(_ items: [String], conjunction: String = "and") -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }

    /// `May 3, 2027` / `May 3, 2027 at 3:30 PM`.
    static func until(_ c: DateComponents) -> String {
        let date = "\(monthName(c.month ?? 0)) \(c.day ?? 0), \(c.year ?? 0)"
        guard RecurrenceDates.hasTime(c) else { return date }
        let h = c.hour ?? 0
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return date + " at \(hour12):\((c.minute ?? 0).zeroPadded(2)) \(h < 12 ? "AM" : "PM")"
    }

    /// Positives ascending, then negatives from the farthest to `last`.
    static func sortedPositions(_ values: [Int]) -> [Int] {
        values.filter { $0 > 0 }.sorted() + values.filter { $0 < 0 }.sorted()
    }

    static let weekdaySet: Set<Recurrence.Weekday> = [.MO, .TU, .WE, .TH, .FR]

    var base: String {
        let n = rule.interval
        switch rule.frequency {
        case .daily: return n == 1 ? "Daily" : "Every \(n) days"
        case .weekly: return n == 1 ? "Weekly" : "Every \(n) weeks"
        case .monthly: return n == 1 ? "Monthly" : "Every \(n) months"
        case .yearly: return n == 1 ? "Yearly" : "Every \(n) years"
        }
    }

    var weekStartMatters: Bool {
        rule.weeksOfYear != nil || (rule.frequency == .weekly && rule.interval > 1 && (rule.daysOfWeek?.count ?? 0) > 1)
    }

    // MARK: fixed phrases

    func fixedPhrase() -> String? {
        switch rule.frequency {
        case .daily: dailyPhrase()
        case .weekly: weeklyPhrase()
        case .monthly: monthlyPhrase()
        case .yearly: yearlyPhrase()
        }
    }

    var hasNoParts: Bool {
        rule.daysOfWeek == nil && rule.daysOfMonth == nil && rule.monthsOfYear == nil && rule.weeksOfYear == nil
            && rule.daysOfYear == nil && rule.setPositions == nil
    }

    func dailyPhrase() -> String? { hasNoParts ? base : nil }

    func weeklyPhrase() -> String? {
        guard let days = rule.daysOfWeek, !days.isEmpty, days.allSatisfy({ $0.ordinal == nil }),
              rule.daysOfMonth == nil, rule.monthsOfYear == nil, rule.weeksOfYear == nil, rule.daysOfYear == nil,
              rule.setPositions == nil
        else { return nil }
        let set = Set(days.map(\.weekday))
        guard set.count == days.count else { return nil }
        if set == Self.weekdaySet {
            return base + " on weekdays"
        }
        let ordered = Recurrence.Weekday.allCases.filter(set.contains).map(Self.dayName)
        return base + " on " + Self.list(ordered)
    }

    func monthlyPhrase() -> String? {
        guard rule.monthsOfYear == nil, rule.weeksOfYear == nil, rule.daysOfYear == nil else { return nil }
        switch (rule.daysOfMonth, rule.daysOfWeek) {
        case (nil, nil):
            return rule.setPositions == nil ? base + " on day \(startDay)" : nil
        case let (days?, nil):
            guard rule.setPositions == nil, !days.isEmpty else { return nil }
            return base + " on " + daysOfMonthPhrase(days)
        case (nil, .some):
            return dayPhrase().map { base + " on " + $0 }
        case (.some, .some):
            return nil
        }
    }

    func yearlyPhrase() -> String? {
        guard rule.weeksOfYear == nil, rule.daysOfMonth == nil else { return nil }
        if let daysOfYear = rule.daysOfYear {
            guard rule.daysOfWeek == nil, rule.monthsOfYear == nil, rule.setPositions == nil, !daysOfYear.isEmpty
            else { return nil }
            return base + " on " + daysOfYearPhrase(daysOfYear)
        }
        let months = rule.monthsOfYear
        if let months, months.isEmpty {
            return nil
        }
        let inMonths = months.map { " in " + Self.list($0.sorted().map(Self.monthName)) } ?? ""
        if rule.daysOfWeek == nil {
            guard rule.setPositions == nil else { return nil }
            if months == nil || months == [startMonth] {
                return base + " on \(Self.monthName(startMonth)) \(startDay)"
            }
            return base + inMonths + " on day \(startDay)"
        }
        // Without months a day counts within the whole year — the generic phrase says so plainly.
        guard months != nil, let day = dayPhrase() else { return nil }
        return base + inMonths + " on " + day
    }

    /// `the 2nd Tuesday`, `the 1st Monday and the 3rd Monday` (ordinal
    /// days), or `the last weekday`, `the 1st and last Monday or Friday`
    /// (plain days narrowed by set positions). Nil for other shapes.
    func dayPhrase() -> String? {
        guard let days = rule.daysOfWeek, !days.isEmpty else { return nil }
        if days.allSatisfy({ $0.ordinal != nil }), rule.setPositions == nil {
            return Self.list(days.map { "the \(Self.ordinal($0.ordinal ?? 0)) \(Self.dayName($0.weekday))" })
        }
        guard days.allSatisfy({ $0.ordinal == nil }), let positions = rule.setPositions, !positions.isEmpty else {
            return nil
        }
        let set = Set(days.map(\.weekday))
        guard set.count == days.count else { return nil }
        let noun = switch set {
        case Self.weekdaySet: "weekday"
        case [.SA, .SU]: "weekend day"
        case Set(Recurrence.Weekday.allCases): "day"
        default: Self.list(Recurrence.Weekday.allCases.filter(set.contains).map(Self.dayName), conjunction: "or")
        }
        return "the " + Self.list(Self.sortedPositions(positions).map(Self.ordinal)) + " " + noun
    }

    /// `day 15`, `days 1 and 15`, `the last day`, `day 1 and the 2nd-to-last day`.
    func daysOfMonthPhrase(_ days: [Int]) -> String {
        Self.list(numberedDays(days, suffix: ""))
    }

    /// `day 100 of the year`, `the last day of the year`.
    func daysOfYearPhrase(_ days: [Int]) -> String {
        Self.list(numberedDays(days, suffix: " of the year"))
    }

    func numberedDays(_ days: [Int], suffix: String) -> [String] {
        let positives = days.filter { $0 > 0 }.sorted()
        let negatives = days.filter { $0 < 0 }.sorted()
        var groups: [String] = []
        if !positives.isEmpty {
            groups.append((positives.count == 1 ? "day " : "days ") + Self.list(positives.map(String.init)) + suffix)
        }
        groups += negatives.map { "the \(Self.ordinal($0)) day" + suffix }
        return groups
    }

    // MARK: generic phrase

    /// `<base>[ on <days>]` then `; <part>: <values>` for every other part.
    func genericPhrase() -> String {
        func values(_ items: [String]) -> String { items.isEmpty ? "none" : Self.list(items) }
        var text = base
        if let months = rule.monthsOfYear {
            text += months.isEmpty ? "; months: none" : " in " + Self.list(months.map(Self.monthName))
        }
        if let days = rule.daysOfWeek {
            let names = days.map { day in
                day.ordinal.map { "the \(Self.ordinal($0)) \(Self.dayName(day.weekday))" } ?? Self.dayName(day.weekday)
            }
            text += names.isEmpty ? "; days of the week: none" : " on " + Self.list(names)
        }
        func part(_ label: String, _ list: [Int]?, _ show: (Int) -> String = String.init) {
            if let list {
                text += "; \(label): " + values(list.map(show))
            }
        }
        part("days of the month", rule.daysOfMonth)
        part("weeks of the year", rule.weeksOfYear)
        part("days of the year", rule.daysOfYear)
        part("positions", rule.setPositions, Self.ordinal)
        return text
    }
}
