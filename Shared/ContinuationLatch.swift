import Foundation

/// Guarantees a `CheckedContinuation` is resumed exactly once, from whichever
/// of two mutually-exclusive-in-theory callbacks actually fires.
///
/// Every `NSXPCConnection` message has two possible completions: the reply
/// block, or the proxy's error handler. NSXPC invokes exactly one of them per
/// message, but they arrive on arbitrary XPC queues, and a
/// `CheckedContinuation` resumed twice traps at runtime — crashing the process
/// is a strictly worse outcome than the hang this class exists to prevent. So
/// the "exactly once" property is enforced here rather than assumed, under a
/// lock because neither callback is guaranteed to be on any particular actor.
///
/// Lives in `Shared/` rather than beside either client because there are two
/// independent XPC clients in this codebase — `Sources/DaemonConnection.swift`
/// (the app) and `Agent/DaemonConnection.swift` (the agent) — and they have
/// already drifted apart once on exactly this hazard: the app's continuation
/// leak was found and fixed while the agent's identical one was not, because
/// the agent's only caller had not been wired up yet. One copy of the
/// primitive means the next correctness fix to it cannot land on only half the
/// codebase.
final class ContinuationLatch<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
