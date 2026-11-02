import Foundation

/// Fixture dates for tests. Deliberately small: the library has no general
/// ISO-8601 argument parser (that belongs to its callers), so tests spell
/// their fixtures in the few shapes this understands.
///
///   2026-04-20                    midnight in `timeZone`
///   2026-04-20T09:00[:00[.000]]   wall clock in `timeZone`
///   …Z                            UTC
func fixtureDate(_ s: String, timeZone: TimeZone = .current) -> Date {
    let pattern = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?(Z)?$/
    guard let m = s.wholeMatch(of: pattern) else { fatalError("test fixture: unparseable date \(s)") }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = m.8 == nil ? timeZone : TimeZone(identifier: "UTC")!
    let comps = DateComponents(
        year: Int(m.1), month: Int(m.2), day: Int(m.3),
        hour: m.4.flatMap { Int($0) } ?? 0, minute: m.5.flatMap { Int($0) } ?? 0,
        second: m.6.flatMap { Int($0) } ?? 0
    )
    guard let base = cal.date(from: comps) else { fatalError("test fixture: invalid date \(s)") }
    guard let frac = m.7 else { return base }
    return base.addingTimeInterval(TimeInterval("0." + frac) ?? 0)
}
