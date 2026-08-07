import Foundation
import os

let helperLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.helper", category: "daemon")

/// Serialises both engines behind one queue: XPC replies arrive on arbitrary
/// threads, and the engines are value types with no locking of their own.
final class DaemonRuntime {
    private let queue = DispatchQueue(label: "au.com.workwireless.keepy-uppy.helper.runtime")
    private var sessions = SessionEngine()
    private var safety = SafetyEngine(config: .default)
    private let observer: SafetyObserving
    private let bundlePath: String
    private var timer: DispatchSourceTimer?

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

    func startSession(_ session: Session) -> Bool {
        queue.sync {
            sessions.apply(.start(session), now: Date())
            return applyLocked()
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
    /// signing-derived role in `HelperListenerDelegate`, not by this call,
    /// so a crash between registering and disconnecting can't leave a stale
    /// "who's the agent" flag here. This exists so the log shows who
    /// registered.
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

    func agentDisappeared() {
        queue.sync {
            let ended = sessions.apply(.agentDisappeared, now: Date())
            if !ended.isEmpty {
                helperLogger.log("Agent gone; ended \(ended.count) unverifiable session(s)")
            }
            _ = applyLocked()
        }
    }

    func conditionEnded(id: UUID) { queue.sync { _ = sessions.apply(.conditionEnded(id: id), now: Date()); _ = applyLocked() } }

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
