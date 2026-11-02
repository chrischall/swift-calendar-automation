@testable import CalendarAutomation
import Foundation
import Synchronization
import Testing

/// `BlockingWorkQueue` is the one place synchronous framework calls
/// (EventKit, Contacts) run: off the cooperative pool, serially, and bounded.
@Suite("BlockingWorkQueue")
struct BlockingWorkQueueTests {
    @Test("returns the body's value")
    func returnsValue() async throws {
        let q = BlockingWorkQueue(label: "test.value", timeout: 5)
        #expect(try await q.run("value") { 42 } == 42)
    }

    @Test("propagates the body's own error")
    func propagatesError() async {
        struct Boom: Error, Equatable {}
        let q = BlockingWorkQueue(label: "test.error", timeout: 5)
        await #expect(throws: Boom()) { try await q.run("boom") { throw Boom() } }
    }

    @Test("runs the body on its own dispatch queue, not the cooperative pool")
    func runsOnOwnQueue() async throws {
        let q = BlockingWorkQueue(label: "test.hop", timeout: 5)
        let onQueue = try await q.run("hop") { q.isCurrent }
        #expect(onQueue)
        #expect(!q.isCurrent)
    }

    @Test("a blocking body times out promptly with the operation named")
    func blockingBodyTimesOut() async {
        let q = BlockingWorkQueue(label: "test.timeout", timeout: 0.1)
        let started = Date()
        await #expect(throws: TimedOutError(operation: "save reminder", seconds: 0.1)) {
            try await q.run("save reminder") { Thread.sleep(forTimeInterval: 2); return 1 }
        }
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test("bodies never overlap")
    func serial() async throws {
        let q = BlockingWorkQueue(label: "test.serial", timeout: 5)
        struct Counts {
            var active = 0
            var peak = 0
        }
        final class Counter: Sendable {
            let counts = Mutex(Counts())
            var peak: Int { counts.withLock { $0.peak } }
        }
        let c = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    try await q.run("overlap") {
                        c.counts.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
                        Thread.sleep(forTimeInterval: 0.02)
                        c.counts.withLock { $0.active -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(c.peak == 1)
    }
}

@Suite("BlockingWorkQueue called from the main actor")
@MainActor
struct BlockingWorkQueueCallerActorTests {
    @Test("the body never runs on the caller's actor")
    func bodyLeavesCallerActor() async throws {
        let queue = BlockingWorkQueue(label: "test.caller-actor", timeout: 5)
        let onMainThread = try await queue.run("where") { pthread_main_np() != 0 }
        #expect(!onMainThread)
    }
}
