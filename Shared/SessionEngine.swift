import Foundation

enum SessionEvent {
    case start(Session)
    case stop(id: UUID)
    case stopAll
    case clientDisconnected(ClientID)
    /// The user-session agent went away, so agent-evaluated conditions can no
    /// longer be verified (spec §5: no session outlives its evidence).
    case agentDisappeared
    case conditionEnded(id: UUID)
    case renewLease(id: UUID, until: Date)
    case tick
}

/// Session-count admission caps (security review batch B, Fix 1).
/// Unbounded session counts make every O(n) operation over the table — the
/// expiry sweep, `listSessions`, ownership lookups — scale with however
/// many sessions a single client cares to start, turning a flood into a
/// CPU/latency attack on the daemon's own safety timer (the 5s tick runs on
/// the same serial queue as every XPC call). Both numbers are chosen
/// generously above any legitimate use — a handful of concurrent sessions
/// per client, e.g. one lease plus a couple of trigger-started ones — while
/// keeping the table, and therefore every scan over it, bounded to the low
/// hundreds even under an outright flood.
///
/// Also folds in the Fix 3 "no agent has ever connected" check: an
/// agent-evaluated kind started with zero live agent connections would be
/// evaluated by nobody and survive, unwatched, to the 8-hour backstop.
enum SessionAdmission: Equatable {
    case admitted
    case ownerLimitReached
    case globalLimitReached
    case noAgentConnected

    /// A single client (XPC connection) legitimately runs very few
    /// concurrent sessions; 20 is generous headroom over that while
    /// bounding what one misbehaving or compromised client can grow the
    /// table by.
    static let maxSessionsPerOwner = 20
    /// Each XPC connection gets a fresh, unique `ClientID`
    /// (`HelperListenerDelegate`), so a per-owner cap alone does not bound
    /// the daemon against a flood of short-lived connections. 200 — 10x the
    /// per-owner cap — keeps the whole table, and every O(n) operation over
    /// it, in the low hundreds regardless of how many distinct clients
    /// connect.
    static let maxSessionsGlobal = 200

    static func evaluate(kind: SessionKind, ownerCount: Int, globalCount: Int,
                          liveAgentConnections: Int) -> SessionAdmission {
        if globalCount >= maxSessionsGlobal { return .globalLimitReached }
        if ownerCount >= maxSessionsPerOwner { return .ownerLimitReached }
        if !kind.isDaemonEvaluable && liveAgentConnections <= 0 { return .noAgentConnected }
        return .admitted
    }
}

/// The result of an agent's `reportConditionEnded` call (Fix 6): an agent
/// may only end sessions it is plausible evidence for. Ending a
/// daemon-evaluable session (a lease, a duration, ...) is not the agent's
/// call to make.
enum ConditionEndOutcome: Equatable {
    case ended(Session)
    case notFound
    case notAgentEvaluated
}

/// Pure reducer over the session table. Holds no clock, performs no I/O:
/// `now` is supplied by the caller on every event.
struct SessionEngine {
    private var table = SessionTable()

    var sessions: [Session] { table.sessions }
    var desiredKeepAwake: Bool { table.desiredKeepAwake }

    /// Mirrors `SafetyConfig.default.maxSessionDuration` (8 hours): the
    /// absolute ceiling any session, including a renewed lease, may run for
    /// from its `startedAt`. Duplicated here — rather than `SessionEngine`
    /// taking a `SafetyConfig` dependency — because `SessionEngine` is a
    /// dependency-free pure reducer, and this check is defense-in-depth
    /// against `renewLease` alone scheduling a deadline further out than
    /// the safety backstop would ever honour, not a replacement for that
    /// backstop (which remains `SafetyEngine`'s job and is keyed off
    /// session age, not the kind's own deadline). If the two ever need to
    /// diverge, tighten this one, not loosen it — it is enforced
    /// independently of whether `SafetyEngine` happens to be wired up.
    static let maxSessionDuration: TimeInterval = 8 * 3600

    /// Starts a session, subject to `SessionAdmission`'s caps. The decision
    /// is made before any mutation, so a rejected start leaves every
    /// existing session exactly as it was.
    @discardableResult
    mutating func startSession(_ session: Session, now: Date, liveAgentConnections: Int) -> SessionAdmission {
        let decision = SessionAdmission.evaluate(
            kind: session.kind,
            ownerCount: table.count(ownedBy: session.owner),
            globalCount: table.count,
            liveAgentConnections: liveAgentConnections)
        guard decision == .admitted else { return decision }
        _ = apply(.start(session), now: now)
        return decision
    }

    /// Ends a session on the agent's report, but only if the agent has any
    /// business judging it — i.e. its kind is not one the daemon itself
    /// evaluates (Fix 6).
    @discardableResult
    mutating func endCondition(id: UUID, now: Date) -> ConditionEndOutcome {
        guard let session = table.session(id: id) else { return .notFound }
        guard !session.kind.isDaemonEvaluable else { return .notAgentEvaluated }
        _ = apply(.conditionEnded(id: id), now: now)
        return .ended(session)
    }

    @discardableResult
    mutating func apply(_ event: SessionEvent, now: Date) -> [Session] {
        var ended: [Session] = []

        switch event {
        case .start(let session):
            table.insert(session)

        case .stop(let id):
            if let session = table.remove(id: id) { ended.append(session) }

        case .stopAll:
            ended.append(contentsOf: table.sessions)
            for session in table.sessions { table.remove(id: session.id) }

        case .clientDisconnected(let owner):
            ended.append(contentsOf: table.removeAll(ownedBy: owner))

        case .agentDisappeared:
            for session in table.sessions where !session.kind.isDaemonEvaluable {
                table.remove(id: session.id)
                ended.append(session)
            }

        case .conditionEnded(let id):
            if let session = table.remove(id: id) { ended.append(session) }

        case .renewLease(let id, let until):
            guard let existing = table.remove(id: id) else { break }
            guard case .lease = existing.kind,
                  until.timeIntervalSinceReferenceDate.isFinite,
                  until <= existing.startedAt.addingTimeInterval(Self.maxSessionDuration)
            else {
                // Reject and restore the session exactly as it was.
                // Renewing must not (a) launder a non-lease kind into a
                // daemon-evaluated `.lease`, letting it outlive the agent
                // that was its evidence (spec §5, Fix 2), nor (b) accept a
                // non-finite or absurdly-far deadline that would defeat the
                // max-duration backstop's intent.
                table.insert(existing)
                break
            }
            table.insert(Session(id: existing.id, kind: .lease(expires: until),
                                 owner: existing.owner, persistence: existing.persistence,
                                 origin: existing.origin, startedAt: existing.startedAt))

        case .tick:
            break
        }

        // Time-based expiry is re-evaluated after every event, not only on
        // ticks, so a stale session can never be observed as alive.
        // `removeExpired` is O(1) in the common case (nothing due) rather
        // than an O(n) scan of the whole table (Fix 1).
        ended.append(contentsOf: table.removeExpired(at: now))

        return ended
    }
}
