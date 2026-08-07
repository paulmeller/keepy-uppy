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
    case failed
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

    /// Structural refcount of open connections to the agent-only Mach
    /// service (Fixes 3 & 4). Tracks *connections*, not explicit
    /// `registerAsAgent` calls, matching how disappearance is already
    /// detected structurally in `HelperListenerDelegate` (a connection's
    /// agent-ness is fixed at accept time by which Mach service it came in
    /// on, not by anything the client asserts). Two problems share this one
    /// counter:
    ///   - Fix 3: an agent-evaluated session must not be startable when no
    ///     agent has ever connected (e.g. the LaunchAgent never loaded or
    ///     was never approved) — spec §5 only covers the agent
    ///     *disappearing*, not never arriving.
    ///   - Fix 4: agents are per-user but share one Mach service, so firing
    ///     `.agentDisappeared` on *any* agent connection closing would let
    ///     one user's logout end another user's `--while-app` session on a
    ///     multi-user Mac. Firing only when the *last* connection closes
    ///     fixes that for the common case. It is not full per-user scoping
    ///     — the daemon does not track which session belongs to which
    ///     user's agent, so if two different users' agents were ever
    ///     connected at once, the daemon still cannot tell whose evidence
    ///     went away when one of them disconnects; the surviving
    ///     connection merely keeps everyone's agent-evaluated sessions
    ///     alive until it, too, closes. That is a strict improvement over
    ///     today (any disconnect ends everyone), not a complete fix.
    private var liveAgentConnections = 0

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
            switch sessions.startSession(session, now: Date(), liveAgentConnections: liveAgentConnections) {
            case .admitted:
                return applyLocked() ? .started : .failed
            case .ownerLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): per-owner session cap (\(SessionAdmission.maxSessionsPerOwner)) reached")
                return .ownerLimitReached
            case .globalLimitReached:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): global session cap (\(SessionAdmission.maxSessionsGlobal)) reached")
                return .globalLimitReached
            case .noAgentConnected:
                helperLogger.error("Rejected startSession from \(session.owner.rawValue): kind requires a live agent connection to evaluate, and none is connected")
                return .noAgentConnected
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
    func renewLease(id: UUID, until: Date, requestedBy: ClientID) -> SessionIsolation.Authorization {
        queue.sync {
            let authorization = SessionIsolation.authorize(sessionID: id, requestedBy: requestedBy, among: sessions.sessions)
            if authorization == .authorized {
                _ = sessions.apply(.renewLease(id: id, until: until), now: Date())
                _ = applyLocked()
            }
            return authorization
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
    func agentConnectionOpened() {
        queue.sync { liveAgentConnections += 1 }
    }

    /// Call when a connection to the agent Mach service invalidates or is
    /// interrupted. Only the *last* live agent connection closing ends
    /// agent-evaluated sessions daemon-wide — see the doc comment on
    /// `liveAgentConnections` for why, and its residual limitation.
    func agentConnectionClosed() {
        queue.sync {
            liveAgentConnections = max(0, liveAgentConnections - 1)
            guard liveAgentConnections == 0 else { return }
            let ended = sessions.apply(.agentDisappeared, now: Date())
            if !ended.isEmpty {
                helperLogger.log("Last agent connection gone; ended \(ended.count) unverifiable session(s)")
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
    func conditionEnded(id: UUID) -> ConditionEndOutcome {
        queue.sync {
            let outcome = sessions.endCondition(id: id, now: Date())
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

        let oldest = sessions.sessions.map { now.timeIntervalSince($0.startedAt) }.max()
        let outcome = safety.evaluate(SafetyInputs(
            thermal: observer.thermalLevel(),
            batteryPercentage: observer.batteryPercentage(),
            onBattery: observer.isOnBatteryPower(),
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
