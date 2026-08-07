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
    private var safety = SafetyEngine(config: .default)
    private let observer: SafetyObserving
    private let bundlePath: String
    private var timer: DispatchSourceTimer?

    /// Per-user structural refcounts of open connections to the agent-only
    /// Mach service. Tracks *connections*, not explicit
    /// `registerAsAgent` calls, matching how disappearance is already
    /// detected structurally in `HelperListenerDelegate` (a connection's
    /// agent-ness is fixed at accept time by which Mach service it came in
    /// on, not by anything the client asserts). Two problems share this map:
    ///   - Fix 3: an agent-evaluated session must not be startable when no
    ///     agent has ever connected (e.g. the LaunchAgent never loaded or
    ///     was never approved) — spec §5 only covers the agent
    ///     *disappearing*, not never arriving.
    ///   - Agents are per-user but share one Mach service. Counts are keyed
    ///     by the authenticated peer UID, matching `Session.ownerUID`, so a
    ///     logout ends exactly that user's agent-evaluated sessions without
    ///     disturbing or lending evidence to another login session.
    private var liveAgentConnectionsByUser: [UInt32: Int] = [:]

    init(observer: SafetyObserving = SystemSafetyObserver(),
         bundlePath: String = Bundle.main.bundlePath) {
        self.observer = observer
        self.bundlePath = bundlePath
    }

    /// Converge to safe before serving anyone, so a daemon crash — or an
    /// upgrade from v1, which left disablesleep set persistently — cannot
    /// leave the Mac stranded awake.
    func start() {
        queue.sync {
            let ok = PowerControl.setSleepDisabled(false)
            helperLogger.log("Daemon start: forced sleep enabled, success=\(ok)")
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
            // and keeps `desiredKeepAwake` true — for up to 5s, until the
            // next timer tick catches it. `.tick` has no effect of its own
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
                    _ = sessions.apply(.stop(id: session.id), now: now)
                    _ = applyLocked()
                    return .failed
                }
                return .started
            case .ownerLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): per-owner session cap (\(SessionAdmission.maxSessionsPerOwner)) reached")
                return .ownerLimitReached
            case .globalLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): global session cap (\(SessionAdmission.maxSessionsGlobal)) reached")
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
    func stopAll(all: Bool, requestedBy: ClientID) {
        queue.sync {
            let ids = SessionIsolation.sessionsToStop(all: all, requestedBy: requestedBy, among: sessions.sessions)
            for id in ids { _ = sessions.apply(.stop(id: id), now: Date()) }
            _ = applyLocked()
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

    func clientDisconnected(_ owner: ClientID) {
        queue.sync {
            let ended = sessions.apply(.clientDisconnected(owner), now: Date())
            if !ended.isEmpty { helperLogger.log("Client \(owner.rawValue) left; ended \(ended.count) session(s)") }
            _ = applyLocked()
        }
    }

    /// Call when a connection to the agent Mach service is accepted
    /// (Fixes 3 & 4). Must be paired with exactly one `agentConnectionClosed`.
    func agentConnectionOpened(userID: UInt32) {
        queue.sync { liveAgentConnectionsByUser[userID, default: 0] += 1 }
    }

    /// Call when a connection to the agent Mach service invalidates or is
    /// interrupted. Only the last live connection for this UID ends that
    /// user's agent-evaluated sessions.
    func agentConnectionClosed(userID: UInt32) {
        queue.sync {
            let remaining = max(0, liveAgentConnectionsByUser[userID, default: 0] - 1)
            if remaining == 0 {
                liveAgentConnectionsByUser.removeValue(forKey: userID)
            } else {
                liveAgentConnectionsByUser[userID] = remaining
            }
            guard remaining == 0 else { return }
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
            // `id` — would otherwise keep counting toward the caps and
            // `desiredKeepAwake` until the next tick.
            _ = sessions.apply(.tick, now: now)
            let outcome = sessions.endCondition(id: id, reportedByUserID: userID, now: now)
            if case .ended = outcome { _ = applyLocked() }
            return outcome
        }
    }

    func currentSessions() -> [Session] { queue.sync { sessions.sessions } }

    func isKeepingAwake() -> Bool { queue.sync { PowerControl.sleepDisabled() } }

    // MARK: - Private, always called on `queue`

    private func tickLocked() {
        guard bundleStillExists() else {
            helperLogger.error("App bundle is gone; restoring sleep and exiting")
            _ = PowerControl.setSleepDisabled(false)
            exit(0)
        }

        let now = Date()
        _ = sessions.apply(.tick, now: now)

        let battery = observer.batteryState()
        let onBattery = battery.source == .battery
        if battery.source != .acPower {
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

    @discardableResult
    private func applyLocked() -> Bool {
        let desired = sessions.desiredKeepAwake
        return PowerControl.setSleepDisabled(desired)
    }
}
