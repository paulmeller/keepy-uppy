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
        // Every field of `Session` falls into exactly one of two categories,
        // and the split is the whole security model of this method. Adding a
        // field means deciding which category it is in — so both lists are
        // written out here rather than left to be re-derived from which
        // arguments happen to read `requested.`:
        //
        // SERVER-OWNED, overwritten and never trusted from the client — `id`,
        //   `owner`, `ownerUID`, `startedAt`. A client must not be able to
        //   mint a session "owned" by someone else, collide its id with an
        //   existing session's, or backdate `startedAt` to dodge the
        //   max-duration backstop. These are facts about *who is calling*,
        //   which only the daemon can establish.
        //
        // CLIENT-CHOSEN, passed through as asked — `kind`, `persistence`,
        //   `origin`, `triggerID`, and `wakeMode`. These are the *request*:
        //   what the caller wants, which the daemon then admits or rejects on
        //   its own terms (`DaemonRuntime.startSession`) but does not
        //   silently rewrite. `wakeMode` is here and not above because how a
        //   session keeps the Mac awake is the caller's business, exactly
        //   like when it ends — there is no mode a caller can select that
        //   would let it affect another client's session, since the daemon
        //   unions every live session's mode itself (`PowerPlan.reduce`).
        //
        // Omitting `wakeMode:` here — as this call did until plan 4 task 4 —
        // does not fail to compile: it silently takes the initialiser's
        // `.clamshell` default, so every session in production was a
        // clamshell session no matter what any client asked for.
        let session = Session(id: UUID(), kind: requested.kind, owner: clientID,
                              ownerUID: userID,
                              persistence: requested.persistence, origin: requested.origin,
                              startedAt: Date(), triggerID: requested.triggerID,
                              wakeMode: requested.wakeMode)
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
