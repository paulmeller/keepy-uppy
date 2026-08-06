import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let state = HelperState()

    func startup() {
        state.resetToSafeState()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if SigningRequirement.isEnforced {
            newConnection.setCodeSigningRequirement(SigningRequirement.requirement)
        } else {
            helperLogger.error(
                "⚠️ DEBUG BUILD: XPC peer code-signing requirement NOT enforced. This build must never be distributed.")
        }
        let id = ObjectIdentifier(newConnection)

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(state: state, clientID: id)

        newConnection.invalidationHandler = { [state] in state.remove(id) }
        newConnection.interruptionHandler = { [state] in state.remove(id) }

        newConnection.resume()
        helperLogger.log("Accepted connection \(String(describing: id))")
        return true
    }
}
