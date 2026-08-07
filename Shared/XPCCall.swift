import Foundation
import os

/// One implementation of "send an XPC message, await its reply, and never hang
/// waiting for one that isn't coming".
///
/// The app and the agent each run their own `DaemonConnection` against a
/// different Mach service with a different method set, so the *clients* are
/// legitimately separate — but this inner mechanic never differed between
/// them, and keeping two hand-maintained copies has now cost this project
/// twice on the same hazard. First the continuation leak: a connection
/// breaking mid-call left the continuation unresumed, fixed in the app and
/// only later, separately, in the agent. Then the timeout below: a daemon that
/// is *registered but never successfully spawns* has launchd holding its Mach
/// port, so the connection is accepted and the message queues, and neither the
/// reply block nor the error handler ever runs. That was fixed in the app —
/// found by running the real signed build against exactly that state — and
/// again reached the agent late, where `EvidenceLoopRunner.tick()` calls
/// `listSessions` every 5s for an entire login session and would strand one
/// suspended `Task` per tick.
///
/// Both fixes now live here once. The next one lands on both clients or
/// neither.
func xpcCall<T>(
    on connection: NSXPCConnection,
    timeout: Duration,
    logger: Logger,
    _ send: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
) async -> T? {
    await withCheckedContinuation { continuation in
        // Resume-exactly-once, so the three paths below can race safely:
        // whichever arrives first wins and the losers are no-ops.
        let latch = ContinuationLatch<T?>(continuation)

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            logger.error("XPC call timed out; treating the daemon as unreachable")
            latch.resume(nil)
        }

        // Built per call, not once per connection: the error handler has to
        // close over *this* call's latch to be able to resume it.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            logger.error("XPC error: \(error.localizedDescription)")
            timeoutTask.cancel()
            latch.resume(nil)
        } as? HelperProtocol

        guard let proxy else {
            timeoutTask.cancel()
            return latch.resume(nil)
        }
        send(proxy) { value in
            timeoutTask.cancel()
            latch.resume(value)
        }
    }
}
