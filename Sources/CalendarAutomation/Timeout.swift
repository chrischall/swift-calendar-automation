import Foundation
import Synchronization

/// Thrown when `withTimeout` gives up on an operation.
struct TimedOutError: Error, Equatable, Sendable {
    let operation: String
    let seconds: Double
}

/// Without this, `localizedDescription` on a `TimedOutError` is Foundation's
/// generic "The operation couldn't be completed. (… error 1.)" — the same
/// empty string that made `NSCocoaErrorDomain 134092` so hard to diagnose in
/// the first place. Any caller that renders a caught error by its description
/// (the Contacts.app replay does) would report a timeout as nothing at all.
extension TimedOutError: LocalizedError {
    var errorDescription: String? {
        "\(operation) timed out after \(Int(seconds))s"
    }
}

/// First-resume-wins handoff between the work, the timer, and cancellation.
///
/// Holds whichever arrives first — a result before the caller has attached
/// its continuation, or a continuation waiting for a result — and lets
/// exactly one resume through. Everything after the first is dropped, which
/// is what makes it safe for three racing producers to call `resume`.
final class TimeoutBox<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var pending: Result<T, any Error>?
        var finished = false
    }

    private let state = Mutex(State())

    /// Attach the caller's continuation, resuming immediately if the work
    /// already finished in the window before this ran.
    func attach(_ c: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = state.withLock { state in
            if let pending = state.pending {
                state.finished = true
                return pending
            }
            state.continuation = c
            return nil
        }
        if let ready {
            c.resume(with: ready)
        }
    }

    /// Deliver a result. Only the first call has any effect.
    func resume(_ result: Result<T, any Error>) {
        let waiting: CheckedContinuation<T, any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            guard let c = state.continuation else {
                // Caller hasn't attached yet — hold the first result for
                // `attach`. Producers can race here too (the timer firing as
                // the work returns), so a later one must not overwrite it.
                if state.pending == nil {
                    state.pending = result
                }
                return nil
            }
            state.finished = true
            state.continuation = nil
            return c
        }
        waiting?.resume(with: result)
    }
}

/// Run `body`, throwing `TimedOutError` if it hasn't finished within
/// `seconds`.
///
/// Deliberately **not** built on `withThrowingTaskGroup`. A group awaits
/// every child before it unwinds, so when the timeout branch throws, the
/// group still waits for the work — and a body that can't observe
/// cancellation is waited out in full, making the timeout decorative for
/// precisely the case it exists to handle. (Measured: a 0.1s timeout over
/// a 2.0s blocking body returned after 2.0s.) Racing through a
/// first-resume-wins box returns the moment either side settles.
///
/// The consequence is that this is unstructured: on timeout the work keeps
/// running, detached, until whatever it is blocked in returns. Cancellation
/// is requested but is cooperative, so a synchronous C/ObjC framework call
/// will ignore it. That is the intended trade — it frees the *caller* (and,
/// for a server, the request handler and the transport behind it) rather
/// than pretending the work itself can be aborted. Anything that blocks
/// should therefore run on a thread it's allowed to occupy, not on the
/// concurrency cooperative pool.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ body: @escaping @Sendable @concurrent () async throws -> T
) async throws -> T {
    let box = TimeoutBox<T>()

    let work = Task { @concurrent in
        do { try await box.resume(.success(body())) }
        catch { box.resume(.failure(error)) }
    }

    let timer = DispatchWorkItem {
        box.resume(.failure(TimedOutError(operation: operation, seconds: seconds)))
        work.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    defer { timer.cancel() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { box.attach($0) }
    } onCancel: {
        work.cancel()
        box.resume(.failure(CancellationError()))
    }
}
