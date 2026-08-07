import Foundation

final class HelperService: NSObject, HelperProtocol {
    /// Generous upper bound on an accepted, not-yet-decoded `sessionJSON`
    /// payload (security review batch B, Fix 1). A legitimate `Session`
    /// encodes to at most a few hundred bytes — its largest field is
    /// `whileAppRunning`'s bundle identifier string. 16 KiB leaves well
    /// over an order of magnitude of headroom while rejecting an attempt to
    /// make `JSONDecoder` repeatedly chew on an arbitrarily large flood
    /// payload before any other check even runs.
    static let maxSessionPayloadBytes = 16 * 1024

    private let runtime: DaemonRuntime
    private let clientID: ClientID
    private let isAgent: Bool

    init(runtime: DaemonRuntime, clientID: ClientID, isAgent: Bool) {
        self.runtime = runtime
        self.clientID = clientID
        self.isAgent = isAgent
    }

    func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) {
        guard sessionJSON.count <= Self.maxSessionPayloadBytes else {
            return reply(nil, "session payload too large")
        }
        guard let requested = try? JSONDecoder().decode(Session.self, from: sessionJSON) else {
            return reply(nil, "invalid session payload")
        }
        // `id`, `owner`, and `startedAt` are authoritative server-side facts
        // and are never trusted from the client: a client cannot mint a
        // session "owned" by someone else, collide its id with an existing
        // session's, or backdate `startedAt` to dodge the max-duration
        // backstop.
        let session = Session(id: UUID(), kind: requested.kind, owner: clientID,
                              persistence: requested.persistence, origin: requested.origin,
                              startedAt: Date())
        switch runtime.startSession(session) {
        case .started:
            reply(session.id.uuidString, nil)
        case .ownerLimitReached:
            reply(nil, "too many sessions for this client; stop one before starting another")
        case .globalLimitReached:
            reply(nil, "daemon session limit reached; try again later")
        case .noAgentConnected:
            reply(nil, "no agent is connected to evaluate this condition")
        case .failed:
            reply(nil, "failed to start session")
        }
    }

    func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        switch runtime.stopSession(id: uuid, requestedBy: clientID) {
        case .authorized:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .forbidden:
            helperLogger.error("Rejected stopSession(\(sessionID)) from \(self.clientID.rawValue): caller does not own this session")
            reply(false, "not authorised")
        }
    }

    func stopAllSessions(all: Bool, reply: @escaping (Bool, String?) -> Void) {
        helperLogger.log("stopAllSessions(all: \(all)) from \(self.clientID.rawValue)")
        runtime.stopAll(all: all, requestedBy: clientID)
        reply(true, nil)
    }

    func listSessions(reply: @escaping (Data?, String?) -> Void) {
        guard let data = try? JSONEncoder().encode(runtime.currentSessions()) else {
            return reply(nil, "encoding failure")
        }
        reply(data, nil)
    }

    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        switch runtime.renewLease(id: uuid, until: until, requestedBy: clientID) {
        case .authorized:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .forbidden:
            helperLogger.error("Rejected renewLease(\(sessionID)) from \(self.clientID.rawValue): caller does not own this session")
            reply(false, "not authorised")
        }
    }

    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
        guard isAgent else {
            helperLogger.error("Rejected condition report from non-agent client \(self.clientID.rawValue)")
            return reply(false, "not authorised")
        }
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        switch runtime.conditionEnded(id: uuid) {
        case .ended:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .notAgentEvaluated:
            helperLogger.error("Rejected reportConditionEnded(\(sessionID)) from \(self.clientID.rawValue): session kind is not the agent's to end")
            reply(false, "not authorised")
        }
    }

    func registerAsAgent(reply: @escaping (Bool, String?) -> Void) {
        guard isAgent else {
            helperLogger.error("Rejected agent registration from non-agent client \(self.clientID.rawValue)")
            return reply(false, "not authorised")
        }
        runtime.registerAgent(clientID)
        reply(true, nil)
    }

    func currentState(reply: @escaping (Bool) -> Void) { reply(runtime.isKeepingAwake()) }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
