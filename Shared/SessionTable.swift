import Foundation

/// The authoritative set of live sessions. Sleep is disabled while any
/// session is alive; removing the last one restores it (spec §5).
struct SessionTable {
    private var storage: [UUID: Session] = [:]

    /// A lower bound (never later than the true minimum) on the earliest
    /// deadline among current sessions. It only ever moves earlier, on
    /// `insert`, and is left untouched by `remove`: removing sessions can
    /// only push the true minimum later or leave it unchanged, so a bound
    /// that was valid before a removal stays valid after it. That invariant
    /// is what makes `removeExpired`'s "nothing is due yet" check an O(1)
    /// comparison regardless of table size (security review batch B, Fix 1)
    /// — a flood of sessions can no longer turn every event into an O(n)
    /// scan that delays the daemon's own safety timer, which shares the
    /// same serial queue.
    private var earliestDeadline: Date?

    var sessions: [Session] { Array(storage.values) }
    var count: Int { storage.count }
    var desiredKeepAwake: Bool { !storage.isEmpty }

    /// O(1) lookup by id, so callers that only need one session (e.g.
    /// authorizing an agent's condition report) never have to materialise
    /// the whole table just to search it.
    func session(id: UUID) -> Session? { storage[id] }

    /// The caller's own live session count, without allocating an
    /// intermediate array — used to enforce the per-owner admission cap
    /// (`SessionAdmission`) on every start request.
    func count(ownedBy owner: ClientID) -> Int {
        storage.values.reduce(0) { $1.owner == owner ? $0 + 1 : $0 }
    }

    mutating func insert(_ session: Session) {
        storage[session.id] = session
        if let deadline = session.kind.deadline {
            earliestDeadline = min(earliestDeadline ?? deadline, deadline)
        }
    }

    @discardableResult
    mutating func remove(id: UUID) -> Session? {
        storage.removeValue(forKey: id)
    }

    /// Ends the client-bound sessions of a departing owner. Detached
    /// sessions deliberately survive — that is what lets `keepy-uppy on`
    /// outlive the process that asked for it.
    @discardableResult
    mutating func removeAll(ownedBy owner: ClientID) -> [Session] {
        let doomed = storage.values.filter {
            $0.owner == owner && $0.persistence == .clientBound
        }
        for session in doomed { storage.removeValue(forKey: session.id) }
        return doomed
    }

    /// Removes and returns every session whose deadline has passed at
    /// `now`. O(1) when nothing is due — the overwhelmingly common case,
    /// since this runs after every single event, not just on ticks — and a
    /// single full pass (only over whatever the cap currently bounds the
    /// table to) when something might be, which also re-tightens
    /// `earliestDeadline` to match what remains.
    mutating func removeExpired(at now: Date) -> [Session] {
        guard let earliest = earliestDeadline, earliest <= now else { return [] }

        var expired: [Session] = []
        var newEarliest: Date?
        for session in storage.values {
            guard let deadline = session.kind.deadline else { continue }
            if deadline <= now {
                expired.append(session)
            } else if newEarliest == nil || deadline < newEarliest! {
                newEarliest = deadline
            }
        }
        for session in expired { storage.removeValue(forKey: session.id) }
        earliestDeadline = newEarliest
        return expired
    }
}
