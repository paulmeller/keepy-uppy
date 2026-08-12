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

    /// The peer's authenticated uid, and which of the daemon's three Mach
    /// services accepted it. Both are server-side facts, established by the OS
    /// at accept time and never asserted by the client (`ClientRole`).
    ///
    /// This used to be a bare `isAgent: Bool`, which was the whole of what any
    /// method here needed to know about role. Plan 8 Task 5 needs the role
    /// itself: spec §4's amendment turns on the caller being *the app*
    /// specifically, and a `Bool` that answers one question about a three-case
    /// enum cannot be widened without inventing a second flag beside it.
    /// Agent-ness is still spelled exactly once — `ClientRole.isAgent` — so
    /// `reportConditionEnded` and `registerAsAgent` keep meaning precisely
    /// "arrived on the agent-only Mach service".
    private let userID: UInt32
    private let role: ClientRole
    private var isAgent: Bool { role.isAgent }

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

    init(runtime: DaemonRuntime, clientID: ClientID, userID: UInt32, role: ClientRole,
         connectionProven: @escaping () -> Void) {
        self.runtime = runtime
        self.clientID = clientID
        self.userID = userID
        self.role = role
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
        // from the test target, so a field dropped from a rebuild at this call
        // site was undetectable by any test — and at the time it did not even
        // fail to compile, because it silently took `Session.init`'s default.
        // Omitting `wakeMode:` here is exactly what made every session in
        // production a clamshell session no matter what any client asked for.
        //
        // `Session.init` has no defaulted parameters any more, so that
        // particular omission would now be a compile error even in this
        // untested file. The rebuild still does not belong here: the compiler
        // can force a field to be *named*, and only `SessionTests` can check
        // that it is named with the value the client actually sent — which is
        // the half that decides whether a client's `keepsDisksAwake` or
        // `wakeMode` survives the trust split. What remains below is decode,
        // authorize, switch.
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
        // The decision is `SessionIsolation.authorize`, in `Shared/` — the same
        // division `startSession` makes above, and for the same reason: this
        // file is not reachable from the test target, and an authorisation rule
        // that no test can read is a rule nobody can check. Since Plan 8 Task 5
        // that rule has one clause that is *not* ownership (spec §4's
        // exception: this user's own trigger sessions), which is precisely the
        // kind of thing that must not be written where it cannot be tested.
        switch runtime.stopSession(id: uuid, requestedBy: clientID, uid: userID, role: role) {
        case .authorized:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .forbidden:
            helperLogger.error("Rejected stopSession(\(sessionID)) from \(self.clientID.rawValue): caller may not stop this session")
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
        switch runtime.renewLease(id: uuid, until: until, requestedBy: clientID,
                                  uid: userID, role: role) {
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

    /// Decode, authorize, switch — the shape `stopSession` and `startSession`
    /// have, and for the same division of labour: the decision
    /// (`SessionIsolation.authorize`) and the rebuild (`Session.with(power:)`)
    /// both live in `Shared/`, where a test can read them, because this file is
    /// not reachable from the test target.
    ///
    /// The payload is bounded by `startSession`'s limit rather than by one of
    /// its own. A `PowerRequest` encodes to a few dozen bytes, so 16 KiB is
    /// absurdly generous here — which is the point: the bound exists to stop
    /// `JSONDecoder` chewing on a flood payload before any other check runs, and
    /// a second constant for a second payload is a second number to keep in step
    /// for no benefit.
    func changeSessionPower(_ sessionID: String, powerJSON: Data,
                            reply: @escaping (Bool, String?) -> Void) {
        connectionProven()
        guard powerJSON.count <= Self.maxSessionPayloadBytes else {
            return reply(false, "power payload too large")
        }
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        // Strict by construction: `PowerRequest`'s synthesized decoder requires
        // both keys, so half a request is refused here rather than completed
        // with somebody's idea of a harmless default.
        guard let power = try? JSONDecoder().decode(PowerRequest.self, from: powerJSON) else {
            return reply(false, "invalid power payload")
        }
        switch runtime.changeSessionPower(id: uuid, to: power, requestedBy: clientID,
                                          uid: userID, role: role) {
        case .changed:
            reply(true, nil)
        case .notFound:
            reply(false, "no such session")
        case .forbidden:
            helperLogger.error("Rejected changeSessionPower(\(sessionID)) from \(self.clientID.rawValue): caller may not change this session")
            reply(false, "not authorised")
        case .failed:
            // The daemon has already put the previous request back and
            // re-applied it, so this is a report about a session that is still
            // running exactly as it was — not one left in an unknown state.
            reply(false, "this Mac would not enter that state; the session is unchanged")
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

    /// This daemon's own version, and the only method here that reads nothing
    /// and changes nothing.
    ///
    /// **Its first caller arrived in Plan 7 Task 10** — `DaemonConnection`,
    /// behind the CLI & Advanced tab's Diagnostics section. Until then it was
    /// declared, implemented, and called by nobody.
    ///
    /// It used to compose the reply here, from `CFBundleShortVersionString`
    /// alone, falling back to `"0"`. Both halves of that were wrong for the
    /// question the only caller asks. Every target ships the same
    /// `MARKETING_VERSION`, so a short version alone is equal between *any* two
    /// builds of this project — including a daemon left running by the copy of
    /// the app that was replaced, which is the exact state Diagnostics has to be
    /// able to show. `bundleVersionText` (Shared/XPCProtocol.swift) adds
    /// `CFBundleVersion`, which `just bump` moves per release, and is the same
    /// function the app formats its own version with, so a healthy install
    /// cannot read as a mismatch through a formatting difference alone.
    ///
    /// An older daemon still answers with a bare `"0.1.0"`, and the app renders
    /// that as a mismatch against its own `"0.1.0 (3)"`. That is the correct
    /// answer, not a false alarm: a daemon that predates this change *is* an
    /// older build than the app asking.
    func version(reply: @escaping (String) -> Void) {
        connectionProven()
        reply(bundleVersionText(of: .main))
    }

    /// The second method here that reads nothing this Mac's state depends on
    /// and changes nothing at all — see `HelperProtocol.recentSafetyStops` for
    /// why it is unfiltered, and for the gate its only caller passes first.
    ///
    /// Encoded exactly like `listSessions`, failure included: an encoding
    /// failure is `(nil, "encoding failure")` and not an empty array, because a
    /// client that cannot tell "nothing to report" from "I could not tell you"
    /// is the position this whole feature exists to get the app out of.
    func recentSafetyStops(reply: @escaping (Data?, String?) -> Void) {
        connectionProven()
        guard let data = try? JSONEncoder().encode(runtime.recentSafetyStops()) else {
            return reply(nil, "encoding failure")
        }
        reply(data, nil)
    }
}
