// Private copies of the small helpers apple-swift-mcp keeps in its own
// AppleMCPCore. Internal on purpose: they are implementation details here,
// not API, and a public `String.nonEmpty` would collide with a client's own.

extension String {
    /// Returns self if non-empty, else nil. Handy for precedence chains
    /// like `explicit ?? envDefault ?? throw`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension BinaryInteger {
    /// Decimal digits left-padded with zeros to `width`, sign first —
    /// `String(format: "%0*ld")` without C varargs, which strict memory
    /// safety counts as unsafe.
    func zeroPadded(_ width: Int) -> String {
        let digits = String(magnitude)
        let padding = String(repeating: "0", count: Swift.max(0, width - digits.count - (self < 0 ? 1 : 0)))
        return (self < 0 ? "-" : "") + padding + digits
    }
}
