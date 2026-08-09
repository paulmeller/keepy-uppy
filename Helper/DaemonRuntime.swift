import Foundation
import os

let helperLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.helper", category: "daemon")

/// `DaemonRuntime.startSession`'s outcome, folding in `SessionAdmission`'s
/// rejection reasons (Fix 1 caps, Fix 3 "no live agent") plus the
/// pre-existing `PowerControl` failure path, which this method has always
/// surfaced to the caller (unlike `stopSession`/`conditionEnded`, which
/// don't gate their reply on it — starting a session that fails to actually
/// disable sleep is a real failure worth reporting).
enum SessionStartResult: Equatable {
    case started
    case ownerLimitReached
    case globalLimitReached
    case noAgentConnected
    case conditionNotMet
    case triggerSuppressed
    case failed
}

enum LeaseRenewalResult: Equatable {
    case renewed
    case notFound
    case forbidden
    case notLease
    case invalidDeadline
}

/// Serialises both engines behind one queue: XPC replies arrive on arbitrary
/// threads, and the engines are value types with no locking of their own.
final class DaemonRuntime {
    private let queue = DispatchQueue(label: "au.com.workwireless.keepy-uppy.helper.runtime")
    private var sessions = SessionEngine()
    /// Starts at `.default` and is replaced by the connected user's saved
    /// config on the first tick that has an agent to read for. It cannot be
    /// seeded from `SafetyConfigStore.load()` here: that reads the *calling*
    /// process's preference domain, and this process is root, so it would
    /// only ever return `.default` anyway — just less honestly (see
    /// `SafetyConfigStore.load(forUserID:)`). There is also nobody to read
    /// for yet at construction time; no agent has connected.
    private var safety = SafetyEngine(config: .default)
    /// The daemon's single, process-lifetime holder for **both** power
    /// mechanisms. Confined to `queue` exactly like the two engines above:
    /// `PowerPlanHolder` is explicitly not thread-safe, and the live
    /// `IOPMAssertionID`s it owns are the state that would leak if two
    /// threads converged it at once.
    ///
    /// One instance, created here, never replaced and never handed out —
    /// which is also the precondition its `deinit` documents for releasing
    /// assertions off-queue.
    private let power = PowerPlanHolder()
    private let observer: SafetyObserving
    private let bundlePath: String
    private var timer: DispatchSourceTimer?

    /// Per-user structural refcounts of *proven* open connections to the
    /// agent-only Mach service — proven meaning the peer has satisfied that
    /// service's code-signing requirement, evidenced by any message reaching
    /// `HelperService` (see `clientConnected`). Still tracks *connections*,
    /// not explicit `registerAsAgent` calls, matching how disappearance is
    /// already detected structurally in `HelperListenerDelegate` (a
    /// connection's agent-ness is fixed at accept time by which Mach service
    /// it came in on, not by anything the client asserts). Two problems share
    /// this map:
    ///   - Fix 3: an agent-evaluated session must not be startable when no
    ///     agent has ever connected (e.g. the LaunchAgent never loaded or
    ///     was never approved) — spec §5 only covers the agent
    ///     *disappearing*, not never arriving.
    ///   - Agents are per-user but share one Mach service. Counts are keyed
    ///     by the authenticated peer UID, matching `Session.ownerUID`, so a
    ///     logout ends exactly that user's agent-evaluated sessions without
    ///     disturbing or lending evidence to another login session.
    private var liveAgentConnectionsByUser: [UInt32: Int] = [:]

    /// Per-identity refcount of *proven* open connections (again: peers that
    /// have actually satisfied the accepting listener's requirement, not
    /// merely been accepted), keyed by the same stable `ClientID` that owns
    /// sessions (`ClientRole.clientID(forUserID:)`).
    ///
    /// Needed only because that identity became stable. While every accepted
    /// connection minted its own random `ClientID`, "this connection closed"
    /// and "this owner is gone" were the same statement, so
    /// `clientDisconnected` could end the owner's `clientBound` sessions
    /// outright. Now several live connections can legitimately share one
    /// identity — two overlapping `keepy-uppy` invocations, for instance —
    /// and the first teardown to run would otherwise end sessions belonging
    /// to a client that is still there. Only the last connection for an
    /// identity ends its sessions.
    ///
    /// Note this is *not* motivated by the menu-bar app's reconnect logic:
    /// `Sources/DaemonConnection.swift` invalidates the dead connection and
    /// only then waits before rebuilding, so its connections do not overlap
    /// and its `clientBound` sessions still end on a daemon restart — which
    /// is the intended behaviour, not a regression this refcount papers over.
    ///
    /// Deliberately separate from `liveAgentConnectionsByUser` above rather
    /// than folded into it: that one is keyed by uid (not identity), counts
    /// only agent-service connections, and gates a different thing entirely
    /// (whether agent-evaluated sessions may start, and when
    /// `agentDisappeared` fires). Merging them would silently change both.
    private var liveConnectionsByClient: [ClientID: Int] = [:]

