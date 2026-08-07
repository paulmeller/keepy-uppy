import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let runtime: DaemonRuntime

    /// Whether every connection accepted by *this* listener is the agent.
    /// Role is structural now: it is fixed for the delegate's whole
    /// lifetime, tracking which Mach service (general vs. agent-only —
    /// `Helper/main.swift` stands up one `NSXPCListener` per service) the
    /// connection came in on, rather than being derived post hoc from the
    /// peer's pid (the TOCTOU-prone pattern this replaced).
    private let isAgent: Bool

    /// The code-signing requirement this listener enforces. The agent
    /// listener pins to `SigningRequirement.agentRequirement` (the agent's
    /// bundle identifier only); the general listener pins to the broader
    /// `SigningRequirement.requirement`.
    private let signingRequirement: String

    init(runtime: DaemonRuntime, isAgent: Bool) {
        self.runtime = runtime
        self.isAgent = isAgent
        self.signingRequirement = isAgent ? SigningRequirement.agentRequirement : SigningRequirement.requirement
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if SigningRequirement.isEnforced {
            newConnection.setCodeSigningRequirement(signingRequirement)
        } else {
            // A DEBUG daemon that logged this and accepted anyway was
            // itself an unauthenticated root daemon: any unprivileged local
            // process could drive root power state for as long as it
            // happened to be registered (security review batch B, Fix 5).
            // Refuse unless the operator explicitly opted in via the
            // daemon's own environment — never something a client can set.
            guard InsecureDebugGate.isExplicitlyOptedIn() else {
                helperLogger.fault(
                    "Refusing connection: code-signing enforcement is compiled out (DEBUG) and \(InsecureDebugGate.environmentKey)=1 is not set in the daemon's environment. Set it explicitly to run an insecure DEBUG daemon locally; this must never be set by accident or in any distributed build.")
                return false
            }
            helperLogger.error(
                "⚠️ DEBUG BUILD: XPC peer code-signing requirement NOT enforced (\(InsecureDebugGate.environmentKey)=1 set). This build must never be distributed.")
        }
        // A genuinely unique identity per accepted connection: every
        // isolation guarantee (Task 10) rests on `ClientID`, so it must not
        // be a value that can collide, which a hash of `ObjectIdentifier`
        // could.
        let id = ClientID(rawValue: UUID().uuidString)

        // Role is fixed by which listener (and therefore which Mach
        // service) accepted this connection, never by anything the client
        // asserts about itself, and never by re-deriving identity from the
        // peer's pid after the fact (spec §4).
        let isAgent = self.isAgent

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(runtime: runtime, clientID: id, isAgent: isAgent)

        // One-shot guard around `agentConnectionClosed()`: both
        // `invalidationHandler` and `interruptionHandler` below can fire for
        // the same connection, and each is documented to potentially run on
        // an arbitrary thread. Nobody has shown both actually firing for one
        // connection today, but nothing rules it out either, and the
        // refcount in `DaemonRuntime` must be decremented at most once per
        // accepted connection no matter how many teardown callbacks run.
        // `NSLock` makes the check-and-set atomic; the flag itself is
        // captured per connection (a fresh one per `shouldAcceptNewConnection`
        // call), not shared across connections.
        let closeLock = NSLock()
        var closed = false
        // Explicit `[runtime]` capture, same as the handlers below: captures
        // the `DaemonRuntime` value itself, not `self`, so this closure
        // (held by `newConnection`, not by the delegate) cannot extend the
        // delegate's lifetime.
        let closeAgentConnectionOnce: () -> Void = { [runtime] in
            closeLock.lock()
            let alreadyClosed = closed
            closed = true
            closeLock.unlock()
            guard !alreadyClosed else { return }
            runtime.agentConnectionClosed()
        }

        newConnection.invalidationHandler = { [runtime] in
            runtime.clientDisconnected(id)
            // No session outlives its evidence (spec §5): once the *last*
            // live agent connection disappears, agent-evaluated sessions
            // can no longer be verified and must end too (Fix 4: a single
            // other user's agent connection closing must not end this
            // one's sessions on a multi-user Mac).
            if isAgent { closeAgentConnectionOnce() }
        }
        newConnection.interruptionHandler = { [runtime] in
            runtime.clientDisconnected(id)
            if isAgent { closeAgentConnectionOnce() }
        }

        // Paired with the `closeAgentConnectionOnce()` calls above (Fixes 3
        // & 4): every accepted agent connection increments the same
        // refcount exactly once. Incremented *before* `resume()`, not
        // after, so the refcount can never be observed out of order
        // relative to the connection becoming live — there is no window
        // where the connection is live but the count hasn't been bumped yet.
        if isAgent { runtime.agentConnectionOpened() }
        newConnection.resume()
        helperLogger.log("Accepted connection \(id.rawValue) (agent: \(isAgent))")
        return true
    }
}
