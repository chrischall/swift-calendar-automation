import Foundation

/// A dedicated serial thread for synchronous framework calls, with every
/// call bounded by a timeout.
///
/// EventKit and Contacts calls are synchronous XPC to a daemon, and a save
/// on a CalDAV/CardDAV account can push to the server before returning.
/// Run inline on the Swift concurrency cooperative pool — which is sized to
/// the core count and assumes tasks yield — a few slow calls occupy the
/// threads the MCP stdio transport's reader and writer also need, and the
/// server stops answering every tool. Hopping onto this queue keeps that
/// work on a thread it is allowed to occupy; `withTimeout` frees the caller
/// if the call never returns. Serial, because neither `EKEventStore` nor
/// `CNContactStore` mutation is safe to overlap.
///
/// On timeout the body keeps running (a blocked framework call cannot be
/// aborted) and later calls queue behind it — each of which then times out
/// too, rather than hanging.
final class BlockingWorkQueue: Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()
    let timeout: Double

    init(label: String, timeout: Double) {
        queue = DispatchQueue(label: label)
        self.timeout = timeout
        queue.setSpecific(key: key, value: true)
    }

    /// True when called from a body running on this queue.
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) ?? false }

    /// Run `body` on the queue, throwing `TimedOutError(operation:…)` if it
    /// hasn't finished within `timeout`.
    func run<T: Sendable>(
        _ operation: String,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let queue = queue
        return try await withTimeout(seconds: timeout, operation: operation) {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { try continuation.resume(returning: body()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}

/// Carries a non-`Sendable` framework object (an `EKEventStore`, a fetched
/// `CNContact`) across a hop onto a `BlockingWorkQueue`. Only for types that
/// are documented thread-safe or immutable; the queue being serial means
/// access never overlaps anyway.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