    init(observer: SafetyObserving = SystemSafetyObserver(),
         bundlePath: String = Bundle.main.bundlePath) {
        self.observer = observer
        self.bundlePath = bundlePath
    }

    /// Converge to safe before serving anyone, so a daemon crash — or an
    /// upgrade from v1, which left disablesleep set persistently — cannot
    /// leave the Mac stranded awake.
    ///
    /// Two mechanisms, two separate calls, and deliberately *not* one
    /// `power.apply(.sleepAllowed)`, because the reason each needs doing is
    /// not the same reason:
    ///
    /// - `SleepDisabled` is why this method exists at all. It is global,
    ///   root-only, and survives both process death *and reboot*, so whatever
    ///   a previous incarnation of this daemon left set is still in force
    ///   right now, before we have applied anything. Only an unconditional
    ///   write repairs that, and only a direct one — this is the reconciling
    ///   write, not part of a plan, and its own success is worth a log line
    ///   of its own.
    /// - Assertions need no reconciliation whatsoever: they are per-process
    ///   and `powerd` reaps them when their holder dies (it logs it as
    ///   `ClientDied`), so a fresh process provably holds none. The release
    ///   below is therefore a no-op today. It stays because "converge to
    ///   safe" should be true of *both* axes by inspection — the reader's
    ///   obvious next question deserves a visible answer rather than a
    ///   silence that looks like an oversight.
    ///
    /// Folding them into one call would flatten exactly that asymmetry, and
    /// would disguise the one write that genuinely repairs persistent global
    /// state as ordinary bookkeeping.
    func start() {
        queue.sync {
            let ok = PowerControl.setSleepDisabled(false)
            helperLogger.log("Daemon start: forced sleep enabled, success=\(ok)")
            power.releaseAllAssertions()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tickLocked() }
        timer.resume()
        self.timer = timer
    }

