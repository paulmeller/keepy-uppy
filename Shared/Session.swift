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
    /// Ends when the named volume is unmounted. The second condition-bound
    /// kind, and the same shape as `.whileExternalDisplay`: "keep this Mac
    /// awake while the backup drive is plugged in" is a *while* on its face,
    /// and a mounted volume is a stable fact rather than one that flickers.
    case whileVolumeMounted(name: String)
    /// Ends when this Mac no longer holds an address inside the block. "While
    /// I am on my home network" — durable, and unlike the Wi-Fi trigger it
    /// needs no Location Services grant and works over Ethernet too.
    case whileOnSubnet(cidr: String)
    /// Ends when no VPN is up any more. "Keep this Mac awake while the tunnel
    /// is up" is durable in the way `.whileOnSubnet` is — a VPN does not
    /// connect and drop between two ticks while a laptop sits on a desk — and
    /// a VPN going down is a real event worth ending on.
    ///
    /// Carries no associated value on purpose: `VPNObserving` answers "is any
    /// VPN up", because the request is never about a particular tunnel and
    /// naming one would mean typing a service identifier nobody has seen.
    case whileVPNActive
    /// Ends when the named USB device is unplugged. "Keep this Mac awake while
    /// the backup dongle is in" — the same shape as `.whileExternalDisplay`,
    /// and as stable a fact: a device is attached or it is not, and it does not
    /// flicker between two ticks the way a Bluetooth connection does.
    ///
    /// Identified by vendor and product ID rather than by name; see
    /// `USBDeviceID`.
    case whileUSBDevicePresent(vendorID: UInt16, productID: UInt16)

    /// A kind's identity without its associated value, so that `CaseIterable`
    /// guarantees are available to anything that has to cover every kind: the
    /// CLI-reachability test, and `wireDescription`'s stable external names.
    ///
    /// It exists because `SessionKind` cannot be `CaseIterable` (four of its
    /// cases carry values) and nothing therefore linked the set of kinds to the
    /// set of ways to *ask* for one. Three kinds —
    /// `.whileExternalDisplay`, `.whileOnACPower` and `.whileCPUBusy` — were
    /// evaluated by the daemon and the agent, encoded, decoded, described on the
    /// wire, and constructible by no client at all: `CLICommand`'s flag list is
    /// a separate enum, so adding a case here compiled cleanly with no flag to
    /// select it. Exactly the shape of the `WakeMode` reachability hole Plan 4
    /// closed, and of the `TriggerConditionKind` one Plan 5 closed, one level up.
    ///
    /// `Tests/CLICommandTests.swift` asserts a bijection between
    /// `Family.allCases` (minus `.lease`, which the XPC lease path creates and
    /// no flag should) and the kinds `keepy-uppy on` can produce, so a tenth
    /// kind with no way to select it fails a test instead of lurking.
    ///
    /// Raw values are exactly the wire stems `wireDescription` already emits and
    /// `Tests/SessionCompletionTests.swift` already pins, so deriving that
    /// property from this enum is verified by tests that predate it.
    enum Family: String, CaseIterable {
        case indefinite, duration
        case untilTime = "until-time"
        case lease
        case whileAppRunning = "while-app-running"
        case whileExternalDisplay = "while-external-display"
        case whileOnACPower = "while-on-ac-power"
        case whileCPUBusy = "while-cpu-busy"
        case whileProcessRunning = "while-process-running"
        case whileVolumeMounted = "while-volume-mounted"
        case whileOnSubnet = "while-on-subnet"
        case whileVPNActive = "while-vpn-active"
        case whileUSBDevicePresent = "while-usb-device-present"
    }

    /// This kind's family, dropping its associated value. Exhaustive, so a new
    /// case cannot be added without giving it one — which is what makes
    /// `Family.allCases` a trustworthy list of every kind there is.
    var family: Family {
        switch self {
        case .indefinite: return .indefinite
        case .duration: return .duration
        case .untilTime: return .untilTime
        case .lease: return .lease
        case .whileAppRunning: return .whileAppRunning
        case .whileExternalDisplay: return .whileExternalDisplay
        case .whileOnACPower: return .whileOnACPower
        case .whileCPUBusy: return .whileCPUBusy
        case .whileProcessRunning: return .whileProcessRunning
        case .whileVolumeMounted: return .whileVolumeMounted
        case .whileOnSubnet: return .whileOnSubnet
        case .whileVPNActive: return .whileVPNActive
        case .whileUSBDevicePresent: return .whileUSBDevicePresent
        }
    }

    /// Kinds the daemon can evaluate alone. Everything else needs the agent,
    /// and so cannot outlive it (spec §5).
    var isDaemonEvaluable: Bool {
        switch self {
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower: return true
        case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy, .whileProcessRunning,
             .whileVolumeMounted, .whileOnSubnet, .whileVPNActive, .whileUSBDevicePresent: return false
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
    /// value is everything after the *first* colon. The name is `Family`'s raw
    /// value rather than a second copy of the same eleven literals — one list, so
    /// a kind cannot be named one thing here and another there. Only the kinds
    /// whose associated value identifies *what was being watched* carry a
    /// value; a deadline is deliberately omitted (the event already carries
    /// `endedAt`) and so is `.whileCPUBusy`'s threshold, so that no `Double`
    /// formatting — and therefore no locale — can ever reach the wire.
    ///
    /// Still an exhaustive `switch` rather than a `default`, for the reason
    /// `TriggerConditionKind.bindsSessionLifetime` is one: whether a new kind
    /// puts something after the colon is a decision its author has to meet, and
    /// a `default` would answer "no" on their behalf, silently, in the one place
    /// whose output leaves the machine.
    var wireDescription: String {
        switch self {
        case .whileAppRunning(let bundleID): return "\(family.rawValue):\(bundleID)"
        case .whileProcessRunning(let processName): return "\(family.rawValue):\(processName)"
        case .whileVolumeMounted(let name): return "\(family.rawValue):\(name)"
        case .whileOnSubnet(let cidr): return "\(family.rawValue):\(cidr)"
        // The value itself contains a colon (`while-usb-device-present:0x05ac:0x024f`),
        // which the "everything after the *first* colon" rule above already
        // covers — a consumer that splits once gets `USBDeviceID.text` back
        // whole. `%04x` carries no locale, so no formatting can vary here.
        case .whileUSBDevicePresent(let vendorID, let productID):
            return "\(family.rawValue):\(USBDeviceID(vendorID: vendorID, productID: productID).text)"
        // `.whileVPNActive` is here rather than above because it has no
        // associated value to put after the colon: the condition is "any VPN",
        // so there is nothing that identifies *which* tunnel was watched.
        case .indefinite, .duration, .untilTime, .lease, .whileExternalDisplay,
             .whileOnACPower, .whileCPUBusy, .whileVPNActive:
            return family.rawValue
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
             .whileOnACPower, .whileCPUBusy, .whileProcessRunning, .whileVolumeMounted,
             .whileOnSubnet, .whileVPNActive, .whileUSBDevicePresent:
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

    /// This session with its lease deadline moved, and **nothing else**
    /// changed.
    ///
    /// It lives here, immediately under the field list it has to mirror,
    /// because rebuilding a `Session` field by field is this type's one
    /// recurring trap: exactly three of its fields carry defaults in the
    /// memberwise initialiser (`ownerUID`, `triggerID`, `wakeMode`), and
    /// omitting any of those three at a rebuild site does **not** fail to
    /// compile — it silently substitutes the default. `triggerID` was dropped
    /// from `SessionEngine`'s lease renewal once; `wakeMode` was dropped from
    /// the same line when it was added, which *escalated* a renewed session
    /// (a client that asked for the display to be free to sleep had the
    /// global `SleepDisabled` switched on for it at the first renewal), and
    /// `ownerUID` could still have been dropped there with every test
    /// passing.
    ///
    /// One copy, adjacent to the fields, is the structural fix: a new field
    /// is added a few lines above the only place that has to carry it
    /// across, and `SessionEngineTests`' whole-struct renewal test — a
    /// `Session == Session` comparison, not a hand-written list of fields —
    /// fails if it isn't.
    func renewed(until: Date) -> Session {
        Session(id: id, kind: .lease(expires: until), owner: owner, ownerUID: ownerUID,
                persistence: persistence, origin: origin, startedAt: startedAt,
                triggerID: triggerID, wakeMode: wakeMode)
    }

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

extension Session {
    /// The session the daemon will actually run, given `self` as the
    /// *request* a client sent over XPC.
    ///
    /// Every field of `Session` falls into exactly one of two categories, and
    /// the split is the whole security model of starting a session. Adding a
    /// field means deciding which category it is in, and the signature says
    /// which one it landed in without anyone having to re-derive it:
    ///
    /// SERVER-OWNED — the four parameters below, overwritten and never
    ///   trusted from the client. A client must not be able to mint a session
    ///   "owned" by someone else, collide its id with an existing session's,
    ///   or backdate `startedAt` to dodge the max-duration backstop. These are
    ///   facts about *who is calling*, which only the daemon can establish.
    ///
    /// CLIENT-CHOSEN — everything read off `self`: `kind`, `persistence`,
    ///   `origin`, `triggerID`, and `wakeMode`. These are the request: what
    ///   the caller wants, which the daemon then admits or rejects on its own
    ///   terms (`SessionAdmission`) but does not silently rewrite. `wakeMode`
    ///   is here and not above because how a session keeps the Mac awake is
    ///   the caller's business, exactly like when it ends — there is no mode a
    ///   caller can select that would let it affect another client's session,
    ///   since the daemon unions every live session's mode itself
    ///   (`PowerPlan.reduce`).
    ///
    /// This lives in `Shared/` for the same reason `SessionTable.desiredPowerPlan`
    /// does: `Helper/` is not reachable from the test target, so anything left
    /// there is verified by reading alone — and this is the most
    /// security-relevant line in `HelperService.startSession`, with the same
    /// silent-default trap as `renewed(until:)` above. Omitting `wakeMode:`
    /// from the rebuild is exactly what made every session in production a
    /// clamshell session no matter what any client asked for, and it did not
    /// fail to compile. `SessionTests` now covers the split directly, with a
    /// whole-struct comparison rather than a hand-written field list.
    func authorized(id: UUID, owner: ClientID, ownerUID: UInt32, startedAt: Date) -> Session {
        Session(id: id, kind: kind, owner: owner, ownerUID: ownerUID,
                persistence: persistence, origin: origin, startedAt: startedAt,
                triggerID: triggerID, wakeMode: wakeMode)
    }
}
