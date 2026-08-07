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
/// Lives in `Shared/` rather than in `Helper/` for the same reason
/// `ContinuationLatch` does: `Helper/` is not in the test target, so a
/// one-shot primitive written there is a correctness-critical invariant with
/// no way to test it. `Shared/` is compiled into the app target the tests
/// import.
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
    /// arbitrary threads with no actor context, and both transitions are a
    /// check-and-set over three bytes of state with no call-outs underneath
    /// the lock — so there is nothing here that can deadlock or re-enter.
    private let lock = NSLock()
    private var state: State = .unproven

    /// Returns `true` on the first call for a connection that is still live,
    /// and `false` every other time — including the first call, if the
    /// connection was already released.
    ///
    /// The caller increments its refcounts exactly when this returns `true`.
    /// The "already released" case deliberately returns `false` rather than
    /// counting: an increment after teardown would never be balanced by a
    /// decrement, since teardown has already run and runs at most once.
    func proveOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .unproven else { return false }
        state = .proven
        return true
    }

    /// Returns `true` only if this connection had been proven and has not
    /// been released before — i.e. exactly once per connection that was ever
    /// counted, and never for one that was not.
    ///
    /// Both `invalidationHandler` and `interruptionHandler` can fire for a
    /// single connection, on arbitrary threads; this is what makes the pair
    /// of them decrement once rather than twice.
    func releaseOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCounted = state == .proven
        state = .released
        return wasCounted
    }
}
