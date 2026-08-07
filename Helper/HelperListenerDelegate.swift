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
            helperLogger.error(
                "⚠️ DEBUG BUILD: XPC peer code-signing requirement NOT enforced. This build must never be distributed.")
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

        newConnection.invalidationHandler = { [runtime] in
            runtime.clientDisconnected(id)
            // No session outlives its evidence (spec §5): if the connection
            // that just disappeared was the agent, agent-evaluated sessions
            // can no longer be verified and must end too.
            if isAgent { runtime.agentDisappeared() }
        }
        newConnection.interruptionHandler = { [runtime] in
            runtime.clientDisconnected(id)
            if isAgent { runtime.agentDisappeared() }
        }

        newConnection.resume()
        helperLogger.log("Accepted connection \(id.rawValue) (agent: \(isAgent))")
        return true
    }
}
