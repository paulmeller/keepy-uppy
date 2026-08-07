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
        let id = ClientID(rawValue: String(UInt(bitPattern: ObjectIdentifier(newConnection).hashValue)))

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(runtime: runtime, clientID: id)

        newConnection.invalidationHandler = { [runtime] in runtime.clientDisconnected(id) }
        newConnection.interruptionHandler = { [runtime] in runtime.clientDisconnected(id) }

        newConnection.resume()
        helperLogger.log("Accepted connection \(id.rawValue)")
        return true
    }
}
