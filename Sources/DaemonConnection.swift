import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

// `ContinuationLatch` — the "resume exactly once, from the reply block or the
// error handler, whichever arrives" primitive this file's `call` depends on —
// now lives in `Shared/ContinuationLatch.swift`, because `Agent`'s parallel
// XPC client needs the identical guarantee and the two must not drift. See
// that file for why.

@MainActor
final class DaemonConnection: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var keepingAwake = false
    @Published private(set) var isConnected = false

    /// **The one line the menu shows when a power request did not fully land**,
    /// and there are now three ways that happens. `nil` whenever everything was
    /// honoured, which is every request against a matching daemon.
    ///
    /// 1. The daemon admitted a *start* that does not carry what was asked for
    ///    (`SessionPowerSkew`, an older daemon's decoder dropping a key).
    /// 2. The daemon is too old to be asked to *change* a running session at all
    ///    (`ChangeSessionPowerGate` refused, so nothing was sent).
    /// 3. The daemon was asked and said no — the machine would not enter that
    ///    state, and it rolled the session back.
    ///
    /// One property and one menu line rather than three, because they are one
    /// thing to a person reading it: *the power request you made is not what is
    /// in force, and here is why*. Two of the three even share a remedy
    /// (`SessionPowerSkew.olderDaemonRemedy`). Three published notes would be
    /// three lines that could appear at once in a menu rebuilt to carry less.
    ///
    /// Recomputed on every request, and cleared when the last session this app
    /// knows about goes away, because every sentence it can hold is about a
    /// *live* session and would otherwise outlive the thing it describes.
    @Published private(set) var powerRequestNote: String?

    private var connection: NSXPCConnection?
    private var pollTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    /// Matches the poll interval below rather than the agent's 5s: the agent
    /// is a headless observer where a slightly later retry costs nothing,
    /// whereas here the poll timer is what actually re-populates the UI, so
    /// aligning the two means a daemon restart heals within roughly one
    /// refresh cycle instead of straddling two.
    private let reconnectDelay: TimeInterval = 3
    private let pollInterval: TimeInterval = 3

    /// How long a single XPC call may wait before the daemon is treated as
    /// unreachable. Generous against a local round-trip (normally well under
    /// a millisecond) while still bounding the damage from an unresponsive
    /// daemon: each stuck call now ends after this, instead of pinning a
    /// task forever. Longer than `pollInterval`, so two polls can briefly
    /// overlap while one is timing out — harmless, since `refresh()` only
    /// assigns published state and the latch makes each call resume once.
    private static let callTimeout: Duration = .seconds(5)

    func start() {
        connect()
        // Refresh immediately: `Timer.scheduledTimer` does not fire on
        // schedule, so without this the menu shows its default empty state
        // for a full poll interval after launch.
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func connect() {
        // `helperMachServiceName` is now the APP-ONLY service (its pinned
        // requirement narrowed to the app's bundle identifier alone when the
        // CLI moved to its own service); both the service and the pinned
        // requirement here are deliberately unchanged.
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            // Pins the PEER (the daemon), not this process's own identity —
            // `setCodeSigningRequirement` validates the other end of the
            // connection. The daemon's *inbound* requirement for this service
            // (`SigningRequirement.appRequirement`) deliberately excludes the
            // daemon's own identifier, so pinning an inbound requirement here
            // would reject the daemon on the first real message.
            new.setCodeSigningRequirement(SigningRequirement.helperRequirement)
        }
        // Both handlers capture the connection they belong to, so a late
        // callback from a connection we already replaced can never tear down
        // the live one.
        new.invalidationHandler = { [weak self, weak new] in
            Task { @MainActor in self?.handleDisconnect(new) }
        }
        new.interruptionHandler = { [weak self, weak new] in
            Task { @MainActor in self?.handleDisconnect(new) }
        }
        new.resume()
        connection = new
    }

    /// Tears down `failed` and schedules a reconnect. Idempotent and scoped:
    /// invalidation, interruption, and a mid-call XPC error can all report
    /// the same break, and only the first one to arrive does the work.
    ///
    /// Without the reconnect the app was permanently dead after a daemon
    /// restart — `isConnected` went false and nothing ever rebuilt the
    /// connection (final whole-branch review, Item 2).
    private func handleDisconnect(_ failed: NSXPCConnection?) {
        guard let current = connection, current === failed else { return }
        connection = nil
        isConnected = false
        // Interruption leaves the connection object alive; dropping the
        // reference without invalidating would leak it. Invalidating may
        // re-enter this method via `invalidationHandler`, which the guard
        // above already makes a no-op.
        current.invalidate()

        let delay = reconnectDelay
        appLogger.log("Daemon connection lost; reconnecting shortly")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// Thin wrapper over `xpcCall` (Shared/XPCCall.swift), which owns the
    /// resume-exactly-once and timeout mechanics both XPC clients need. What
    /// stays here is the part that is genuinely this client's: turning a
    /// failed call into a disconnect, and treating a real reply as the only
    /// positive evidence the connection is live —
    /// `remoteObjectProxyWithErrorHandler` hands back a proxy quite happily
    /// for a connection that is about to fail.
    private func call<T>(
        _ send: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T? {
        guard let connection else {
            isConnected = false
            return nil
        }

        let result: T? = await xpcCall(on: connection, timeout: Self.callTimeout,
                                       logger: appLogger, send)

        if result == nil {
            handleDisconnect(connection)
        } else {
            isConnected = true
        }
        return result
    }

    func refresh() async {
        guard let state: Bool = await call({ proxy, reply in
            proxy.currentState { reply($0) }
        }) else { return }
        keepingAwake = state

        guard let list: [Session] = await call({ proxy, reply in
            proxy.listSessions { data, _ in
                guard let data, let decoded = try? JSONDecoder().decode([Session].self, from: data) else {
                    // The reply arrived, so the connection is live — an
                    // undecodable payload is an empty list, not a
                    // disconnection.
                    return reply([])
                }
                reply(decoded)
            }
        }) else { return }
        sessions = list
        // The note describes a session that is running now. Once nothing is
        // running it is stale, and a stale explanation on an idle menu is worse
        // than none.
        if list.isEmpty { powerRequestNote = nil }
    }

    /// The `Session` this app asks the daemon to start — the *request*, whose
    /// `id`, `owner`, `ownerUID` and `startedAt` the daemon overwrites
    /// server-side (`Session.authorized(id:owner:ownerUID:startedAt:)`), and
    /// whose remaining fields are the actual ask.
    ///
    /// It is a separate, testable function rather than four lines inside
    /// `startSession` for one reason: `wakeMode` used to be one of exactly three
    /// `Session` fields with a memberwise default, so omitting it from a
    /// construction site was not a compile error — it silently substituted
    /// `.clamshell`. That omission *was* here, which is why every session this
    /// app started ignored the mode entirely, and the identical omission was
    /// made and fixed twice more on two other lines (`SessionEngine`'s lease
    /// renewal, `HelperService`'s trust split). `Session.init` no longer defaults
    /// anything, so that particular omission is now a compile error everywhere —
    /// but this function stays, because the compiler can force a field to be
    /// *named* and cannot force it to be named with the value the caller asked
    /// for, which is what `DaemonConnectionRequestTests` checks.
    nonisolated static func requestedSession(
        kind: SessionKind, power: PowerRequest,
        persistence: SessionPersistence, origin: SessionOrigin, now: Date = Date()
    ) -> Session {
        // `ownerUID: 0` and the `nil` trigger id are the request's placeholders:
        // the daemon overwrites the first server-side and this app never starts
        // a trigger-originated session.
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "app"), ownerUID: 0,
                persistence: persistence, origin: origin, startedAt: now,
                triggerID: nil, wakeMode: power.wakeMode,
                keepsDisksAwake: power.keepsDisksAwake)
    }

    /// `power` has **no default**, unlike `persistence` and `origin`, and that
    /// asymmetry is deliberate: the two defaulted parameters are visible in the
    /// UI if they are wrong, whereas a session that quietly stopped being
    /// lid-safe — or quietly started holding every attached disk out of idle —
    /// looks exactly like one that did not.
    ///
    /// One `PowerRequest` rather than a parameter per axis, for the reason
    /// `PowerPlan.reduce` takes one: a caller cannot supply half of it.
    @discardableResult
    func startSession(kind: SessionKind, power: PowerRequest,
                      persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual) async -> Bool {
        let session = Self.requestedSession(kind: kind, power: power,
                                            persistence: persistence, origin: origin)
        guard let data = try? JSONEncoder().encode(session) else { return false }
        // The id, not just "did it work". It is what lets the refresh below
        // find *this* session among everyone's and check what the daemon
        // actually admitted, which is the only way this app can see a request
        // an older daemon dropped on the wire (`SessionPowerSkew`).
        let startedID: String?? = await call { proxy, reply in
            proxy.startSession(data) { sessionID, error in
                if let error { appLogger.error("startSession failed: \(error)") }
                reply(sessionID)
            }
        }
        // The refresh that was already here — the read-back costs no extra
        // round trip, it just stops throwing away the one already being made.
        await refresh()
        guard let admittedID = startedID.flatMap({ $0 }) else { return false }
        noteSkew(requested: power, admittedID: admittedID)
        return true
    }

    /// Compares what was asked for against the session the daemon admitted,
    /// and records the sentence if they differ.
    ///
    /// A missing session is deliberately *not* a note. Between the reply and
    /// the refresh a very short session can legitimately have ended, and a
    /// message blaming the daemon's vintage for that would be wrong in the one
    /// direction that erodes trust in every other message this app shows.
    private func noteSkew(requested: PowerRequest, admittedID: String) {
        guard let id = UUID(uuidString: admittedID),
              let admitted = sessions.first(where: { $0.id == id }) else { return }
        powerRequestNote = SessionPowerSkew.note(requested: requested, admitted: admitted.power)
        if let powerRequestNote {
            appLogger.error("Daemon dropped part of the power request: \(powerRequestNote)")
        }
    }

    func stopSession(_ id: UUID) async {
        let _: Bool? = await call { proxy, reply in
            proxy.stopSession(id.uuidString) { ok, _ in reply(ok) }
        }
        await refresh()
    }

    /// Answers how many sessions were actually stopped.
    ///
    /// `@discardableResult` because the menu and the hot key both stop and then
    /// look at the refreshed list rather than a count; the count is here for
    /// the Shortcut, which has no list to look at and has to say something.
    /// Nil — the daemon never answered — is reported as 0 rather than guessed
    /// upward, for `ConditionReading`'s reason: a number nobody measured is
    /// worse than an admission.
    @discardableResult
    func stopAllSessions(all: Bool) async -> Int {
        let stopped: Int? = await call { proxy, reply in
            proxy.stopAllSessions(all: all) { stopped, _ in reply(stopped) }
        }
        await refresh()
        return stopped ?? 0
    }

    /// Changes what a **running** session asks of this Mac, and reports whether
    /// the daemon did it.
    ///
    /// `power` is a whole `PowerRequest` with no default, exactly like
    /// `startSession(kind:power:)` above and for the identical reason: this verb
    /// sets the session's whole request, so a caller that supplied one axis
    /// would be silently resetting the other.
    ///
    /// **The gate is `ChangeSessionPowerGate`, and it is passed before anything
    /// is sent** — see that type for what it can and cannot protect. What is
    /// here is the sequencing: at most one version probe per process, then at
    /// most one send, and a refusal turned into a sentence rather than into
    /// silence. A menu row that did nothing and said nothing would be the
    /// "button that silently does nothing" this menu was rebuilt to remove.
    @discardableResult
    func changeSessionPower(of sessionID: UUID, to power: PowerRequest) async -> Bool {
        switch ChangeSessionPowerGate.nextStep(support: ChangeSessionPowerGate.support) {
        case .refuse:
            powerRequestNote = menuPowerChangeUnavailableNote
            return false
        case .askTheVersionFirst:
            // Safe to send to any daemon: `version(reply:)` has existed since v2
            // and the daemon serving this Mac answers it. This is the only
            // probe, it happens at most once per process, and its answer is
            // latched below whichever way it goes.
            let reply = await version()
            ChangeSessionPowerGate.record(
                DaemonCapability.supports(.changeSessionPower, versionReply: reply)
                    ? .present : .absent)
            guard case .send = ChangeSessionPowerGate.nextStep(
                support: ChangeSessionPowerGate.support) else {
                powerRequestNote = menuPowerChangeUnavailableNote
                return false
            }
        case .send:
            break
        }

        guard let payload = try? JSONEncoder().encode(power) else { return false }
        let changed: Bool? = await call { proxy, reply in
            proxy.changeSessionPower(sessionID.uuidString, powerJSON: payload) { ok, error in
                if let error { appLogger.error("changeSessionPower failed: \(error)") }
                reply(ok)
            }
        }
        // Refresh either way: on success the menu has to show the new mode, and
        // on failure it has to go on showing the old one — which is what the
        // daemon left running, since a refused change is rolled back there
        // (`DaemonRuntime.changeSessionPower`).
        await refresh()
        guard let changed else {
            // **Latched on failure, not on having asked** (Task 1's R1.2), for
            // `recentSafetyStops()`'s reason: a failed call is what a missing
            // verb looks like from here, and there is no reply to tell it apart
            // from a daemon that merely went away.
            ChangeSessionPowerGate.record(.absent)
            powerRequestNote = menuPowerChangeUnavailableNote
            return false
        }
        if !changed { powerRequestNote = menuPowerChangeRefusedNote }
        return changed
    }

    /// The daemon's version, or `nil` if it did not answer.
    ///
    /// **`nil` is the whole of "not connected", and deliberately so.** The
    /// Diagnostics section could have read `isConnected` instead, but that flag
    /// is whatever the last poll left behind up to three seconds ago, whereas a
    /// reply here is a round trip that completed at the moment the pane asked —
    /// which is the same rule `call` above already follows, for the same reason:
    /// `remoteObjectProxyWithErrorHandler` hands back a proxy quite happily for
    /// a connection that is about to fail. One call, one fact, no second state
    /// to keep in step.
    ///
    /// The first production caller of `HelperProtocol.version(reply:)`, which
    /// was declared and implemented in v2 and called by nobody for four plans.
    /// Deliberately the *only* verb this app's Diagnostics pane reaches for:
    /// it takes no argument, touches no session, and cannot change what this
    /// Mac does.
    func version() async -> String? {
        await call { proxy, reply in proxy.version { reply($0) } }
    }

    /// Why this user's sessions were stopped, if a safety guard stopped them
    /// and if this daemon can say so. `[]` means **"no reason available"** and
    /// never "no guard fired" — every caller has to treat the two as the same
    /// answer, which is the honesty rule `sessionNotificationCopy` is built on.
    ///
    /// **Every gate this passes through is in `SafetyStopVerbGate`**, including
    /// why they are in the order they are. What is here is the sequencing: at
    /// most one version probe, then at most one send, and a failure latched so
    /// this process never asks again.
    ///
    /// It is `async` and returns a value rather than publishing one, and that
    /// is deliberate: a published property would need a producer, and the only
    /// producer available is the poll — which is the one thing Task 1's finding
    /// forbids for this verb.
    func recentSafetyStops() async -> [SafetyStopRecord] {
        switch SafetyStopVerbGate.nextStep(support: SafetyStopVerbGate.support,
                                           liveSessionsOfThisUser: liveSessionsOfThisUser) {
        case .refuse:
            return []
        case .askTheVersionFirst:
            // Safe to send to any daemon: `version(reply:)` has existed since
            // v2 and the daemon serving this Mac answers it. This is the only
            // probe, it happens at most once per process, and its answer is
            // latched below whichever way it goes.
            let reply = await version()
            SafetyStopVerbGate.record(
                DaemonCapability.supports(.recentSafetyStops, versionReply: reply)
                    ? .present : .absent)
            // Decided again rather than recursed, and not merely for style: the
            // probe above suspended, so the session count that cleared the gate
            // a moment ago is no longer known to be zero. One re-decision, and
            // `.askTheVersionFirst` is now unreachable because the latch is set.
            guard case .send = SafetyStopVerbGate.nextStep(
                support: SafetyStopVerbGate.support,
                liveSessionsOfThisUser: liveSessionsOfThisUser) else { return [] }
        case .send:
            break
        }

        let records: [SafetyStopRecord]? = await call { proxy, reply in
            proxy.recentSafetyStops { data, _ in
                guard let data,
                      let decoded = try? JSONDecoder().decode([SafetyStopRecord].self, from: data)
                else {
                    // The reply arrived, so the daemon does implement the verb
                    // and the connection is live — an undecodable payload is an
                    // empty list, exactly as in `refresh()`, and must not be
                    // mistaken for the verb being absent.
                    return reply([])
                }
                reply(decoded)
            }
        }
        guard let records else {
            // **Latched on failure, not on having asked** (Task 1, R1.2). A
            // failed call is what a missing verb looks like from here — there
            // is no reply to distinguish it from a daemon that merely went
            // away, and `handleDisconnect` has already run either way.
            //
            // A transient failure therefore disables this sentence for the rest
            // of the process, and that is the intended trade rather than an
            // oversight: being wrong this way costs one explanation the app
            // would have liked to give, and being wrong the other way costs the
            // user every session they own, on every subsequent attempt.
            SafetyStopVerbGate.record(.absent)
            return []
        }
        return records
    }

    /// Sessions belonging to this user — the set a connection teardown could
    /// cost, over-counted on purpose.
    ///
    /// What `DaemonRuntime.clientDisconnected` would actually end is narrower:
    /// the `clientBound` sessions owned by `app-<uid>`. Filtering by uid instead
    /// of by owner counts this user's CLI and trigger sessions too, so the gate
    /// refuses in strictly more situations than it has to. That is the correct
    /// direction to be imprecise in, and it costs nothing: the only caller asks
    /// at the moment the notification tracker has just observed this user's last
    /// session end, so this is zero exactly when it matters.
    private var liveSessionsOfThisUser: Int {
        let me = UInt32(getuid())
        return sessions.filter { $0.ownerUID == me }.count
    }
}

