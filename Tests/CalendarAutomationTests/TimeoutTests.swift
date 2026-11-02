@testable import CalendarAutomation
import Foundation
import Testing

@Suite("withTimeout")
struct TimeoutTests {
    @Test("returns the value when the work finishes in time")
    func completesInTime() async throws {
        let value = try await withTimeout(seconds: 5, operation: "fast") { 42 }
        #expect(value == 42)
    }

    @Test("throws TimedOutError naming the operation when the work overruns")
    func timesOut() async {
        await #expect(throws: TimedOutError(operation: "slow", seconds: 0.05)) {
            try await withTimeout(seconds: 0.05, operation: "slow") {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
    }

    @Test("propagates the work's own error rather than masking it")
    func propagatesError() async {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await withTimeout(seconds: 5, operation: "boom") { throw Boom() }
        }
    }

    @Test("a late result from timed-out work is dropped rather than double-resuming")
    func lateResultIsDropped() async throws {
        // The work resumes its continuation after the timeout has already
        // settled the call. First-resume-wins has to swallow it; a second
        // resume would trap.
        await #expect(throws: TimedOutError(operation: "late", seconds: 0.05)) {
            try await withTimeout(seconds: 0.05, operation: "late") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        c.resume(returning: 7)
                    }
                }
            }
        }
        try await Task.sleep(nanoseconds: 400_000_000) // let the late resume land
    }

    @Test("a timeout returns promptly instead of waiting out the work")
    func returnsPromptly() async {
        let started = Date()
        _ = try? await withTimeout(seconds: 0.05, operation: "slow") {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}

@Suite("withTimeout under blocking work")
struct TimeoutBlockingTests {
    /// The shape `EventKitStore.perform` actually passes: a checked
    /// continuation resumed from a queue running a genuinely blocking
    /// call. Cancellation can't reach it, so the timeout is the only
    /// thing that can free the caller.
    @Test("frees the caller even when the work can't observe cancellation")
    func timesOutOnUncancellableWork() async {
        let started = Date()
        await #expect(throws: TimedOutError(operation: "blocking", seconds: 0.1)) {
            try await withTimeout(seconds: 0.1, operation: "blocking") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 2.0) // genuinely blocking
                        c.resume(returning: 1)
                    }
                }
            }
        }
        // Built on a task group this returned after the full 2.0s: the group
        // awaited the uncancellable child before propagating the timeout.
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}

@Suite("TimeoutBox first-resume-wins")
struct TimeoutBoxTests {
    /// Two producers can settle before the caller attaches — the timer
    /// fires while the work is already returning. Only the first result
    /// may survive, or the timeout silently overwrites a real answer.
    @Test("holds the first pre-attach result and drops later ones")
    func firstPendingWins() async throws {
        let box = TimeoutBox<Int>()
        box.resume(.success(1))
        box.resume(.failure(TimedOutError(operation: "late", seconds: 0.1)))

        let value = try await withCheckedThrowingContinuation { box.attach($0) }
        #expect(value == 1)
    }

    @Test("still delivers a pre-attach failure that arrived first")
    func firstPendingFailureWins() async {
        let box = TimeoutBox<Int>()
        box.resume(.failure(TimedOutError(operation: "slow", seconds: 0.1)))
        box.resume(.success(99))

        await #expect(throws: TimedOutError(operation: "slow", seconds: 0.1)) {
            try await withCheckedThrowingContinuation { box.attach($0) }
        }
    }

    @Test("a resume after attach still wins only once")
    func postAttachFirstWins() async throws {
        let box = TimeoutBox<Int>()
        async let attached: Int = withCheckedThrowingContinuation { box.attach($0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        box.resume(.success(5))
        box.resume(.success(6))
        #expect(try await attached == 5)
    }
}

/// `withTimeout` is called from actors (`EventKitStore`, the contacts and
/// reminders stores) and could be called from the main actor. Its work and
/// its timer must not run on that caller's actor: a blocking body there
/// would hold the actor for the whole block, and the timeout could not
/// free the caller until it finished.
@Suite("withTimeout called from the main actor")
@MainActor
struct TimeoutCallerActorTests {
    @Test("runs the work off the caller's actor")
    func workLeavesCallerActor() async throws {
        let onMainThread = try await withTimeout(seconds: 5, operation: "where") {
            pthread_main_np() != 0
        }
        #expect(!onMainThread)
    }

    @Test("a blocking body cannot hold the caller past the deadline")
    func blockingBodyDoesNotPinCaller() async {
        let started = Date()
        await #expect(throws: TimedOutError(operation: "blocked", seconds: 0.1)) {
            try await withTimeout(seconds: 0.1, operation: "blocked") { usleep(1_500_000) }
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}
