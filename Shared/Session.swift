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

/// How a session keeps the Mac awake. Deliberately *not* a single flag:
/// `SleepDisabled` is the only thing that survives a lid close, and
/// assertions are the only things that can be selective about the display.
/// See spec §1 — the two mechanisms are complementary and the daemon holds
/// both.
enum WakeMode: String, Codable, Equatable, CaseIterable {
    /// Idle system sleep prevented; the display may sleep. The mode most
    /// long-running headless work actually wants.
    case system
    /// Idle system *and* display sleep prevented.
    case systemAndDisplay
    /// Awake with the lid shut. The only mode needing the global setting,
    /// and the only one that works in clamshell.
    case clamshell

    var requiresSleepDisabled: Bool { self == .clamshell }
    var holdsDisplayAwake: Bool { self == .systemAndDisplay }
}

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
    /// How this session keeps the Mac awake. Defaults to `.clamshell` in
    /// both the memberwise initialiser and decoding: every session that
    /// exists today is a clamshell session, and a payload stored before this
    /// field existed must decode to the strongest mode, not silently become
    /// weaker.
    let wakeMode: WakeMode

    init(id: UUID, kind: SessionKind, owner: ClientID, ownerUID: UInt32 = 0,
         persistence: SessionPersistence, origin: SessionOrigin,
         startedAt: Date, triggerID: UUID? = nil, wakeMode: WakeMode = .clamshell) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.ownerUID = ownerUID
        self.persistence = persistence
        self.origin = origin
        self.startedAt = startedAt
        self.triggerID = triggerID
        self.wakeMode = wakeMode
    }

    // `wakeMode` needs a *decode-time* default, not just an initializer
    // default: Swift's synthesized Decodable requires a non-Optional
    // stored property's key to be present unless the property itself
    // carries a declaration-site default (`let wakeMode: WakeMode =
    // .clamshell`) — and that alternative is worse, because Swift then
    // excludes the property from decoding entirely, so a *real*,
    // non-clamshell `wakeMode` would silently come back as `.clamshell`
    // after any encode/decode round trip. A hand-written `init(from:)`
    // with `decodeIfPresent(...) ?? .clamshell` is the only way to get
    // "absent key defaults to clamshell" and "present key decodes
    // faithfully" at the same time. `encode(to:)` is left to synthesis.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        owner = try container.decode(ClientID.self, forKey: .owner)
        ownerUID = try container.decode(UInt32.self, forKey: .ownerUID)
        persistence = try container.decode(SessionPersistence.self, forKey: .persistence)
        origin = try container.decode(SessionOrigin.self, forKey: .origin)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        triggerID = try container.decodeIfPresent(UUID.self, forKey: .triggerID)
        wakeMode = try container.decodeIfPresent(WakeMode.self, forKey: .wakeMode) ?? .clamshell
    }
}