// MARK: - The gate in front of the one verb an old daemon may not have

/// **When this app may send `recentSafetyStops`, and the per-process memory of
/// whether it ever may again.**
///
/// Task 1 measured that sending a verb an old daemon does not implement
/// invalidates the connection *server-side*, which ends every `clientBound`
/// session the caller owns (`Tests/UnimplementedVerbProbeTests.swift`). The
/// daemon serving this Mac predates every field Plans 4-8 have added, so this
/// is a live condition, not a hypothetical. Three protections, and the order
/// they are checked in is part of the design:
///
/// 1. **Never polled.** There is no timer anywhere near this. The only caller
///    is the notification path, which asks only when it has an ending in hand
///    that it is about to describe — at most a handful of times in a login
///    session, and never at all for a user who has not switched the toggle on.
///    This is Task 1's R1.1, and it is the protection that cannot be got wrong
///    by a later change to this file, because it is the absence of a caller.
///
/// 2. **Only while this user owns no live sessions** — checked *first*, before
///    the version gate, precisely because it is the one that holds even if the
///    version gate is wrong. It is structural rather than heuristic: the caller
///    asks exactly when `SessionNotificationTracker` has observed that this
///    user's last session ended, so the set a teardown could destroy is empty
///    by construction at the moment the question is asked. If that ever stops
///    being true, this refuses instead of costing somebody an eight-hour job
///    (Task 1's R1.5).
///
/// 3. **A version gate, probed once and latched.** `DaemonCapability` owns the
///    reasoning, including why it is sound and why it is not sufficient alone.
///
/// ## Why the latch is `static`
///
/// Task 1's R1.2, which is unusually specific: *a per-connection latch is not
/// sufficient*, because the `NSXPCConnection` is rebuilt after every failure
/// (`reconnectDelay`, 3s) and a latch scoped to one would re-arm on every
/// reconnect — reproducing the polling hazard at reconnect cadence.
///
/// A stored property on `DaemonConnection` would in fact survive that, since
/// `connect()` replaces the connection and not the object, and `AppDelegate`
/// builds exactly one. It is `static` anyway, because "this happens to be a
/// singleton today" is not the same guarantee as "there is one of these", and
/// the failure mode of getting it wrong is measured in other people's sessions.
/// Being process-wide is also *what the fact is*: whether the daemon on this
/// Mac implements a verb is not a property of a connection.
@MainActor
enum SafetyStopVerbGate {
    /// What is known about the daemon's ability to answer. Starts `.unknown`
    /// once per process; `.absent` is terminal.
    enum Support: Equatable {
        case unknown
        case present
        case absent
    }

