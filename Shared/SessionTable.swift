import Foundation

/// The authoritative set of live sessions. Sleep is disabled while any
/// session is alive; removing the last one restores it (spec §5).
struct SessionTable {
    private var storage: [UUID: Session] = [:]

    var sessions: [Session] { Array(storage.values) }
    var desiredKeepAwake: Bool { !storage.isEmpty }

    mutating func insert(_ session: Session) {
        storage[session.id] = session
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
}
