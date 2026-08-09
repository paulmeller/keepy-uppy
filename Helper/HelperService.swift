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
    private let userID: UInt32
    private let isAgent: Bool

    /// Called on entry to every `HelperProtocol` method below, before any
    /// other work — including before a method rejects its caller.
    ///
    /// Reaching *any* method on this object is the daemon's only proof that
    /// the peer satisfied the accepting listener's code-signing requirement:
    /// `HelperListenerDelegate` sets that requirement, but XPC adjudicates it
    /// after accept and delivers no message until it passes. So this is where
    /// the connection's liveness refcounts get incremented — see the closure
    /// in `HelperListenerDelegate.listener(_:shouldAcceptNewConnection:)`,
    /// which pairs it with the matching decrement.
    ///
    /// Idempotent by construction (`ConnectionProofLatch.proveOnce`), so
    /// calling it from all nine methods counts one connection once, however
    /// many messages it sends. One hook rather than nine copies of the
    /// bookkeeping, so the accounting cannot drift method by method — and the
    /// call itself is cheap enough to sit on every message (an uncontended
    /// lock; every method below already funnels into `DaemonRuntime`'s serial
    /// queue anyway).
    private let connectionProven: () -> Void

    init(runtime: DaemonRuntime, clientID: ClientID, userID: UInt32, isAgent: Bool,
         connectionProven: @escaping () -> Void) {
        self.runtime = runtime
        self.clientID = clientID
        self.userID = userID
        self.isAgent = isAgent
        self.connectionProven = connectionProven
    }

    func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) {
        connectionProven()
        guard sessionJSON.count <= Self.maxSessionPayloadBytes else {
            return reply(nil, "session payload too large")
        }
        guard let requested = try? JSONDecoder().decode(Session.self, from: sessionJSON) else {
            return reply(nil, "invalid session payload")
        }
        // The trusted/untrusted split — the most security-relevant step in
        // this method — is `Session.authorized(id:owner:ownerUID:startedAt:)`,
        // in `Shared/`. Read its doc comment for which fields the daemon owns
        // and which the client chooses, and why.
        //
        // It is not written out here on purpose. `Helper/` is not reachable
        // from the test target, so a field silently dropped from a rebuild at
        // this call site — which does not fail to compile; it takes
        // `Session.init`'s default — was undetectable by any test. Omitting
        // `wakeMode:` here is exactly what made every session in production a
        // clamshell session no matter what any client asked for. What remains
        // below is decode, authorize, switch.
        let session = requested.authorized(id: UUID(), owner: clientID,
                                           ownerUID: userID, startedAt: Date())
        switch runtime.startSession(session) {
        case .started:
            reply(session.id.uuidString, nil)
        case .ownerLimitReached:
            reply(nil, "too many sessions for this client; stop one before starting another")
        case .globalLimitReached:
            reply(nil, "daemon session limit reached; try again later")
        case .noAgentConnected:
            reply(nil, "no agent is connected to evaluate this condition")
        case .conditionNotMet:
            reply(nil, "the session condition is not currently met")
        case .triggerSuppressed:
            reply(nil, "trigger starts are temporarily suppressed by a safety cooldown")
        case .failed:
            reply(nil, "failed to start session")
        }
    }

    func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
        connectionProven()
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

    func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void) {
        connectionProven()
        helperLogger.log("stopAllSessions(all: \(all)) from \(self.clientID.rawValue)")
        let stopped = runtime.stopAll(all: all, requestedBy: clientID)
        reply(stopped, nil)
    }

    /// Logged at the same level as `stopAllSessions`, and for the same reason:
    /// it ends every client's sessions. The extra scalar is the one the caller
    /// has to act on — `false` means this Mac is still held awake, and
    /// `DaemonRemoval.next(after:)` turns that into a refusal to unregister.
    func prepareForRemoval(reply: @escaping (Int, Bool) -> Void) {
        connectionProven()
        helperLogger.log("prepareForRemoval from \(self.clientID.rawValue)")
        let outcome = runtime.prepareForRemoval()
        reply(outcome.stopped, outcome.sleepRestored)
    }

    func listSessions(reply: @escaping (Data?, String?) -> Void) {
        connectionProven()
        guard let data = try? JSONEncoder().encode(runtime.currentSessions()) else {
            return reply(nil, "encoding failure")
        }
        reply(data, nil)
    }

    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void) {
        connectionProven()
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        switch runtime.renewLease(id: uuid, until: until, requestedBy: clientID) {
        case .renewed:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .forbidden:
            helperLogger.error("Rejected renewLease(\(sessionID)) from \(self.clientID.rawValue): caller does not own this session")
            reply(false, "not authorised")
        case .notLease:
            reply(false, "session is not a lease")
        case .invalidDeadline:
            reply(false, "invalid lease deadline")
        }
    }

    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
        connectionProven()
        guard isAgent else {
            helperLogger.error("Rejected condition report from non-agent client \(self.clientID.rawValue)")
            return reply(false, "not authorised")
        }
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        switch runtime.conditionEnded(id: uuid, reportedByUserID: userID) {
        case .ended:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .notAgentEvaluated:
            helperLogger.error("Rejected reportConditionEnded(\(sessionID)) from \(self.clientID.rawValue): session kind is not the agent's to end")
            reply(false, "not authorised")
        case .wrongUser:
            helperLogger.error("Rejected reportConditionEnded(\(sessionID)) from uid \(self.userID): session belongs to another user")
            reply(false, "not authorised")
        }
    }

    func registerAsAgent(reply: @escaping (Bool, String?) -> Void) {
        connectionProven()
        guard isAgent else {
            helperLogger.error("Rejected agent registration from non-agent client \(self.clientID.rawValue)")
            return reply(false, "not authorised")
        }
        runtime.registerAgent(clientID)
        reply(true, nil)
    }

    func currentState(reply: @escaping (Bool) -> Void) {
        connectionProven()
        reply(runtime.isKeepingAwake())
    }

    func version(reply: @escaping (String) -> Void) {
        connectionProven()
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