    /// What to do next, given both facts.
    enum Step: Equatable {
        case askTheVersionFirst
        case send
        case refuse(Refusal)
    }

    /// Why not — kept distinct rather than collapsed to a `Bool`, so a test can
    /// tell "this daemon cannot answer" from "now is not the moment to ask",
    /// which are different bugs with different fixes.
    enum Refusal: Equatable {
        case sessionsAreStillLive
        case daemonCannotAnswer
    }

    private(set) static var support: Support = .unknown

    /// Records what was learned. `.absent` is one-way: nothing this process
    /// observes later can talk it back into asking, which is the difference
    /// between one failed call and one per attempt for the rest of the session.
    static func record(_ learned: Support) {
        guard support != .absent else { return }
        support = learned
    }

    /// Test-only. Production has no path back to `.unknown` — see `record`.
    static func resetForTesting() { support = .unknown }

    /// Pure, so the whole decision is testable without an XPC connection —
    /// which matters here more than usual, because `DaemonConnection` builds
    /// its `NSXPCConnection` against a Mach service with no injection point, so
    /// the surrounding method is verifiable only by reading plus a build.
    static func nextStep(support: Support, liveSessionsOfThisUser: Int) -> Step {
        // First, and deliberately ahead of what is known about the daemon: this
        // is the check that makes a wrong answer from the version gate cost
        // nothing.
        guard liveSessionsOfThisUser == 0 else { return .refuse(.sessionsAreStillLive) }
        switch support {
        case .absent: return .refuse(.daemonCannotAnswer)
        case .unknown: return .askTheVersionFirst
        case .present: return .send
        }
    }
}

