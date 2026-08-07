import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let runtime: DaemonRuntime

    /// Who every connection accepted by *this* listener is. Role is
    /// structural: it is fixed for the delegate's whole lifetime, tracking
    /// which Mach service (`Helper/main.swift` stands up one `NSXPCListener`
    /// per role) the connection came in on, rather than being derived post
    /// hoc from the peer's pid (the TOCTOU-prone pattern this replaced).
    ///
    /// It supplies two things: the code-signing requirement this listener
    /// pins (one bundle identifier, `role.inboundSigningRequirement`) and
    /// half of the peer's `ClientID` — the other half being the peer's
    /// authenticated uid. Both are server-side facts; neither is anything
    /// the client says about itself.
    private let role: ClientRole

    init(runtime: DaemonRuntime, role: ClientRole) {
        self.runtime = runtime
        self.role = role
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if SigningRequirement.isEnforced {
            newConnection.setCodeSigningRequirement(role.inboundSigningRequirement)
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
        // Supplied by XPC from the peer's audit credentials, not by the
        // client. This binds condition sessions to the matching user agent,
        // and is half of the peer's identity below.
        let userID = UInt32(newConnection.effectiveUserIdentifier)

        // A *stable* identity, not a fresh one per connection. Every
        // isolation guarantee (Task 10) rests on comparing this against
        // `Session.owner`, and a per-connection UUID meant a second
        // `keepy-uppy` invocation could never match the first's sessions —
        // so `keepy-uppy off` silently ended nothing. Derived entirely from
        // server-side facts (the accepting listener's role plus the
        // authenticated uid), so it is no more forgeable than the random id
        // it replaces. See `ClientRole.clientID(forUserID:)`.
        let id = role.clientID(forUserID: userID)

        // Role is fixed by which listener (and therefore which Mach
        // service) accepted this connection, never by anything the client
        // asserts about itself, and never by re-deriving identity from the
        // peer's pid after the fact (spec §4).
        let isAgent = role.isAgent

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(
            runtime: runtime, clientID: id, userID: userID, isAgent: isAgent)

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
            runtime.agentConnectionClosed(userID: userID)
        }

        // The same one-shot discipline, for the same reason, around the
        // *client* refcount — deliberately its own lock and flag rather than
        // sharing the agent one above, so the agent path's behaviour is
        // untouched by this change.
        //
        // This guard is newly load-bearing. `clientDisconnected` used to be
        // called from both handlers with no guard, which was harmless while
        // it was an idempotent "end this owner's `clientBound` sessions".
        // Now that identities are stable, several live connections can share
        // one `ClientID` and the call is a refcount decrement: a double
        // decrement for one connection would under-count the live ones and
        // tear down a still-connected client's sessions.
        let clientCloseLock = NSLock()
        var clientClosed = false
        let closeClientConnectionOnce: () -> Void = { [runtime] in
            clientCloseLock.lock()
            let alreadyClosed = clientClosed
            clientClosed = true
            clientCloseLock.unlock()
            guard !alreadyClosed else { return }
            runtime.clientDisconnected(id)
        }

        // Neither handler captures `self`: they hold only the two local
        // closures above, each of which captures `runtime` explicitly.
        newConnection.invalidationHandler = {
            closeClientConnectionOnce()
            // No session outlives its evidence (spec §5): once the *last*
            // live agent connection disappears, agent-evaluated sessions
            // can no longer be verified and must end too (Fix 4: a single
            // other user's agent connection closing must not end this
            // one's sessions on a multi-user Mac).
            if isAgent { closeAgentConnectionOnce() }
        }
        newConnection.interruptionHandler = {
            closeClientConnectionOnce()
            if isAgent { closeAgentConnectionOnce() }
        }

        // Paired with the `close*ConnectionOnce()` calls above: every
        // accepted connection increments the client refcount exactly once,
        // and every accepted *agent* connection the agent refcount exactly
        // once (Fixes 3 & 4). Incremented *before* `resume()`, not after, so
        // neither refcount can be observed out of order relative to the
        // connection becoming live — there is no window where the connection
        // is live but a count hasn't been bumped yet.
        runtime.clientConnected(id)
        if isAgent { runtime.agentConnectionOpened(userID: userID) }
        newConnection.resume()
        helperLogger.log("Accepted connection from \(id.rawValue) (role: \(self.role.rawValue))")
        return true
    }
}
