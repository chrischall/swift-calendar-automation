@testable import CalendarAutomation
import Foundation
import Testing

@Suite("zeroPadded")
struct ZeroPaddedTests {
    @Test("matches printf's %0Nd", arguments: [
        (0, 2), (7, 2), (12, 2), (123, 2), (5, 4), (2026, 4), (0, 1), (59, 2),
    ])
    func matchesPrintf(value: Int, width: Int) {
        let expected = unsafe String(format: "%0\(width)ld", value)
        #expect(value.zeroPadded(width) == expected)
    }

    @Test("keeps the sign in front of the padding, as printf does")
    func negative() {
        #expect((-5).zeroPadded(3) == "-05")
    }
}

@Suite("nonEmpty")
struct NonEmptyTests {
    @Test("empty is nil, anything else is itself")
    func nonEmpty() {
        #expect("".nonEmpty == nil)
        #expect(" ".nonEmpty == " ")
        #expect("Work".nonEmpty == "Work")
    }
}
