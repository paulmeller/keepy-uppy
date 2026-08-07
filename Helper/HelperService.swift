import Foundation

final class HelperService: NSObject, HelperProtocol {
    private let runtime: DaemonRuntime
    private let clientID: ClientID

    init(runtime: DaemonRuntime, clientID: ClientID) {
        self.runtime = runtime
        self.clientID = clientID
    }

    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if enabled {
            let session = Session(id: UUID(), kind: .indefinite, owner: clientID,
                                  persistence: .clientBound, origin: .manual,
                                  startedAt: Date())
            reply(runtime.startSession(session), nil)
        } else {
            runtime.stopAll()
            reply(true, nil)
        }
    }

    func currentState(reply: @escaping (Bool) -> Void) { reply(runtime.isKeepingAwake()) }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
