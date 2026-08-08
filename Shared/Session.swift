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
    /// The one `SessionKind` a trigger condition is deliberately bound to —
    /// see `TriggerRule.sessionKind(firing:now:)` for why this is an
    /// intentional exception to "a trigger starts a session, it doesn't
    /// bind that session's lifetime to the condition."
    case whileProcessRunning(processName: String)

    /// Kinds the daemon can evaluate alone. Everything else needs the agent,
    /// and so cannot outlive it (spec §5).
    var isDaemonEvaluable: Bool {
        switch self {
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower: return true
        case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy, .whileProcessRunning: return false
        }
    }

    /// The kind's **stable external name**, for anything that leaves this
    /// process: the `kind` field of the session-completion webhook JSON and
    /// the `KEEPY_UPPY_KIND` environment variable handed to a user's script
    /// (`Agent/SessionCompletionNotifier.swift`).
    ///
    /// This exists because those two call sites used `String(describing:)`,
    /// i.e. Swift's *synthesized debug description*, which is not a wire
    /// format and was never promised to be one. It rendered as
    /// `whileAppRunning(bundleID: "com.example.App")`, and renaming a case or
    /// even an associated-value *label* — a pure refactor, invisible to
    /// every test — would silently change what a user's script parses and
    /// what leaves the machine. `Tests/SessionCompletionTests.swift` pins
    /// every string below for exactly that reason: a rename now fails a test
    /// instead of breaking somebody's webhook consumer in production.
    ///
    /// The shape is `name` or `name:value`, lowercase kebab-case, where the
    /// value is everything after the *first* colon. Only the two kinds whose
    /// associated value identifies *what was being watched* carry one; a
    /// deadline is deliberately omitted (the event already carries `endedAt`)
    /// and so is `.whileCPUBusy`'s threshold, so that no `Double` formatting
    /// — and therefore no locale — can ever reach the wire.
    var wireDescription: String {
        switch self {
        case .indefinite: return "indefinite"
        case .duration: return "duration"
        case .untilTime: return "until-time"
        case .lease: return "lease"
        case .whileAppRunning(let bundleID): return "while-app-running:\(bundleID)"
        case .whileExternalDisplay: return "while-external-display"
        case .whileOnACPower: return "while-on-ac-power"
        case .whileCPUBusy: return "while-cpu-busy"
        case .whileProcessRunning(let processName): return "while-process-running:\(processName)"
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
             .whileOnACPower, .whileCPUBusy, .whileProcessRunning:
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
    /// Effective UID of the authenticated XPC peer that created the session.
    /// The daemon overwrites this server-side, just like `id`, `owner`, and
    /// `startedAt`; agent-evaluated sessions use it to bind their evidence to
    /// the matching per-user agent.
    let ownerUID: UInt32
    let persistence: SessionPersistence
    let origin: SessionOrigin
    let startedAt: Date
    /// The `TriggerRule.id` that started this session, for trigger-originated
    /// sessions. `nil` for manually-started sessions. Lets `triggersToFire`
    /// (Shared/TriggerRule.swift) recognize a rule already represented by a
    /// live session and not refire it every tick.
    let triggerID: UUID?

    init(id: UUID, kind: SessionKind, owner: ClientID, ownerUID: UInt32 = 0,
         persistence: SessionPersistence, origin: SessionOrigin,
         startedAt: Date, triggerID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.ownerUID = ownerUID
        self.persistence = persistence
        self.origin = origin
        self.startedAt = startedAt
        self.triggerID = triggerID
    }
}
