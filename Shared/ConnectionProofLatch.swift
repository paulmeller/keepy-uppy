import Foundation

/// One accepted XPC connection's answer to "has this peer actually proven it
/// satisfies the listener's code-signing requirement yet?", so the daemon's
/// liveness refcounts can be bumped when that becomes true rather than when
/// the connection was merely *accepted*.
///
/// Why the distinction matters: `shouldAcceptNewConnection` sets the peer
/// requirement (`NSXPCConnection.setCodeSigningRequirement`) and returns
/// `true`, but XPC adjudicates that requirement *after* the delegate returns,
/// tearing the connection down later if it fails. Any local process can look
/// up a Mach service, so reaching accept proves nothing at all about who the
/// peer is. Incrementing there let an unsigned rogue hold
/// `DaemonRuntime.liveConnectionsByClient` (and, worse,
/// `liveAgentConnectionsByUser`, which gates whether agent-evaluated sessions
/// may start at all) above zero for the whole adjudication window, just by
/// spamming connect/disconnect — keeping the real app's `clientBound` sessions
/// alive after it quit, or faking agent liveness outright. The first message
/// delivered to the exported object *is* proof: XPC delivers none until the
/// requirement has passed.
///
/// Three states, not a pair of independent flags, because the two events race:
/// a message can be in flight while the connection tears down. The terminal
/// `released` state is what makes the pairing safe in that order too — a
/// connection torn down before it ever proved itself can never afterwards
/// increment a count that nothing is left to decrement.
///
/// Both methods take the refcount work as a closure and run it *while holding
/// the lock*, rather than returning a `Bool` for the caller to branch on
/// afterwards. Deciding under the lock but acting outside it is not enough:
/// see `proveOnce` below for the race that shape allowed.
///
/// Lives in `Shared/` rather than in `Helper/` for the same reason
/// `ContinuationLatch` does: `Helper/` is not in the test target, so a
/// one-shot primitive written there is a correctness-critical invariant with
/// no way to test it. `Shared/` is compiled into the app target the tests
/// import. Unlike `ContinuationLatch` — which two XPC clients genuinely share
/// via `Shared/XPCCall.swift` — this type has exactly one real caller,
/// `Helper/HelperListenerDelegate.swift`, and is compiled into all four
/// targets only as a side effect of living here for testability.
final class ConnectionProofLatch: @unchecked Sendable {
    private enum State {
        /// Accepted, but nothing has been delivered to the exported object,
        /// so the peer is still just "some process that found the service".
        case unproven
        /// A message arrived, so XPC has adjudicated the code-signing
        /// requirement in the peer's favour. Counted.
        case proven
        /// Torn down. Terminal from either predecessor: reaching it from
        /// `unproven` means the connection died without ever being counted,
        /// and must not be counted by a late message afterwards.
        case released
    }

    /// `NSLock` rather than an actor or a queue: XPC callbacks arrive on
    /// arbitrary threads with no actor context, and the bodies run under it
    /// are the caller's refcount mutations, which enter `DaemonRuntime`'s
    /// serial queue. That call-out is safe because the lock order is only
    /// ever latch → runtime queue: nothing running on that queue touches a
    /// latch, and each latch belongs to exactly one connection, so no second
    /// thread can be holding the runtime queue while waiting on *this* lock.
    private let lock = NSLock()
    private var state: State = .unproven

    /// Runs `body` — the caller's refcount increments — exactly once, on the
    /// first call for a connection that is still live, and never again. A
    /// connection that was already released deliberately does not count: an
    /// increment after teardown would never be balanced by a decrement, since
    /// teardown has already run and runs at most once.
    ///
    /// `body` runs *under the lock*, and that is the point of the closure
    /// rather than a `Bool` return. Returning a `Bool` decided the two events'
    /// order but did not impose it on their effects: prove released the lock
    /// before its caller incremented, so a teardown parked on `lock.lock()`
    /// could be woken by that unlock and reach `DaemonRuntime` *first* —
    /// decrementing a count of zero (`decrementToZero` clamps, fires
    /// `.clientDisconnected`, and returns), after which the increment landed
    /// on a connection that was already dead with its one teardown spent. That
    /// +1 never came back down: `clientBound` cleanup wedged forever on
    /// `app-<uid>`, and `liveAgentConnectionsByUser` pinned at 1 forever,
    /// permanently defeating `SessionAdmission`'s `noAgentConnected` gate and
    /// `.agentDisappeared`. Holding the lock across `body` makes prove's
    /// increment happen-before release's decrement, which is what the
    /// pre-latch code got for free by incrementing synchronously inside
    /// `shouldAcceptNewConnection`, before `resume()`.
    func proveOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .unproven else { return }
        state = .proven
        body()
    }

    /// Runs `body` — the caller's refcount decrements — only if this
    /// connection had been proven and has not been released before, i.e.
    /// exactly once per connection that was ever counted, and never for one
    /// that was not.
    ///
    /// Both `invalidationHandler` and `interruptionHandler` can fire for a
    /// single connection, on arbitrary threads; this is what makes the pair
    /// of them decrement once rather than twice. `body` runs under the lock
    /// for the ordering reason given on `proveOnce`.
    func releaseOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let wasCounted = state == .proven
        state = .released
        if wasCounted { body() }
    }
}
