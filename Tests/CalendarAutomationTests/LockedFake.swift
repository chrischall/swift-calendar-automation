import Synchronization

/// A test double's mutable state behind a `Mutex`, so the double can be a
/// plain `Sendable` class instead of `@unchecked Sendable`.
///
/// A class that stores only `let`s of `Sendable` types is `Sendable` by
/// construction, and `Mutex` is `Sendable` whatever it guards. `Mutex` is
/// noncopyable, so it can't be a protocol requirement — this class is the
/// copyable handle `LockedFake` needs.
final class Locked<State>: Sendable {
    private let mutex: Mutex<State>

    init(_ initial: sending State) { mutex = Mutex(initial) }

    /// Runs `body` with exclusive access to the state. `Mutex` is not
    /// recursive: never call back into the same fake (or a callback that
    /// might) from inside `body`.
    func withLock<Result, E: Error>(
        _ body: (inout sending State) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        try mutex.withLock(body)
    }
}

/// A test double whose `var`s live in one `State` struct behind a `Locked`.
///
/// `@dynamicMemberLookup` forwards `fake.someField` to `state`, so tests keep
/// seeding and inspecting fakes the way they always have
/// (`store.calendars = ["Work"]`, `#expect(store.deletes.isEmpty)`). Each such
/// access takes the lock once; the fake's own methods use `state.withLock`
/// so a read-modify-write is atomic.
@dynamicMemberLookup
protocol LockedFake: AnyObject, Sendable {
    associatedtype State
    var state: Locked<State> { get }
}

extension LockedFake {
    subscript<Value: Sendable>(dynamicMember keyPath: any WritableKeyPath<State, Value> & Sendable) -> Value {
        get { state.withLock { $0[keyPath: keyPath] } }
        set { state.withLock { $0[keyPath: keyPath] = newValue } }
    }
}
