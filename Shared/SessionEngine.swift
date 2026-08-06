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

/// Pure reducer over the session table. Holds no clock, performs no I/O:
/// `now` is supplied by the caller on every event.
struct SessionEngine {
    private var table = SessionTable()

    var sessions: [Session] { table.sessions }
    var desiredKeepAwake: Bool { table.desiredKeepAwake }

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
            table.insert(Session(id: existing.id, kind: .lease(expires: until),
                                 owner: existing.owner, persistence: existing.persistence,
                                 origin: existing.origin, startedAt: existing.startedAt))

        case .tick:
            break
        }

        // Time-based expiry is re-evaluated after every event, not only on
        // ticks, so a stale session can never be observed as alive.
        for session in table.sessions where Self.hasExpired(session, at: now) {
            table.remove(id: session.id)
            ended.append(session)
        }

        return ended
    }

    private static func hasExpired(_ session: Session, at now: Date) -> Bool {
        switch session.kind {
        case .duration(let until), .untilTime(let until), .lease(let until):
            return now >= until
        case .indefinite, .whileAppRunning, .whileExternalDisplay,
             .whileOnACPower, .whileCPUBusy:
            return false
        }
    }
}
