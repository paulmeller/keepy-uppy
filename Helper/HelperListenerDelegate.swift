import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let state = HelperState()

    func startup() {
        state.resetToSafeState()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Task 5 adds peer code-signing verification here. Until then this
        // helper accepts any local connection and MUST NOT be shipped.
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
