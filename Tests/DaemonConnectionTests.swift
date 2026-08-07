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
