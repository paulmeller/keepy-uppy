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
    /// An observer, not a factory — the exact contrast with
    /// `makeProcessRunning` above, and for the mirror-image reason. CPU busy
    /// is a rate, so `SystemCPUBusyObserver` reports the difference between
    /// consecutive samples and its previous sample MUST outlive the tick that
    /// took it; rebuilding it per tick would leave it permanently on its first
    /// call, which by contract is `.undetermined` forever. One instance, held
    /// for this runner's whole life, sampled exactly once per tick below.
    private let cpuObserver: CPUBusyObserving
    /// A plain observer rather than a factory: it holds no state and caches
    /// nothing, because `NSWorkspace.frontmostApplication` is a cheap
    /// property read rather than a table enumeration. There is nothing whose
    /// lifetime has to be the tick.
    private let frontmostApp: FrontmostAppObserving
    private var evidence = SessionEvidence()
    private var timer: Timer?
    /// Snapshot bookkeeping for the session-completion action, including the
    /// filter to this agent's own uid. See `SessionCompletionTracker` for
    /// both defects it exists to close.
    private var completionTracker = SessionCompletionTracker(ownerUID: getuid())
    private let completionNotifier = SessionCompletionNotifier()
    /// Non-reentrancy guard for `tick()`. See `start()`.
    private var isTicking = false

    init(connection: DaemonConnection,
         appRunning: AppRunningObserving = SystemAppRunningObserver(),
         display: DisplayObserving = SystemDisplayObserver(),
         processRunning: @escaping () -> ProcessRunningObserving = { SystemProcessRunningObserver() },
         cpuObserver: CPUBusyObserving = SystemCPUBusyObserver(),
         frontmostApp: FrontmostAppObserving = SystemFrontmostAppObserver()) {
        self.connection = connection
        self.appRunning = appRunning
        self.display = display
        self.makeProcessRunning = processRunning
        self.cpuObserver = cpuObserver
        self.frontmostApp = frontmostApp
    }

    /// The timer fires every 5s and spawns a `Task` per fire, but `tick()` is
    /// `async` and has no bound on how long it takes: every XPC call inside
    /// it is capped at `DaemonConnection.callTimeout`, which is *also* 5s, so
    /// a single hung call is enough to make one tick outlive its own period
    /// and overlap the next. Overlapping ticks are not merely wasteful, they
    /// were incorrect — the reviewer reproduced a stalled tick writing its
    /// stale session snapshot over a newer one, after which the next tick
    /// re-diffed an already-reported session as newly ended and ran the
    /// user's completion script a second time for the same session.
    ///
    /// The guard makes a slow tick degrade to "this tick was skipped" rather
    /// than "this action fired twice", which is the right direction: a
    /// skipped tick costs at most five seconds of latency on ending a
    /// session, and the next tick sees the same world. Re-reading the
    /// snapshot after the awaits would fix the write-back specifically, but
    /// would still leave two ticks concurrently reporting conditions ended
    /// and firing triggers against the same daemon state; refusing to
    /// overlap at all is both simpler and strictly stronger.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTicking else { return }
                self.isTicking = true
                defer { self.isTicking = false }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard let sessions = await connection.listSessions() else {
            // The connection is unusable (`listSessions` returning nil is
            // also what tears it down, in `DaemonConnection.call`). Drop the
            // completion baseline: when the daemon comes back its table is
            // empty, and diffing the pre-restart snapshot against it would
            // report every session as having ended in the same tick — N
            // script spawns and N webhook POSTs at once, bounded only by how
            // many sessions happened to be running. Same reasoning, and same
            // deliberate trade, as skipping the very first tick.
            completionTracker.forgetSnapshot()
            return
        }
        // One process-table read serves both `sessionsToEnd` and
        // `triggersToFire` below, however many sessions and rules each has to
        // answer for. Before this, the ~530-entry table was enumerated once
        // per session AND once per rule, every 5 seconds.
        let processRunning = makeProcessRunning()
        // One bundle, built once, passed to both — which is what keeps that
        // guarantee true: a second `ObserverSet` here would be a second
        // process-table enumeration, and a second CPU sample, whose delta
        // would be measured from the wrong instant.
        //
        // `acPower`: IOKit declining to say is not "on battery" — see
        // `PowerSource.acPowerReading`, where this mapping now lives so the
        // daemon's `.whileOnACPower` handling shares it rather than
        // re-deriving it (it re-derived it wrongly).
        let observers = ObserverSet(appRunning: appRunning,
                                    display: display,
                                    processRunning: processRunning,
                                    frontmostApp: frontmostApp,
                                    acPower: PowerControl.batteryState().source.acPowerReading,
                                    cpuBusy: cpuObserver.currentBusy())

        let ended = sessionsToEnd(sessions, observers: observers,
                                  evidence: &evidence, now: Date())
        for id in ended {
            _ = await connection.reportConditionEnded(id.uuidString)
        }

        let rules = TriggerStore.load()
        let fired = triggersToFire(rules, activeSessions: sessions, observers: observers)
        for rule in fired {
            // The rule stores relative intent; the absolute deadline is
            // computed HERE, at the instant the rule actually fires. A rule
            // written weeks ago must still buy a full hour of wakefulness
            // now — see `TriggerRule.defaultKind` for what going the other
            // way costs (a permanent 5s refire loop against the daemon).
            let now = Date()
            // `wakeMode:` is written out rather than left to the memberwise
            // default: a trigger fires while nobody is watching, so its session
            // has to be the one that survives a lid close. Spelling it is not
            // ceremony — `wakeMode` is one of `Session`'s three defaulted
            // fields, so omitting it is not a compile error (see
            // `Session.renewed(until:)`), and this file is not in the test
            // target, making this the one construction site with neither a
            // compiler nor a test to notice.
            let session = Session(id: UUID(), kind: sessionKind(firing: rule, now: now),
                                  owner: ClientID(rawValue: "agent"),
                                  persistence: .detached, origin: .trigger, startedAt: now,
                                  triggerID: rule.id, wakeMode: .clamshell)
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

        // One call does the uid filtering, the diff, and the write-back —
        // see `SessionCompletionTracker`. It reports nothing on the very
        // first tick (no baseline yet) so an agent restart doesn't
        // retroactively fire completion actions for sessions that ended
        // while it was down, and nothing for another logged-in user's
        // sessions, which this agent must never run scripts or POST payloads
        // for.
        //
        // The tracker is updated whether or not anything is configured, so
        // that turning a script on mid-session doesn't hand it a baseline
        // from whenever the agent last happened to look.
        let endedSessions = completionTracker.recordAndReportEnded(current: sessions)
        let config = SessionCompletionStore.load()
        if config.scriptPath != nil || config.webhookURL != nil {
            for endedSession in endedSessions {
                completionNotifier.notify(config: config, event: SessionCompletionEvent(
                    tool: nil, sessionID: endedSession.id.uuidString,
                    kind: endedSession.kind.wireDescription, endedAt: Date()))
            }
        }
    }
}
