import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let runtime: DaemonRuntime

    init(runtime: DaemonRuntime) {
        self.runtime = runtime
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if SigningRequirement.isEnforced {
            newConnection.setCodeSigningRequirement(SigningRequirement.requirement)
        } else {
            helperLogger.error(
                "⚠️ DEBUG BUILD: XPC peer code-signing requirement NOT enforced. This build must never be distributed.")
        }
        // A genuinely unique identity per accepted connection: every
        // isolation guarantee (Task 10) rests on `ClientID`, so it must not
        // be a value that can collide, which a hash of `ObjectIdentifier`
        // could.
        let id = ClientID(rawValue: UUID().uuidString)

        // Role is derived from the peer's signing identity, never from
        // anything the client asserts about itself (spec §4).
        let isAgent = PeerIdentity.isAgent(newConnection)

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
