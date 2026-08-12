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
    /// I am on my home network" — durable, needs no Location Services grant,
    /// and works over Ethernet too.
    ///
    /// It is also the *only* network-identity kind there is: the Wi-Fi SSID
    /// trigger specified beside it was cut, because an unauthorized `ssid()`
    /// read is indistinguishable from "not on Wi-Fi" and the agent can never
    /// obtain the grant. See `NetworkAddressObserving`.
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

        /// A representative `SessionKind` of this family. Associated values are
        /// stand-ins chosen to be recognisable in a failure message, never
        /// matched against anything live.
        ///
        /// The precedent, and the argument, are `TriggerConditionKind.
        /// sampleCondition`'s: it is the bridge from "every kind there is" to
        /// "a value to try it with", which is what lets a guard be written over
        /// `allCases` instead of over a hand-written list a fourteenth kind
        /// would silently not appear in. It lives here rather than in the test
        /// for the same reason that one does — **two lists that must agree are
        /// one list** — and being an exhaustive `switch` it stops compiling the
        /// moment a case is added to `Family`, which is precisely when somebody
        /// needs to be asked what a sample of it looks like.
        ///
        /// The deadline is a **parameter** rather than a baked-in constant,
        /// where `sampleCondition` needed none. Three families
        /// (`.duration`, `.untilTime`, `.lease`) carry a `Date`, and this
        /// project injects time rather than reading it — a `Date()` in
        /// `Shared/` would make every test using this non-deterministic, and a
        /// fixed 1970 literal would hand callers a deadline that is always in
        /// the past, which is a different lie. The caller has a clock; it can
        /// say which one.
        func sampleKind(deadline: Date) -> SessionKind {
            switch self {
            case .indefinite: return .indefinite
            case .duration: return .duration(until: deadline)
            case .untilTime: return .untilTime(deadline)
            case .lease: return .lease(expires: deadline)
            case .whileAppRunning: return .whileAppRunning(bundleID: "com.apple.dt.Xcode")
            case .whileExternalDisplay: return .whileExternalDisplay
            case .whileOnACPower: return .whileOnACPower
            case .whileCPUBusy: return .whileCPUBusy(threshold: 0.3)
            case .whileProcessRunning: return .whileProcessRunning(processName: "claude")
            case .whileVolumeMounted: return .whileVolumeMounted(name: "Backup")
            case .whileOnSubnet: return .whileOnSubnet(cidr: "192.168.1.0/24")
            case .whileVPNActive: return .whileVPNActive
            case .whileUSBDevicePresent:
                return .whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f)
            }
        }
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
    /// How this session keeps the Mac awake. **No memberwise default** — see
    /// the initialiser below — but an absent key still decodes to
    /// `.clamshell`: every session that existed before this field did was a
    /// clamshell session, and a payload stored by an older build must decode
    /// to the strongest mode rather than silently becoming weaker.
    let wakeMode: WakeMode
    /// Whether this session also asks the machine to keep attached disks from
    /// idling into a lower power state.
    ///
    /// A third axis, not a fourth `WakeMode`. `WakeMode` is a user-facing choice
    /// of one radio button — three named points, not a grid — and folding this
    /// in would make it six cases, two of which nobody would ever pick. The
    /// mechanism layer already models axes separately and correctly
    /// (`PowerPlan`), so this belongs beside `wakeMode`, not inside it.
    ///
    /// Its **decode-time** default is `false`, which is the opposite direction
    /// from `wakeMode`'s and deliberately so: no session that existed before
    /// this field asked for it, and inventing a held assertion for a session
    /// that never requested one is over-application — a Mac whose disks never
    /// spin down, for a reason nothing on screen explains.
    ///
    /// **No memberwise default, and neither has anything else any more.** See
    /// the initialiser below.
    let keepsDisksAwake: Bool

    /// This session's power request as one value, for `PowerPlan.reduce`.
    ///
    /// The reduction takes whole requests rather than one axis at a time, so
    /// this is the only place the two are assembled and no caller can pass one
    /// and forget the other.
    var power: PowerRequest { PowerRequest(wakeMode: wakeMode, keepsDisksAwake: keepsDisksAwake) }

    /// This session with its lease deadline moved, and **nothing else**
    /// changed.
    ///
    /// It lives here, immediately under the field list it has to mirror,
    /// because rebuilding a `Session` field by field is this type's one
    /// recurring trap. It used to be a trap the compiler slept through: three
    /// of its fields carried memberwise defaults (`ownerUID`, `triggerID`,
    /// `wakeMode`), and omitting any of those three at a rebuild site did
    /// **not** fail to compile — it silently substituted the default.
    /// `triggerID` was dropped from `SessionEngine`'s lease renewal once;
    /// `wakeMode` was dropped from the same line when it was added, which
    /// *escalated* a renewed session (a client that asked for the display to be
    /// free to sleep had the global `SleepDisabled` switched on for it at the
    /// first renewal), and `ownerUID` could still have been dropped there with
    /// every test passing.
    ///
    /// No parameter has a default any more, so an omission here is now a
    /// compile error rather than a silent substitution. One copy, adjacent to
    /// the fields, is still the structural fix for the *other* half — a new
    /// field is added a few lines above the only place that has to carry it
    /// across — and `SessionEngineTests`' whole-struct renewal test, a
    /// `Session == Session` comparison rather than a hand-written list of
    /// fields, is what catches a field carried across as the wrong value.
    func renewed(until: Date) -> Session {
        Session(id: id, kind: .lease(expires: until), owner: owner, ownerUID: ownerUID,
                persistence: persistence, origin: origin, startedAt: startedAt,
                triggerID: triggerID, wakeMode: wakeMode, keepsDisksAwake: keepsDisksAwake)
    }

    /// This session with a different **whole power request**, and **nothing
    /// else** changed.
    ///
    /// It is on the line under `renewed(until:)` for that function's reason,
    /// which is the only reason: rebuilding a `Session` field by field is this
    /// type's one recurring trap, it bit five times, and what fixed it was one
    /// copy of the rebuild *adjacent to the field list it has to mirror* rather
    /// than a rebuild spelled out wherever one was needed. Two rebuilds, both
    /// here, both a few lines under the fields — so a twelfth field is carried
    /// across by editing the two functions directly below where it was just
    /// added.
    ///
    /// **It takes a `PowerRequest`, not a `WakeMode`**, and that is the same
    /// argument `PowerPlan.reduce`, `PowerPlanHolder.apply` and
    /// `DaemonConnection.startSession(kind:power:)` each make in their own doc
    /// comments, restated for a *change*: a rebuild that took one axis would
    /// leave `keepsDisksAwake` as the axis somebody forgets. It is worse here
    /// than at those three, too — forgetting it at a start defaults a session
    /// nobody has yet relied on, while forgetting it here silently *resets* a
    /// live session's answer on an axis the caller never mentioned.
    ///
    /// `startedAt` is carried across like every other field, and is called out
    /// because it is the one whose loss would be both invisible and expensive:
    /// a rebuild that restamped it would hand the session a fresh 8-hour
    /// max-duration budget (`SessionEngine.maxSessionDuration`, and
    /// `SafetyEngine`'s backstop, which keys off session age) every time its
    /// mode changed. `SessionTests` compares whole structs rather than a
    /// hand-written field list, because the compiler can force a field to be
    /// *named* here but not to be named with the value the caller sent.
    func with(power: PowerRequest) -> Session {
        Session(id: id, kind: kind, owner: owner, ownerUID: ownerUID,
                persistence: persistence, origin: origin, startedAt: startedAt,
                triggerID: triggerID, wakeMode: power.wakeMode,
                keepsDisksAwake: power.keepsDisksAwake)
    }

    /// **No parameter here has a default, and none may gain one.**
    ///
    /// Three used to (`ownerUID`, `triggerID`, `wakeMode`) and the omission bit
    /// five times, always the same way: a rebuild site that left one out
    /// compiled silently and substituted somebody else's idea of harmless.
    /// `triggerID` was dropped from lease renewal; `wakeMode` was dropped from
    /// the same line and *escalated* every renewed session; omitting it from
    /// `authorized(...)` made every production session a clamshell session
    /// whatever the client asked for. All three compiled. All three passed.
    ///
    /// There is no way to assert "this does not compile" in XCTest, so this
    /// comment is the guarantee. Adding a defaulted parameter here is the thing
    /// it forbids. Note that the **decode-time** defaults in `init(from:)` are a
    /// different mechanism serving a different caller (the wire) and stay.
    init(id: UUID, kind: SessionKind, owner: ClientID, ownerUID: UInt32,
         persistence: SessionPersistence, origin: SessionOrigin,
         startedAt: Date, triggerID: UUID?, wakeMode: WakeMode,
         keepsDisksAwake: Bool) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.ownerUID = ownerUID
        self.persistence = persistence
        self.origin = origin
        self.startedAt = startedAt
        self.triggerID = triggerID
        self.wakeMode = wakeMode
        self.keepsDisksAwake = keepsDisksAwake
    }

    // `wakeMode` and `keepsDisksAwake` need *decode-time* defaults, which are
    // not the same mechanism as an initializer default and survive its
    // removal: Swift's synthesized Decodable requires a non-Optional stored
    // property's key to be present unless the property itself carries a
    // declaration-site default (`let wakeMode: WakeMode = .clamshell`) — and
    // that alternative is worse, because Swift then excludes the property from
    // decoding entirely, so a *real*, non-clamshell `wakeMode` would silently
    // come back as `.clamshell` after any encode/decode round trip, and a real
    // `keepsDisksAwake: true` as `false`. A hand-written `init(from:)` with
    // `decodeIfPresent(...) ?? …` is the only way to get "absent key defaults"
    // and "present key decodes faithfully" at the same time. `encode(to:)` is
    // left to synthesis.
    //
    // The two defaults point in OPPOSITE directions, and that is the decision,
    // not an inconsistency. An absent `wakeMode` becomes the STRONGEST mode
    // because weakening a session that already exists loses a user's work; an
    // absent `keepsDisksAwake` becomes the WEAKEST state because nobody asked
    // for it and holding disks awake unasked costs battery for no visible
    // reason. `SessionDiskAxisTests` pins both directions off one payload.
    //
    // ## What those defaults cost under client/daemon skew
    //
    // They are written for a *stored* payload — a session read back that was
    // encoded before the field existed. But the same decoder runs on the wire,
    // where the payload is a **request from a client of a different vintage**,
    // and there the same defaults mean an older daemon silently drops what a
    // newer client asked for. It decodes the request, never sees the key
    // (its `Session` has no such property), admits a session without it, and
    // replies with a session id. Nothing fails; the client shows a running
    // session that is not doing what was asked. The window is not theoretical:
    // the daemon is launched on demand and respawned only after an
    // *unsuccessful* exit, so replacing the app bundle in place restarts
    // nothing, and the old daemon serves until the Mac reboots.
    //
    // The two directions cost differently, and neither is free:
    //
    //  - `wakeMode` is lost UPWARDS. A client asking for `.system` or
    //    `.systemAndDisplay` against an old daemon gets clamshell behaviour — a lid
    //    that will not let the Mac sleep, which is the axis that persists
    //    across reboots. Over-application, not under-.
    //  - `keepsDisksAwake` is lost DOWNWARDS. A client asking to hold disks
    //    awake gets a session that does not, and nothing says so.
    //
    // **This cannot be prevented from the encoding side.** `startSession`
    // carries an opaque JSON blob, and an older daemon's decoder ignores keys
    // it does not know *by construction* — so the only lever is to break a key
    // it does decode. That is what `TriggerRule` does for its own field, and it
    // does not transfer: `kind` could be poisoned into an unknown form so an old
    // daemon throws, but conditioning one key's wire form on another field's
    // value is a wart every future daemon must carry forever, and the user gets
    // "invalid session payload" rather than a reason.
    //
    // So it is detected instead, on the client, after the fact:
    // `SessionPowerSkew` (Shared/SessionPowerSkew.swift) compares the request
    // against the session `listSessions` reports back, which needs no new
    // protocol surface — the property that matters, because adding a verb an
    // old daemon lacks does not merely fail, it tears the connection down and
    // ends the caller's `clientBound` sessions.
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
        keepsDisksAwake = try container.decodeIfPresent(Bool.self, forKey: .keepsDisksAwake) ?? false
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
    ///   `origin`, `triggerID`, `wakeMode`, and `keepsDisksAwake`. These are the
    ///   request: what the caller wants, which the daemon then admits or rejects
    ///   on its own terms (`SessionAdmission`) but does not silently rewrite.
    ///   The two power axes are here and not above because how a session keeps
    ///   the Mac awake is the caller's business, exactly like when it ends —
    ///   there is nothing a caller can select on either axis that would let it
    ///   affect another client's session, since the daemon unions every live
    ///   session's request itself (`PowerPlan.reduce`).
    ///
    /// This lives in `Shared/` for the same reason `SessionTable.desiredPowerPlan`
    /// does: `Helper/` is not reachable from the test target, so anything left
    /// there is verified by reading alone — and this is the most
    /// security-relevant line in `HelperService.startSession`, and was for a long
    /// time the same silent-default trap as `renewed(until:)` above. Omitting
    /// `wakeMode:` from the rebuild is exactly what made every session in
    /// production a clamshell session no matter what any client asked for, and it
    /// did not fail to compile. It would now: no parameter of `Session.init` has
    /// a default. `SessionTests` covers the split directly on top of that, with
    /// whole-struct comparisons rather than a hand-written field list, because
    /// the compiler can force a field to be *named* here but not to be named
    /// with the value the client sent.
    func authorized(id: UUID, owner: ClientID, ownerUID: UInt32, startedAt: Date) -> Session {
        Session(id: id, kind: kind, owner: owner, ownerUID: ownerUID,
                persistence: persistence, origin: origin, startedAt: startedAt,
                triggerID: triggerID, wakeMode: wakeMode, keepsDisksAwake: keepsDisksAwake)
    }
}

