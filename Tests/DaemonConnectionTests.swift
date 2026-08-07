import XCTest
@testable import KeepyUppy

/// Final whole-branch review, Item 2: a broken XPC connection must resume
/// the awaiting continuation, not hang forever.
///
/// `Sources/DaemonConnection.swift` used to send each message through a
/// proxy whose error handler only logged and flipped `isConnected` — it had
/// no reference to whichever `withCheckedContinuation` was pending, so when
/// the connection failed mid-call the awaiting `refresh()` never resumed.
/// The 3s poll timer then started a fresh, equally stuck `refresh()` `Task`
/// every tick, leaking one task per tick for the lifetime of the app.
///
/// This test exercises exactly that path: nothing registers the privileged
/// daemon in the test environment, so `resume()` succeeds (Mach service
/// lookup is lazy) and the *first real message* is what fails — the precise
/// shape of the bug. It asserts only that the call returns, deliberately
/// making no claim about `isConnected`, so it stays honest on a developer
/// machine that does happen to have the daemon registered: there, the calls
/// succeed and return promptly, which is equally fine. It fails only if a
/// continuation is left unresumed.
///
/// Verified to be a real regression test, not a tautology: with the
/// pre-fix `Sources/DaemonConnection.swift` restored in place, this test
/// times out.
@MainActor
final class DaemonConnectionFailurePathTests: XCTestCase {
    /// Well under the 10s expectation timeout below, but long enough that a
    /// slow machine's XPC round-trip is not mistaken for a hang.
    private let timeout: TimeInterval = 10

    private func expectCompletion(
        _ name: String,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let done = expectation(description: name)
        Task { @MainActor in
            await work()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }

    func testRefreshReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("refresh() returned") { await daemon.refresh() }
    }

    func testStartSessionReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("startSession() returned") {
            _ = await daemon.startSession(kind: .indefinite)
        }
    }

    func testStopSessionReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("stopSession() returned") { await daemon.stopSession(UUID()) }
    }

    func testStopAllSessionsReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("stopAllSessions() returned") {
            await daemon.stopAllSessions(all: false)
        }
    }
}

/// `ContinuationLatch` is the primitive the fix above is built on, and as of
/// fix wave D it is shared (`Shared/ContinuationLatch.swift`) by BOTH XPC
/// clients — the app's, exercised directly above, and the agent's
/// (`Agent/DaemonConnection.swift`), which had the identical unfixed
/// continuation leak until the same wave.
///
/// The agent's client deliberately has no XCTest here, and cannot have one:
/// it declares a type also named `DaemonConnection`, so it cannot join the
/// app target alongside `Sources/DaemonConnection.swift`, and compiled into
/// the test target instead it could not see the internal `Shared` symbols
/// (`HelperProtocol`, `agentMachServiceName`, `Session`) it is written
/// against. It is instead verified by compiling the real, unmodified file
/// into a standalone executable with the real `Shared` sources and driving it
/// against the (unregistered) daemon Mach service — pre-fix that run trips
/// "SWIFT TASK CONTINUATION MISUSE: listSessions() leaked its continuation
/// without resuming it" and hangs; post-fix all three calls return. See
/// `.superpowers/sdd/final-review-fixwave-D-report.md` for the transcript.
///
/// What is testable here, and now matters twice over, is the latch's own
/// contract: it exists because NSXPC's reply block and its error handler
/// arrive on arbitrary queues, and resuming a `CheckedContinuation` twice
/// traps at runtime — a crash would be a strictly worse outcome than the hang
/// the latch prevents.
final class ContinuationLatchTests: XCTestCase {
    func testASecondResumeIsDroppedRatherThanTrapping() async {
        let value: Int = await withCheckedContinuation { continuation in
            let latch = ContinuationLatch(continuation)
            latch.resume(1)
            // Without the latch this is `CheckedContinuation` misuse and
            // traps the process.
            latch.resume(2)
        }
        XCTAssertEqual(value, 1, "the first resume must win")
    }

    /// The real shape of the race: the reply block and the error handler are
    /// on different queues, so "check then resume" without a lock is not
    /// enough. Repeated so a lost race is not a one-in-a-thousand flake that
    /// only shows up in production.
    func testConcurrentResumesDeliverExactlyOneValue() async {
        for _ in 0..<250 {
            let value: Int = await withCheckedContinuation { continuation in
                let latch = ContinuationLatch(continuation)
                DispatchQueue.concurrentPerform(iterations: 8) { latch.resume($0) }
            }
            XCTAssertTrue((0..<8).contains(value), "unexpected value \(value)")
        }
    }
}
