import Foundation

struct ClientID: Hashable, Codable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

enum SessionKind: Equatable, Codable {
    case indefinite
    case duration(until: Date)
    case untilTime(Date)
    case lease(expires: Date)
    case whileAppRunning(bundleID: String)
    case whileExternalDisplay
    case whileOnACPower
    case whileCPUBusy(threshold: Double)

    /// Kinds the daemon can evaluate alone. Everything else needs the agent,
    /// and so cannot outlive it (spec §5).
    var isDaemonEvaluable: Bool {
        switch self {
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower: return true
        case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy: return false
        }
    }

    /// The kind's absolute deadline, for kinds that have one. `nil` for
    /// kinds with no fixed clock-time end (an indefinite session, or a
    /// condition the agent must observe), which `SessionTable`'s expiry
    /// tracking therefore ignores.
    var deadline: Date? {
        switch self {
        case .duration(let until), .untilTime(let until), .lease(let until):
            return until
        case .indefinite, .whileAppRunning, .whileExternalDisplay,
             .whileOnACPower, .whileCPUBusy:
            return nil
        }
    }
}

enum SessionPersistence: String, Codable { case clientBound, detached }
enum SessionOrigin: String, Codable { case manual, trigger }

struct Session: Equatable, Codable, Identifiable {
    let id: UUID
    let kind: SessionKind
    let owner: ClientID
    let persistence: SessionPersistence
    let origin: SessionOrigin
    let startedAt: Date
}