// MARK: - "This user's own trigger rule started this session"

extension Session {
    /// **The two-clause-plus-origin predicate, written once**, and now the
    /// hinge of an *authorisation* decision rather than only of a menu row.
    ///
    /// ## Why it is here, in `Shared/`, and no longer in `Sources/`
    ///
    /// It used to live beside `menuSessionGroup` in `Sources/SessionDisplay.swift`,
    /// defined *as* that grouping, on the stated argument that "nothing in the
    /// daemon, the CLI or the agent asks this question". Plan 8 Task 5 made that
    /// false: spec §4's one exception is that the menu-bar app may **stop** a
    /// session this same user's own trigger rules started, and the place that
    /// exception has to be enforced is `SessionIsolation.authorize`, inside the
    /// root daemon — which cannot see `Sources/` at all (`project.yml`: the
    /// helper target compiles `Helper` + `Shared`).
    ///
    /// So the definition moved down rather than being copied across, and the
    /// direction of the weld flipped with it: `menuSessionGroup` now asks *this*,
    /// where this used to ask the group. The alternative was two hand-written
    /// copies of a security predicate — one deciding which row gets a button and
    /// one deciding whether the daemon honours the click — which is precisely the
    /// pair that drifts, because the copy that gets loosened first is always the
    /// one whose file never mentions the other.
    ///
    /// ## Why all three clauses
    ///
    /// * `ownerUID == userID` — the account boundary. Nothing here may ever
    ///   cross it. It is not redundant with the owner comparison below, though
    ///   it looks it: the daemon stamps both fields from one connection, so they
    ///   agree for every session it started, but a `Session` is JSON off the
    ///   wire and the pair *can* arrive disagreeing. That case has a name
    ///   (`MenuSessionGroup.yoursOtherClient`) and is refused here.
    /// * `owner == agent-<uid>` — **the unforgeable half.** The daemon stamps
    ///   `owner` from the listener that accepted the connection
    ///   (`ClientRole.clientID(forUserID:)`), and only the agent can connect on
    ///   the agent's Mach service.
    /// * `origin == .trigger` — the honest half, and the one nothing verifies:
    ///   `HelperProtocol.startSession` documents `origin` as *client-chosen* and
    ///   passes it through untouched. Asked on its own it would mean any client
    ///   of this user could opt its own sessions into being stoppable by the app
    ///   simply by setting a field, so it is never asked on its own.
    func startedByTrigger(forUserID userID: UInt32) -> Bool {
        ownerUID == userID
            && owner == ClientRole.agent.clientID(forUserID: userID)
            && origin == .trigger
    }
}
