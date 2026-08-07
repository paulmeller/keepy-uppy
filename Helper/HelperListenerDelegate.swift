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

        // Accepting a connection establishes nothing about the peer:
        // `setCodeSigningRequirement` above is adjudicated by XPC *after*
        // this method returns, and any local process can look up a Mach
        // service. This latch is what separates "accepted" from "proved
        // itself", and owns the exactly-once bookkeeping for both refcounts.
        // A fresh instance per `shouldAcceptNewConnection` call, never shared
        // across connections. See `Shared/ConnectionProofLatch.swift`.
        let proof = ConnectionProofLatch()

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        // Both halves of the refcount pairing live here, side by side, so a
        // future change cannot alter one without seeing the other. Explicit
        // `[runtime]` captures, so these closures — held by the connection,
        // not by the delegate — cannot extend the delegate's lifetime.
        //
        // The increments moved off accept and onto the arrival of the first
        // message (security review: refcount-before-proof). Every accepted
        // connection used to increment the client refcount, and every
        // accepted *agent* connection the agent refcount (Fixes 3 & 4) —
        // which meant an unsigned rogue that merely connected could hold
        // either count above zero for the adjudication window: enough to
        // suppress `clientDisconnected`'s `clientBound` cleanup when the real
        // app quit, and enough to fake agent liveness to
        // `SessionAdmission`'s `noAgentConnected` check. `HelperService`
        // calls this on entry to every `HelperProtocol` method, which XPC
        // reaches only for a peer that satisfied the requirement.
        newConnection.exportedObject = HelperService(
            runtime: runtime, clientID: id, userID: userID, isAgent: isAgent,
            connectionProven: { [runtime] in
                guard proof.proveOnce() else { return }
                runtime.clientConnected(id)
                if isAgent { runtime.agentConnectionOpened(userID: userID) }
            })

        // One guard, not two. Both refcounts are decremented from the same
        // pair of handlers, in the same order, and `isAgent` is fixed for
        // this connection's whole life — so the two independent lock/flag
        // pairs this replaces could never actually diverge, they just
        // duplicated the discipline twice over.
        //
        // The guard exists at all because `invalidationHandler` and
        // `interruptionHandler` can both fire for one connection, each on an
        // arbitrary thread, and every refcount here must be decremented at
        // most once per *counted* connection however many teardown callbacks
        // run. That check-and-set now lives inside the latch (which has to
        // hold a lock anyway, since prove and release genuinely race: a
        // message can be in flight while the connection tears down), and
        // `releaseOnce()` folds in the second half of this fix — it reports
        // `true` only for a connection that was actually counted, so a rogue
        // that connects and vanishes without ever passing the requirement
        // decrements nothing it never incremented.
        let tearDownOnce: () -> Void = { [runtime] in
            guard proof.releaseOnce() else { return }

            // Order preserved from when these were separate guards.
            runtime.clientDisconnected(id)
            // No session outlives its evidence (spec §5): once the *last*
            // live agent connection disappears, agent-evaluated sessions can
            // no longer be verified and must end too (Fix 4: one user's agent
            // connection closing must not end another's sessions).
            if isAgent { runtime.agentConnectionClosed(userID: userID) }
        }

        newConnection.invalidationHandler = tearDownOnce
        newConnection.interruptionHandler = tearDownOnce

        newConnection.resume()
        helperLogger.log("Accepted connection from \(id.rawValue) (role: \(self.role.rawValue))")
        return true
    }
}
