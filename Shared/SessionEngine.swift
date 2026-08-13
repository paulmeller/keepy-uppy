import Foundation

enum SessionEvent {
    case start(Session)
    case stop(id: UUID)
    case stopAll
    case clientDisconnected(ClientID)
    /// The user-session agent went away, so agent-evaluated conditions can no
    /// longer be verified (spec §5: no session outlives its evidence).
    case agentDisappeared(userID: UInt32)
    /// The daemon observed that AC power is no longer present.
    case acPowerDisconnected
    case conditionEnded(id: UUID)
    case renewLease(id: UUID, until: Date)
    /// A live session's power request changed — **the whole request**, never
    /// one axis of it. See `Session.with(power:)` for why the unit is
    /// `PowerRequest`, and `changePower(id:to:now:)` below for what this event
    /// can and cannot break.
    case changePower(id: UUID, to: PowerRequest)
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
    case conditionNotMet
    case triggerSuppressed

    /// A single client legitimately runs very few concurrent sessions; 20 is
    /// generous headroom over that while bounding what one misbehaving or
    /// compromised client can grow the table by.
    ///
    /// This only became a real bound once `ClientID` became stable
    /// (`ClientRole.clientID(forUserID:)`). While every accepted connection
    /// minted a fresh random identity, an owner's allowance reset on every
    /// reconnect, so the cap was close to decorative — reconnecting 20 times
    /// bought 400 sessions. There are now exactly (roles × uids) possible
    /// owners, and reconnecting returns to the same one.
    static let maxSessionsPerOwner = 20
    /// A backstop the per-owner cap cannot provide: on a multi-user Mac
    /// there is one owner per role per logged-in uid, so the per-owner cap
    /// alone scales with however many identities exist. 200 — 10x the
    /// per-owner cap — keeps the whole table, and every O(n) operation over
    /// it, in the low hundreds regardless of how many distinct clients
    /// connect.
    static let maxSessionsGlobal = 200

    /// Only `.detached` sessions can ever become orphaned garbage —
    /// `.clientBound` ones are removed the moment their owner disconnects
    /// (`SessionTable.removeAll(ownedBy:)`). Capping detached sessions at
    /// half the global cap guarantees at least `maxSessionsGlobal -
    /// maxDetachedSessionsGlobal` = 100 slots stay available for
    /// `.clientBound` sessions no matter how many connections flood
    /// `detached` starts and disappear (spec §5's documented known
    /// limitation — this closes it once the CLI, the actual origin of
    /// legitimate `detached` sessions, exists to design the fix against).
    static let maxDetachedSessionsGlobal = 100

    static func evaluate(kind: SessionKind, origin: SessionOrigin,
                         ownerCount: Int, globalCount: Int, detachedGlobalCount: Int,
                         liveAgentConnections: Int, onACPower: Bool,
                         triggersSuppressed: Bool, persistence: SessionPersistence) -> SessionAdmission {
        if globalCount >= maxSessionsGlobal { return .globalLimitReached }
        if persistence == .detached && detachedGlobalCount >= maxDetachedSessionsGlobal { return .globalLimitReached }
        if ownerCount >= maxSessionsPerOwner { return .ownerLimitReached }
        if origin == .trigger && triggersSuppressed { return .triggerSuppressed }
        if kind == .whileOnACPower && !onACPower { return .conditionNotMet }
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
    case wrongUser
}

enum LeaseRenewalOutcome: Equatable {
    case renewed(Session)
    case notFound
    case notLease
    case invalidDeadline
}

/// The result of `SessionEngine.changePower`.
///
/// `.changed` carries the session as it now is **and the request it had a moment
/// ago**, because the caller who needs this most is the daemon: `applyLocked()`
/// can refuse a promotion, and the previous request is what it has to put back
/// (`DaemonRuntime.changeSessionPower`). Handing it over here rather than making
/// that caller re-read the table is what keeps the rollback from being a second
/// lookup that could return something else.
///
/// It also makes a no-op answerable honestly: `from == session.power` means the
/// session already asked for exactly this, which is a *success* — nothing was
/// refused and nothing failed — and not a case for an error string.
///
/// **There is deliberately no rejection case beyond `.notFound`**, and the
/// contrast with `LeaseRenewalOutcome` directly above is the point. Renewing can
/// be rejected because a deadline can be nonsense (`.invalidDeadline`) and
/// because renewing *changes the kind*, which would launder an agent-evaluated
/// session into a daemon-evaluated `.lease` that outlives its evidence
/// (`.notLease`; spec §5, Fix 2). Neither has an analogue here: every
/// `PowerRequest` is a legal request for every session, and this change touches
/// neither `kind` nor any other field (`Session.with(power:)`), so there is
/// nothing to launder and nothing to validate. The rejection that *can* happen —
/// the machine refusing to enter the requested state — is not visible from this
/// layer at all; it belongs to the daemon, which rolls back by applying this
/// same event again with `from`.
enum PowerChangeOutcome: Equatable {
    case changed(session: Session, from: PowerRequest)
    case notFound
}

/// Pure reducer over the session table. Holds no clock, performs no I/O:
/// `now` is supplied by the caller on every event.
struct SessionEngine {
    private var table = SessionTable()