    func startSession(_ session: Session) -> SessionStartResult {
        queue.sync {
            let now = Date()
            // Sweep expired sessions before evaluating admission (Fix 3a).
            // `SessionAdmission`'s per-owner/global caps are computed
            // against whatever is currently in the table; a rejection below
            // returns before `sessions.startSession` ever reaches `apply`,
            // which is otherwise the only place expiry gets swept. Without
            // this, an already-expired session keeps occupying a cap slot —
            // and keeps contributing its `WakeMode` to the plan `applyLocked`
            // holds the machine to — for up to 5s, until the next timer tick
            // catches it. `.tick` has no effect of its own
            // beyond the unconditional sweep `apply` always performs at the
            // end of every event.
            _ = sessions.apply(.tick, now: now)
            let powerSource = observer.batteryState().source
            let liveAgentConnections = liveAgentConnectionsByUser[session.ownerUID, default: 0]
            switch sessions.startSession(
                session, now: now,
                liveAgentConnections: liveAgentConnections,
                onACPower: powerSource == .acPower,
                triggersSuppressed: safety.triggersSuppressed) {
            case .admitted:
                guard applyLocked() else {
                    // Starting is transactional: never retain a session whose
                    // id the caller will not receive. Otherwise a later retry
                    // can turn a reported failure into an unmanageable live
                    // session, especially when it is detached.
                    //
                    // The gate is now the *whole* apply — both mechanisms —
                    // rather than `setSleepDisabled`'s return alone. That
                    // return was the entire story only while every session
                    // was a clamshell session; a `.system` session's promise
                    // is kept by an assertion that write knows nothing about,
                    // so keying off it would report success for a Mac free to
                    // idle-sleep. See `applyLocked` for why the conjunction,
                    // and why a `false` is always safe to destroy a session
                    // over.
                    //
                    // The re-apply below can itself fail (it converges the
                    // *remaining* sessions, which may want the very thing
                    // that just failed). Nothing better is available here:
                    // it logs, and the 5s tick keeps retrying. What matters
                    // is that the caller and the table now agree that this
                    // session does not exist.
                    _ = sessions.apply(.stop(id: session.id), now: now)
                    _ = applyLocked()
                    return .failed
                }
                return .started
            case .ownerLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): per-owner session cap (\(SessionAdmission.maxSessionsPerOwner)) reached")
                return .ownerLimitReached
            case .globalLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): session cap reached (global \(SessionAdmission.maxSessionsGlobal), detached sub-cap \(SessionAdmission.maxDetachedSessionsGlobal)); persistence=\(session.persistence.rawValue)")
                return .globalLimitReached
            case .noAgentConnected:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): kind requires a live agent connection to evaluate, and none is connected")
                return .noAgentConnected
            case .conditionNotMet:
                return .conditionNotMet
            case .triggerSuppressed:
                helperLogger.error("Rejected trigger-driven startSession from \(session.owner.rawValue): safety cooldown is active")
                return .triggerSuppressed
            }
        }
    }

    /// Ends a single session, but only if `requestedBy` owns it (Task 10
    /// isolation fix: this used to take a bare UUID and end any session
    /// regardless of owner). The authorization check and the mutation run
    /// inside the same `queue.sync`, so there is no window between "checked
    /// ownership" and "removed the session" for a concurrent call to widen.
    @discardableResult
    func stopSession(id: UUID, requestedBy: ClientID) -> SessionIsolation.Authorization {
        queue.sync {
            let authorization = SessionIsolation.authorize(sessionID: id, requestedBy: requestedBy, among: sessions.sessions)
            if authorization == .authorized {
                _ = sessions.apply(.stop(id: id), now: Date())
                _ = applyLocked()
            }
            return authorization
        }
    }

    /// Ends sessions on behalf of `requestedBy`: scoped to their own
    /// sessions unless `all` is set, in which case every client's sessions
    /// end (Task 10 isolation fix: this used to always end everyone's
    /// sessions, including a `detached` session another client started).
    /// Returns how many sessions were actually ended, so the caller can tell
    /// "stopped three" from "matched nothing". Replying with a bare `true`
    /// regardless is what let `keepy-uppy off` silently no-op for an entire
    /// release: every invocation minted a fresh `ClientID`, so the own-scoped
    /// filter never matched, and the command still exited 0 and printed
    /// nothing. The identity fix removes that cause; reporting the count
    /// removes the *silence*, so any future scoping mismatch says so out loud
    /// instead of looking like success.
    @discardableResult
    func stopAll(all: Bool, requestedBy: ClientID) -> Int {
        queue.sync {
            let ids = SessionIsolation.sessionsToStop(all: all, requestedBy: requestedBy, among: sessions.sessions)
            var stopped = 0
            for id in ids {
                // `apply` also returns anything swept for expiry in the same
                // pass, so match on the id to count only real stops.
                let ended = sessions.apply(.stop(id: id), now: Date())
                if ended.contains(where: { $0.id == id }) { stopped += 1 }
            }
            _ = applyLocked()
            return stopped
        }
    }

    /// `start()`'s converge-to-safe, run on the way **out**: end every session
    /// and force sleep back on, because the caller is about to unregister this
    /// daemon and nothing left on the machine would ever put the setting back.
    /// `DaemonRemoval` states the ordering rule; this is the half of it only
    /// root can perform.
    ///
    /// Three things about the shape, in the order a reader will ask them:
    ///
    /// - **The direct `setSleepDisabled(false)` is not redundant with the
    ///   `applyLocked()` above it, and cannot be folded into it.** `apply`
    ///   deliberately reports a refused *clear* as success: a setting that
    ///   stays on leaves the Mac awake for longer than asked, which is the one
    ///   direction that cannot lose a user's work, so it must never fail a
    ///   start. That is precisely the fact this method exists to learn, so it
    ///   makes the write itself, unconditionally. Same division of labour as
    ///   `start()`, for the same reason, read in the other direction.
    /// - **What it reports is the setting's state, not the write's return.**
    ///   Those are not the same claim, and reporting the second one locked the
    ///   caller out for good on a whole class of machine. `SleepDisabled` is
    ///   written through undeclared SPI, and "a machine where the undeclared
    ///   SPI refuses writes outright" is a case `PowerPlanHolder.apply` already
    ///   contemplates: there the clear returns `false` every single time, so
    ///   `reset` refused, every single time, promising a retry that could never
    ///   succeed — for a Mac the same SPI had also refused to set to `1`, and
    ///   which was therefore never held. So the reply comes from
    ///   `DaemonRemoval.sleepWasRestored`: the clear landed, or the setting
    ///   reads off. The read is the one `isKeepingAwake()` already makes.
    /// - **The assertion axis needs nothing extra here.** `applyLocked`
    ///   releases whatever the now-empty plan no longer wants, and `powerd`
    ///   reaps the rest the moment this process dies. Only the persistent axis
    ///   can outlive an eviction, so only it needs the belt-and-braces write.
    /// - **This does not stop the daemon.** It stays up and keeps ticking, and
    ///   would honour a session started a millisecond later; the caller's
    ///   `SMAppService.unregister()` is what ends it. Refusing new sessions in
    ///   that window would need a shutdown state this daemon does not have, and
    ///   the window is bounded by one synchronous call in the client. What such
    ///   a session can no longer do is *outlive* the window: `Helper/main.swift`
    ///   converges the persistent axis on SIGTERM, and SIGTERM is what the
    ///   eviction itself delivers — so the cost of losing that race is a Mac
    ///   held for the rest of one XPC call rather than for the rest of its life.
    func prepareForRemoval() -> (stopped: Int, sleepRestored: Bool) {
        queue.sync {
            let ended = sessions.apply(.stopAll, now: Date())
            _ = applyLocked()
            let wrote = PowerControl.setSleepDisabled(false)
            let restored = DaemonRemoval.sleepWasRestored(
                writeSucceeded: wrote, settingStillOn: PowerControl.sleepDisabled())
            helperLogger.log("Prepare for removal: ended \(ended.count) session(s), forced sleep enabled, write=\(wrote), restored=\(restored)")
            return (ended.count, restored)
        }
    }

    /// Renews a lease session's deadline. Ownership-checked exactly like
    /// `stopSession`, for the same reason: a lease belongs to the client
    /// that started it.
    @discardableResult
    func renewLease(id: UUID, until: Date, requestedBy: ClientID) -> LeaseRenewalResult {
        queue.sync {
            let now = Date()
            _ = sessions.apply(.tick, now: now)
            let authorization = SessionIsolation.authorize(sessionID: id, requestedBy: requestedBy, among: sessions.sessions)
            switch authorization {
            case .notFound: return .notFound
            case .forbidden: return .forbidden
            case .authorized: break
            }

            switch sessions.renewLease(id: id, until: until, now: now) {
            case .renewed:
                _ = applyLocked()
                return .renewed
            case .notFound:
                return .notFound
            case .notLease:
                return .notLease
            case .invalidDeadline:
                return .invalidDeadline
            }
        }
    }

    /// Bookkeeping only: disappearance handling is driven by the peer's
    /// structural role (which Mach service it connected to) in
    /// `HelperListenerDelegate`, not by this call, so a crash between
    /// registering and disconnecting can't leave a stale "who's the agent"
    /// flag here. This exists so the log shows who registered.
    func registerAgent(_ id: ClientID) {
        queue.sync {
            helperLogger.log("Agent connection registered: \(id.rawValue)")
        }
    }

    /// Call when a connection has *proven itself* — i.e. when its first
    /// message reaches `HelperService`, which XPC delivers only once the
    /// listener's code-signing requirement has been adjudicated in the peer's
    /// favour. Deliberately not at accept time: accepting is something any
    /// local process can provoke, so counting there let an unverified peer
    /// hold this count above zero and suppress the `clientBound` cleanup
    /// below.
    ///
    /// Must be paired with at most one `clientDisconnected` —
    /// `HelperListenerDelegate` enforces that with a one-shot latch
    /// (`ConnectionProofLatch`), since invalidation and interruption can both
    /// fire for the same connection, and a connection that was never proven
    /// must not decrement what it never incremented.
    func clientConnected(_ owner: ClientID) {
        queue.sync { liveConnectionsByClient[owner, default: 0] += 1 }
    }

    /// Call when a connection invalidates or is interrupted. Only the *last*
    /// live connection for this identity ends its `clientBound` sessions:
    /// with stable `ClientID`s, an overlapping second connection from the
    /// same client would otherwise have its sessions torn down when the
    /// first one closed. Modelled on `agentConnectionClosed` below, which
    /// solves the structurally identical problem for the agent refcount.
    func clientDisconnected(_ owner: ClientID) {
        queue.sync {
            guard Self.decrementToZero(&liveConnectionsByClient, key: owner) else { return }
            let ended = sessions.apply(.clientDisconnected(owner), now: Date())
            if !ended.isEmpty { helperLogger.log("Client \(owner.rawValue) left; ended \(ended.count) session(s)") }
            _ = applyLocked()
        }
    }

    /// Call when a connection to the agent Mach service has proven itself
    /// (Fixes 3 & 4) — same trigger, and same reason, as `clientConnected`
    /// above, and more load-bearing here: this count is the whole of the
    /// evidence behind `SessionAdmission`'s `noAgentConnected` check, so
    /// counting an unverified peer meant a rogue could make the daemon
    /// believe an agent was present when none was. Must be paired with at
    /// most one `agentConnectionClosed`.
    func agentConnectionOpened(userID: UInt32) {
        queue.sync { liveAgentConnectionsByUser[userID, default: 0] += 1 }
    }

    /// Call when a connection to the agent Mach service invalidates or is
    /// interrupted. Only the last live connection for this UID ends that
    /// user's agent-evaluated sessions.
    func agentConnectionClosed(userID: UInt32) {
        queue.sync {
            guard Self.decrementToZero(&liveAgentConnectionsByUser, key: userID) else { return }
            let ended = sessions.apply(.agentDisappeared(userID: userID), now: Date())
            if !ended.isEmpty {
                helperLogger.log("Last agent connection for uid \(userID) gone; ended \(ended.count) unverifiable session(s)")
            }
            _ = applyLocked()
        }
    }

    /// Ends a session on the agent's report, but only if its kind is one
    /// the agent has business judging — i.e. not daemon-evaluable (Fix 6).
    /// Rejection is logged by the caller (`HelperService`), matching how
    /// `stopSession`/`renewLease` rejections are logged there rather than
    /// here.
    @discardableResult
    func conditionEnded(id: UUID, reportedByUserID userID: UInt32) -> ConditionEndOutcome {
        queue.sync {
            let now = Date()
            // Same pre-sweep as `startSession`, and for the same reason
            // (Fix 3a): `endCondition`'s `.notFound`/`.notAgentEvaluated`
            // paths return before `apply` ever runs, so a *different*,
            // already-expired session sitting in the table — unrelated to
            // `id` — would otherwise keep counting toward the caps and toward
            // the power plan `applyLocked` applies, until the next tick.
            _ = sessions.apply(.tick, now: now)
            let outcome = sessions.endCondition(id: id, reportedByUserID: userID, now: now)
            if case .ended = outcome { _ = applyLocked() }
            return outcome
        }
    }

    func currentSessions() -> [Session] { queue.sync { sessions.sessions } }

    /// Whether the daemon is holding the Mac awake by **either** mechanism —
    /// what the menu bar's balloon and `keepy-uppy status` report.
    ///
    /// Reading `SleepDisabled` alone was the whole truth only while every
    /// session set it. It is not any more: a `.system` or `.systemAndDisplay`
    /// session is held entirely by assertions and deliberately leaves the
    /// global setting clear, so the old one-line answer would have started
    /// reporting "not keeping awake" with sessions live and the Mac genuinely
    /// held — a silent lie in the one place a user looks.
    ///
    /// The global read stays, and stays first, because it is a real read of
    /// real machine state (including anything a previous incarnation left
    /// behind). The assertion half can only be what *we asked for* — held
    /// assertions are advisory, so `pmset -g assertions` remains the truth
    /// about the machine and `heldTypes` the truth about our request. That
    /// weaker claim is still the right one here: this reports whether the
    /// daemon is keeping the Mac awake, not whether the kernel is obeying.
    func isKeepingAwake() -> Bool {
        queue.sync { PowerControl.sleepDisabled() || !power.heldTypes.isEmpty }
    }

    /// Drops one reference and reports whether that was the last one.
    ///
    /// Shared by both refcounts purely as arithmetic. It deliberately does
    /// *not* merge them: they stay keyed differently (identity vs. uid), over
    /// different domains, with different effects — a separation a security
    /// review settled explicitly. This is only the clamp-remove-report dance
    /// that was otherwise written out twice, where a future off-by-one would
    /// have had to be found and fixed in both copies.
    private static func decrementToZero<Key: Hashable>(_ counts: inout [Key: Int], key: Key) -> Bool {
        let remaining = max(0, counts[key, default: 0] - 1)
        if remaining == 0 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = remaining
        }
        return remaining == 0
    }

    // MARK: - Private, always called on `queue`

    private func tickLocked() {
        guard bundleStillExists() else {
            helperLogger.error("App bundle is gone; restoring sleep and exiting")
            // Same shape, and same reasoning, as `start()`'s converge-to-safe,
            // read in the other direction: the `SleepDisabled` write is the
            // one that matters, because it would otherwise outlive this
            // process and the reboot after it. The release is belt-and-braces
            // — `exit(0)` runs no deinits, but `powerd` reaps a dead client's
            // assertions anyway — and is here so that both axes are visibly
            // put back on the way out.
            _ = PowerControl.setSleepDisabled(false)
            power.releaseAllAssertions()
            exit(0)
        }

        let now = Date()
        _ = sessions.apply(.tick, now: now)

        // Pick up Settings → Safety changes. Whose settings? The lowest UID
        // with a live agent connection. That set is the right source because
        // a UID only appears in it once a code-signing-verified agent
        // connection was accepted for it — the same authenticated trust
        // boundary everything else here rests on — rather than whoever
        // happens to hold the console. `min()` rather than an arbitrary key
        // because `Dictionary` ordering is not stable across runs: with two
        // users logged in, taking "any" key would let the governing config
        // flap between them from tick to tick.
        //
        // Values are honoured exactly as written, with no server-side
        // clamping. Widening a safety boundary is already a visible,
        // deliberate choice in that tab (`ThermalSensitivity.off`), and any
        // admitted signed client can already start an `.indefinite` session
        // through it, so reading the config the user actually saved crosses
        // no trust boundary that was not already crossed.
        //
        // Nothing is reassigned when the read fails (no agent connected, no
        // saved config, unreadable): the last config that did load stays in
        // force, so a transient failure cannot quietly revert a user's
        // chosen safety settings to the defaults.
        if let userID = liveAgentConnectionsByUser.keys.min(),
           let freshConfig = SafetyConfigStore.load(forUserID: userID),
           freshConfig != safety.config {
            helperLogger.log("Safety config reloaded from uid \(userID)")
            safety.config = freshConfig
        }

        let battery = observer.batteryState()
        let onBattery = battery.source == .battery
        // Only a *confident* negative ends `.whileOnACPower` sessions. This
        // used to read `battery.source != .acPower`, which folded
        // `.unknown` — a failed IOKit read, not an observation of anything —
        // in with "unplugged", so one hiccup in
        // `IOPSCopyPowerSourcesInfo`/`IOPSCopyPowerSourcesList` ended every
        // AC-bound session and let the Mac sleep while still plugged in. See
        // `PowerSource.acPowerReading` and `ConditionReading` for the rule;
        // this was the last observer in the codebase still collapsing
        // "I don't know" into "no".
        //
        // Note the deliberate asymmetry with `startSession`'s admission
        // check above, which still passes `onACPower: powerSource ==
        // .acPower` and so *refuses* to start a `.whileOnACPower` session on
        // an unknown reading. Refusing to start returns a visible
        // `.conditionNotMet` the caller can retry in five seconds; ending
        // silently sleeps a Mac mid-build. Same asymmetry, same argument, as
        // `SessionEvidence.negativesBeforeEnding`.
        if battery.source.acPowerReading.isConfidentlyAbsent {
            let ended = sessions.apply(.acPowerDisconnected, now: now)
            if !ended.isEmpty {
                helperLogger.log("AC power unavailable; ended \(ended.count) AC-bound session(s)")
            }
        }

        let oldest = sessions.sessions.map { now.timeIntervalSince($0.startedAt) }.max()
        let outcome = safety.evaluate(SafetyInputs(
            thermal: observer.thermalLevel(),
            batteryPercentage: battery.percentage,
            onBattery: onBattery,
            lidClosed: observer.isLidClosed(),
            oldestSessionAge: oldest,
            now: now))

        switch outcome {
        case .none:
            break
        case .warn(let reason, let actAt):
            helperLogger.log("Safety warning: \(reason.rawValue), acting at \(actAt)")
        case .stopAll(let reason):
            let ended = sessions.apply(.stopAll, now: now)
            helperLogger.error("Safety stop (\(reason.rawValue)); ended \(ended.count) session(s)")
        }

        _ = applyLocked()
    }

    private func bundleStillExists() -> Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }

    /// Converge the machine onto whatever the live session table now asks
    /// for. One call, both mechanisms: `sessions.desiredPowerPlan` is the
    /// pure reduction (`Shared/SessionTable.swift`) and
    /// `PowerPlanHolder.apply` establishes both of its axes.
    ///
    /// ## What "the apply failed" means, now that there are two mechanisms
    ///
    /// It means **the holder could not establish everything the plan asked
    /// for, on either axis.** The conjunction — not "the important half
    /// worked", not "at least something is held". Three reasons, in order of
    /// weight:
    ///
    /// 1. **The axes cover disjoint sleep paths, so neither stands in for the
    ///    other.** Assertions prevent *idle* sleep and demonstrably do not
    ///    survive a lid close (15 of 15 observed clamshell sleeps happened
    ///    with sleep-preventing assertions live — see
    ///    `power-assertion-research.md` Q4). `SleepDisabled` is the only
    ///    thing that survives a shut lid, and is the only mechanism a
    ///    `.clamshell` session's promise rests on. So a partial apply is not
    ///    "weaker protection": it is *no* protection against whichever path
    ///    failed. A `.system` session whose assertion was refused idle-sleeps;
    ///    a `.clamshell` session whose `SleepDisabled` write was refused
    ///    sleeps the moment the lid shuts. Either is exactly the state this
    ///    daemon must never be in — believing a session is live while the Mac
    ///    is free to sleep.
    ///
    /// 2. **A `false` from the holder means under-application, and the holder
    ///    guarantees that by construction.** It is not a property of the two
    ///    mechanisms — either write can fail in either direction — it is a
    ///    property `PowerPlanHolder.apply` establishes deliberately, by
    ///    returning `true` for every failure in the *weakening* direction on
    ///    both axes: a failed release (the id is dropped regardless, so there
    ///    is nothing left to retry) and a failed write of `sleepDisabled:
    ///    false` (the setting stays on, and the next apply rewrites it). Both
    ///    residues leave the Mac awake longer than asked. So the only ways to
    ///    see `false` are a create that did not happen and a `sleepDisabled:
    ///    true` write that did not land — both "we hold less than we
    ///    promised". That one-directionality is what makes `false` safe for
    ///    `startSession` to *destroy a session* over: the failure can never
    ///    have been "too awake". Anything that later reports a
    ///    release-or-clear failure through this `Bool` breaks the invariant
    ///    this gate rests on, and would start destroying sessions over a Mac
    ///    that is merely awake for too long.
    ///
    /// 3. **Self-healing is real but too slow to soften the gate with.** The
    ///    holder retries whatever it is not holding, and rewrites the setting,
    ///    on every apply — so both axes do recover. But the next apply is up
    ///    to five seconds away, and a Mac that idle-sleeps inside that window
    ///    has already lost the work the session existed to protect. Handing
    ///    back a session id is a promise about *now*, so it is made only when
    ///    the machine is in the requested state now.
    ///
    /// The much-discussed asymmetry between the mechanisms therefore lives in
    /// *recovery*, not in this predicate. An unheld assertion is knowable —
    /// `held[type] == nil` is literally the retry queue — while the true value
    /// of `SleepDisabled` is never re-read and is repaired only by being
    /// blindly rewritten on every apply, plus `start()`'s converge-to-safe for
    /// the case where no apply is ever coming because the process died. Both
    /// are best-effort *afterwards*; neither is a reason to call a failed
    /// apply a success *now*.
    ///
    /// Only `startSession` reads the result, as before. Every other caller is
    /// converging *after* sessions ended, where a failure means the Mac stays
    /// awake longer than asked and the next tick retries — the same
    /// discarded-result behaviour those paths have always had, except that it
    /// is no longer silent.
    @discardableResult
    private func applyLocked() -> Bool {
        let plan = sessions.desiredPowerPlan
        guard power.apply(plan) else {
            // Scalars only: `Logger` redacts interpolated strings by default,
            // and this line is worth nothing if it reads `<private>`. Which
            // mechanism failed, and why, is already logged by `PowerPlanHolder`
            // (`powerLogger`); what this adds is the session context that
            // explains what was being promised at the time.
            let live = sessions.sessions.count
            helperLogger.error("Power apply FAILED: \(live) live session(s) wanted \(plan.assertions.count) assertion(s), sleepDisabled=\(plan.sleepDisabled)")
            return false
        }
        return true
    }
}
