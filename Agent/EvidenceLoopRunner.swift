import Foundation

/// Polls the daemon every 5s for its current session list and: (1) reports
/// back any agent-evaluated session whose condition has ended
/// (`sessionsToEnd`, in EvidenceLoop.swift), and (2) evaluates
/// `TriggerStore`'s rules against fresh observer readings and originates a
/// new session (`triggersToFire`, in Shared/TriggerRule.swift) for any that
/// fired. Talks to the daemon over `DaemonConnection` (Task 2's agent-only
/// XPC client), so this type is agent-executable-only — it must never be
/// compiled into the GUI app bundle, unlike the pure `sessionsToEnd` and
/// `triggersToFire` functions it wraps.
@MainActor
final class EvidenceLoopRunner {
    private let connection: DaemonConnection
    private let appRunning: AppRunningObserving
    private let display: DisplayObserving
    private let cpuObserver: CPUBusyObserving
    private var cpuWindows: [UUID: CPUBusyWindow] = [:]
    private var timer: Timer?

    init(connection: DaemonConnection,
         appRunning: AppRunningObserving = SystemAppRunningObserver(),
         display: DisplayObserving = SystemDisplayObserver(),
         cpuObserver: CPUBusyObserving = SystemCPUBusyObserver()) {
        self.connection = connection
        self.appRunning = appRunning
        self.display = display
        self.cpuObserver = cpuObserver
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard let sessions = await connection.listSessions() else { return }
        let ended = sessionsToEnd(sessions, appRunning: appRunning, display: display,
                                  cpu: &cpuWindows, busyNow: cpuObserver.currentBusyFraction(), now: Date())
        for id in ended {
            _ = await connection.reportConditionEnded(id.uuidString)
        }

        let rules = TriggerStore.load()
        let onACPower = PowerControl.batteryState().source == .acPower
        let fired = triggersToFire(rules, activeSessions: sessions, appRunning: appRunning,
                                   display: display, onACPower: onACPower)
        for rule in fired {
            // The rule stores relative intent; the absolute deadline is
            // computed HERE, at the instant the rule actually fires. A rule
            // written weeks ago must still buy a full hour of wakefulness
            // now — see `TriggerRule.defaultKind` for what going the other
            // way costs (a permanent 5s refire loop against the daemon).
            let now = Date()
            let session = Session(id: UUID(), kind: rule.defaultKind.sessionKind(now: now),
                                  owner: ClientID(rawValue: "agent"),
                                  persistence: .detached, origin: .trigger, startedAt: now,
                                  triggerID: rule.id)
            let (sessionID, error) = await connection.startSession(session)
            if sessionID == nil {
                // A `.triggerSuppressed` ("cooldown") rejection here is
                // expected, ordinary behavior during a safety episode, not
                // an error worth alarming on — the daemon's admission path
                // (Shared/SessionEngine.swift) already made the real
                // decision; the agent just logs and moves on to the next
                // tick rather than crashing or retry-looping.
                agentLogger.log("Trigger \(rule.id) did not start a session: \(error ?? "unknown")")
            }
        }
    }
}
