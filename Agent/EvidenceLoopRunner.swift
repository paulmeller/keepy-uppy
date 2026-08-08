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
    /// A *factory*, not an observer: enumerating the process table is the
    /// expensive read in this loop, and one observer per tick is what lets it
    /// be memoized safely. See `SystemProcessRunningObserver` — its cache has
    /// no invalidation logic because its lifetime is the tick.
    private let makeProcessRunning: () -> ProcessRunningObserving
    private let cpuObserver: CPUBusyObserving
    private var evidence = SessionEvidence()
    private var timer: Timer?
    private var previousSessions: [Session]?
    private let completionNotifier = SessionCompletionNotifier()

    init(connection: DaemonConnection,
         appRunning: AppRunningObserving = SystemAppRunningObserver(),
         display: DisplayObserving = SystemDisplayObserver(),
         processRunning: @escaping () -> ProcessRunningObserving = { SystemProcessRunningObserver() },
         cpuObserver: CPUBusyObserving = SystemCPUBusyObserver()) {
        self.connection = connection
        self.appRunning = appRunning
        self.display = display
        self.makeProcessRunning = processRunning
        self.cpuObserver = cpuObserver
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard let sessions = await connection.listSessions() else { return }
        // One process-table read serves both `sessionsToEnd` and
        // `triggersToFire` below, however many sessions and rules each has to
        // answer for. Before this, the ~530-entry table was enumerated once
        // per session AND once per rule, every 5 seconds.
        let processRunning = makeProcessRunning()

        let ended = sessionsToEnd(sessions, appRunning: appRunning, display: display,
                                  processRunning: processRunning,
                                  evidence: &evidence, busyNow: cpuObserver.currentBusy(), now: Date())
        for id in ended {
            _ = await connection.reportConditionEnded(id.uuidString)
        }

        let rules = TriggerStore.load()
        let acPower: ConditionReading
        switch PowerControl.batteryState().source {
        case .acPower: acPower = .present
        case .battery: acPower = .absent
        case .unknown: acPower = .undetermined // IOKit declined to say; not "on battery"
        }
        let fired = triggersToFire(rules, activeSessions: sessions, appRunning: appRunning,
                                   display: display, processRunning: processRunning, acPower: acPower)
        for rule in fired {
            // The rule stores relative intent; the absolute deadline is
            // computed HERE, at the instant the rule actually fires. A rule
            // written weeks ago must still buy a full hour of wakefulness
            // now — see `TriggerRule.defaultKind` for what going the other
            // way costs (a permanent 5s refire loop against the daemon).
            let now = Date()
            let session = Session(id: UUID(), kind: sessionKind(firing: rule, now: now),
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

        // Skipped on the very first tick (previousSessions == nil) so an
        // agent restart doesn't retroactively fire completion actions for
        // sessions that ended while it was down — there's no "previous" to
        // diff against yet, only a possibly-stale snapshot from before the
        // restart.
        if let previousSessions {
            let config = SessionCompletionStore.load()
            if config.scriptPath != nil || config.webhookURL != nil {
                for endedSession in sessionsEndedSince(previous: previousSessions, current: sessions) {
                    completionNotifier.notify(config: config, event: SessionCompletionEvent(
                        tool: nil, sessionID: endedSession.id.uuidString,
                        kind: String(describing: endedSession.kind), endedAt: Date()))
                }
            }
        }
        previousSessions = sessions
    }
}