// MARK: - The gate in front of the *other* verb an old daemon may not have

/// **When this app may send `changeSessionPower`.**
///
/// A sibling of `SafetyStopVerbGate` above rather than a generalisation of it,
/// and the difference between them is the whole reason both exist:
///
/// * That gate has **three** protections. The load-bearing one is structural —
///   it refuses while this user owns any live session, so a wrong answer from
///   the version gate costs nothing at all.
/// * This one has **two**. That third protection is not merely unimplemented
///   here, it is *unavailable in principle*: this verb's entire purpose is to
///   act on a live session, so "refuse while a session is live" would refuse
///   every call there will ever be.
///
/// Folding the two into one type would mean either dropping that gate from the
/// verb that has it, or writing a flag that turns it off — and a flag that
/// disables the load-bearing protection is exactly the thing a later change
/// flips for the wrong verb. Each type names the protections its own verb has,
/// and the two rules that must not drift between them are shared where they
/// belong: `DaemonCapability` owns which build clears which verb, and Task 1's
/// "every uncertain answer means absent" is written there, once.
///
/// So what is left here carries the whole weight:
///
/// 1. **Never polled.** There is no timer near this. Its callers are a menu row
///    somebody clicked and a command somebody typed — at most a handful of times
///    in a login session, and none at all for a user who never has a session in
///    a mode worth promoting (the row does not appear otherwise). This is Task
///    1's R1.1, and it is the protection a later change to this file cannot get
///    wrong, because it is the absence of a caller.
/// 2. **A version gate, probed once and latched, and the latch is `static`.**
///    Task 1's R1.2: the `NSXPCConnection` is rebuilt 3 s after every failure,
///    so a latch scoped to one would re-arm on every reconnect and reproduce the
///    hazard at reconnect cadence. `.absent` is terminal.
///
/// **The residual risk, stated rather than buried**: `DaemonCapability`'s own
/// comment records that a build number orders releases but does not identify
/// source, so two local builds made without a bump share a number and this gate
/// can clear a daemon that predates the verb on a developer's machine. For the
/// other verb that is survivable because of gate 3. Here it is the whole
/// exposure, and what it would cost is this app's own `clientBound` sessions.
/// It is why `.changeSessionPower`'s build number was chosen against what is
/// *installed* rather than against what `project.yml` tracked.
@MainActor
enum ChangeSessionPowerGate {
    /// What is known about the daemon's ability to answer. Starts `.unknown`
    /// once per process; `.absent` is terminal.
    ///
    /// Its own type rather than `SafetyStopVerbGate.Support`, so that "what this
    /// process knows about verb A" and "…about verb B" cannot be assigned to
    /// each other by accident. They are different facts about the same daemon,
    /// and a daemon that has one verb and not the other is the ordinary state
    /// during exactly the upgrade window these gates are for.
    enum Support: Equatable {
        case unknown
        case present
        case absent
    }

    /// What to do next. No `Refusal` reasons: there is only one, which is that
    /// this daemon cannot answer — the other gate needs to tell two refusals
    /// apart precisely because it has a second one.
    enum Step: Equatable {
        case askTheVersionFirst
        case send
        case refuse
    }

    private(set) static var support: Support = .unknown

    /// Records what was learned. `.absent` is one-way: nothing this process
    /// observes later can talk it back into asking.
    static func record(_ learned: Support) {
        guard support != .absent else { return }
        support = learned
    }

    /// Test-only. Production has no path back to `.unknown` — see `record`.
    static func resetForTesting() { support = .unknown }

    /// Pure, so the decision is testable without an XPC connection —
    /// `DaemonConnection` builds its `NSXPCConnection` against a Mach service
    /// with no injection point, so the method around it is verifiable only by
    /// reading plus a build.
    static func nextStep(support: Support) -> Step {
        switch support {
        case .absent: return .refuse
        case .unknown: return .askTheVersionFirst
        case .present: return .send
        }
    }
}