    var sessions: [Session] { table.sessions }
    /// The reduction the daemon applies on every event and every tick. See
    /// `SessionTable.desiredPowerPlan`.
    var desiredPowerPlan: PowerPlan { table.desiredPowerPlan }
    var desiredKeepAwake: Bool { table.desiredKeepAwake }

    /// The absolute ceiling a **renewed lease** may run for from its
    /// `startedAt`. Duplicated here — rather than `SessionEngine` taking a
    /// `SafetyConfig` dependency — because `SessionEngine` is a
    /// dependency-free pure reducer, and this check is defense-in-depth
    /// against `renewLease` alone scheduling a deadline further out than
    /// anything would ever honour. It is not a replacement for the safety
    /// backstop, which remains `SafetyEngine`'s job.
    ///
    /// **It no longer mirrors `SafetyConfig.default.maxSessionDuration`, and
    /// deliberately so.** That backstop now spends a budget of *battery* time
    /// and never fires on mains, so on a plugged-in Mac it is the looser of the
    /// two and this 8 hours is the binding limit on a lease. That is the
    /// direction the original note sanctioned — "if the two ever need to
    /// diverge, tighten this one, not loosen it" — and it still holds: this
    /// number is enforced whether or not `SafetyEngine` is wired up, so it must
    /// never be raised to chase the backstop.
    static let maxSessionDuration: TimeInterval = 8 * 3600

    /// Starts a session, subject to `SessionAdmission`'s caps. The decision
    /// is made before any mutation, so a rejected start leaves every
    /// existing session exactly as it was.
    @discardableResult
    mutating func startSession(_ session: Session, now: Date,
                               liveAgentConnections: Int,
                               onACPower: Bool = true,
                               triggersSuppressed: Bool = false) -> SessionAdmission {
        let decision = SessionAdmission.evaluate(
            kind: session.kind,
            origin: session.origin,
            ownerCount: table.count(ownedBy: session.owner),
            globalCount: table.count,
            detachedGlobalCount: table.count(persistence: .detached),
            liveAgentConnections: liveAgentConnections,
            onACPower: onACPower,
            triggersSuppressed: triggersSuppressed,
            persistence: session.persistence)
        guard decision == .admitted else { return decision }
        _ = apply(.start(session), now: now)
        return decision
    }

    /// Ends a session on the agent's report, but only if the agent has any
    /// business judging it — i.e. its kind is not one the daemon itself
    /// evaluates (Fix 6).
    @discardableResult
    mutating func endCondition(id: UUID, reportedByUserID userID: UInt32,
                               now: Date) -> ConditionEndOutcome {
        guard let session = table.session(id: id) else { return .notFound }
        guard !session.kind.isDaemonEvaluable else { return .notAgentEvaluated }
        guard session.ownerUID == userID else { return .wrongUser }
        _ = apply(.conditionEnded(id: id), now: now)
        return .ended(session)
    }

    @discardableResult
    mutating func renewLease(id: UUID, until: Date, now: Date) -> LeaseRenewalOutcome {
        // An expired lease cannot be resurrected in the interval before the
        // daemon's next timer tick. Sweep first, then decide whether there is
        // still a live lease to renew.
        _ = apply(.tick, now: now)
        guard let existing = table.session(id: id) else { return .notFound }
        guard case .lease = existing.kind else { return .notLease }
        guard until.timeIntervalSinceReferenceDate.isFinite,
              until > now,
              until <= existing.startedAt.addingTimeInterval(Self.maxSessionDuration)
        else { return .invalidDeadline }

        _ = apply(.renewLease(id: id, until: until), now: now)
        guard let renewed = table.session(id: id) else { return .invalidDeadline }
        return .renewed(renewed)
    }

    /// Changes what a live session asks of the machine, leaving everything else
    /// about it — including how and when it ends — exactly as it was.
    ///
    /// The sweep comes first, on `renewLease`'s reasoning one axis over: a
    /// session whose deadline has passed but whose removal is still up to five
    /// seconds away must not be observable as something you can change the mode
    /// of, because the reply would describe a session that is already over. It
    /// is also what makes the `.notFound` below cover both "no such id" and
    /// "that one has just expired" with one answer, which is what the caller can
    /// act on either way.
    ///
    /// `table.session(id:)` is asked before the event and again after it, and
    /// the second read is not ceremony: `apply` sweeps expiry at the end of
    /// *every* event, so the honest thing to report is what is in the table when
    /// the call returns, not what was put there mid-call.
    @discardableResult
    mutating func changePower(id: UUID, to power: PowerRequest, now: Date) -> PowerChangeOutcome {
        _ = apply(.tick, now: now)
        guard let existing = table.session(id: id) else { return .notFound }
        _ = apply(.changePower(id: id, to: power), now: now)
        guard let changed = table.session(id: id) else { return .notFound }
        return .changed(session: changed, from: existing.power)
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

        case .agentDisappeared(let userID):
            for session in table.sessions
                where !session.kind.isDaemonEvaluable && session.ownerUID == userID {
                table.remove(id: session.id)
                ended.append(session)
            }

        case .acPowerDisconnected:
            for session in table.sessions where session.kind == .whileOnACPower {
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
            // Every field but the deadline is carried across verbatim — by
            // `Session.renewed(until:)`, which is deliberately declared next
            // to `Session`'s own field list rather than written out here.
            // Spelling the rebuild out at this call site is what dropped
            // `triggerID` once and `wakeMode` again (an omitted argument does
            // not fail to compile; it silently takes the initialiser's
            // default), and left `ownerUID` free to be dropped next.
            table.insert(existing.renewed(until: until))

        case .changePower(let id, let power):
            guard let existing = table.remove(id: id) else { break }
            // Remove-then-insert, in `.renewLease`'s shape directly above, so
            // that "no such session" is one `break` in both and neither can
            // half-mutate. **What is deliberately missing is the validation
            // step between them**, and its absence is a decision rather than an
            // omission: renewing has two things to reject — a nonsense deadline,
            // and a kind laundered into `.lease` so it outlives the agent that
            // was its evidence — and a power request has neither. Every
            // `PowerRequest` is legal for every session, and
            // `Session.with(power:)` changes no other field, so there is no
            // rejected branch for an original to be restored to.
            //
            // `SessionTable.earliestDeadline` survives this untouched, which is
            // worth stating because a rebuild-and-reinsert is exactly the shape
            // that could break it: the bound only ever moves *earlier* on
            // insert and is left alone by remove (Shared/SessionTable.swift),
            // and `kind` is carried across verbatim here — so the reinserted
            // session has the same deadline it had, and a bound that was valid
            // before this event is still valid after it.
            table.insert(existing.with(power: power))

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
