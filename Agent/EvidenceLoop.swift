import Foundation

/// Per-session evidence the loop carries between ticks, because no single
/// sample is allowed to decide anything on its own.
///
/// This started as a bare `[UUID: CPUBusyWindow]` for the one condition that
/// already knew a single sample was not enough (`.whileCPUBusy`, spec §5).
/// The same reasoning applies to the other three, so the state they need
/// lives here beside it.
struct SessionEvidence {
    /// How many consecutive *confident negatives* end a session.
    ///
    /// One is not enough. `ConditionReading.undetermined` already removes the
    /// failures the agent can recognise, but the remaining reads still go
    /// through system components with their own transients that report
    /// success: `CGGetActiveDisplayList` legitimately reports one display
    /// while a monitor renegotiates its link (a KVM switch, a display waking
    /// from its own sleep), and `NSWorkspace.runningApplications` is fed by
    /// asynchronous Launch Services notifications that a relaunching app can
    /// briefly fall out of. Two consecutive negatives costs at most one extra
    /// 5s tick of wakefulness; one wrong negative sleeps a Mac mid-build.
    /// The asymmetry is the whole argument.
    ///
    /// This is the same shape as `CPUBusyWindow`'s sustained-quiet window,
    /// which is why `.whileCPUBusy` does not additionally go through here:
    /// it already debounces, over 120s rather than two samples, because CPU
    /// load genuinely oscillates around a threshold while the job it belongs
    /// to is still running. A process either is in the process table or is
    /// not; it does not flicker. So the process/app/display debounce is a
    /// guard against *observation* transients, and is deliberately short.
    static let negativesBeforeEnding = 2

    private var cpuWindows: [UUID: CPUBusyWindow] = [:]
    private var consecutiveNegatives: [UUID: Int] = [:]

    init() {}

    /// Number of sessions currently carrying any state. Only the tests care;
    /// it exists so `prune(toLive:)` is observable without exposing the
    /// dictionaries themselves.
    var trackedSessionCount: Int {
        Set(cpuWindows.keys).union(consecutiveNegatives.keys).count
    }

    /// Forgets sessions that are no longer live. Without this, every session
    /// that ended by some route other than this loop — a user pressing stop,
    /// a deadline expiring, a safety guard firing — left its entry behind for
    /// as long as the agent ran.
    mutating func prune(toLive ids: Set<UUID>) {
        cpuWindows = cpuWindows.filter { ids.contains($0.key) }
        consecutiveNegatives = consecutiveNegatives.filter { ids.contains($0.key) }
    }

    /// Folds one reading into a session's run of confident negatives, and
    /// answers whether that run is now long enough to end it.
    ///
    /// `.undetermined` leaves the run exactly as it was: it is neither
    /// evidence for ending nor evidence against, so it must not advance the
    /// count (a stream of failed reads could then end a session, which is the
    /// bug this whole change exists to fix) and must not reset it either
    /// (a flaky observer could then hold a session open forever). Only
    /// `.present` — real evidence the condition still holds — resets it.
    mutating func recordAndCheckEnd(_ id: UUID, _ reading: ConditionReading) -> Bool {
        switch reading {
        case .present:
            consecutiveNegatives[id] = 0
            return false
        case .undetermined:
            return false
        case .absent:
            let run = (consecutiveNegatives[id] ?? 0) + 1
            consecutiveNegatives[id] = run
            return run >= Self.negativesBeforeEnding
        }
    }

    /// The `.whileCPUBusy` path, unchanged in substance: each such session
    /// needs its own sustained-quiet window, keyed by session id, surviving
    /// across calls.
    mutating func recordAndCheckCPUEnd(_ id: UUID, threshold: Double,
                                       busy: CPUBusyReading, now: Date) -> Bool {
        // A sample that could not be taken is not a quiet CPU. Leaving the
        // window untouched means the 120s clock neither starts nor advances
        // on a failed read.
        guard case .busy(let fraction) = busy else { return false }
        var window = cpuWindows[id] ?? CPUBusyWindow(threshold: threshold, sustainedFor: 120)
        window.record(busy: fraction, at: now)
        cpuWindows[id] = window
        return window.isSustainedQuiet(at: now)
    }
}

/// Pure: given the daemon's current session list and fresh observer
/// readings, which sessions' conditions have ended?
///
/// The one invariant that matters here: a session ends only on a **confident
/// negative**, and only after `SessionEvidence.negativesBeforeEnding` of them
/// in a row. `ConditionReading.undetermined` can never end a session, no
/// matter how many times it is returned — an observer that cannot answer must
/// not be able to put a Mac to sleep in the middle of a build. `evidence` is
/// `inout` because that run, and each `.whileCPUBusy` session's
/// sustained-quiet window, have to survive across calls.
func sessionsToEnd(
    _ sessions: [Session],
    observers: ObserverSet,
    evidence: inout SessionEvidence,
    now: Date
) -> [UUID] {
    evidence.prune(toLive: Set(sessions.map(\.id)))

    var ended: [UUID] = []
    for session in sessions {
        switch session.kind {
        case .whileAppRunning(let bundleID):
            if evidence.recordAndCheckEnd(session.id, observers.appRunning.isRunning(bundleID: bundleID)) {
                ended.append(session.id)
            }
        case .whileExternalDisplay:
            if evidence.recordAndCheckEnd(session.id, observers.display.hasExternalDisplay()) {
                ended.append(session.id)
            }
        case .whileProcessRunning(let processName):
            if evidence.recordAndCheckEnd(session.id, observers.processRunning.isRunning(processName: processName)) {
                ended.append(session.id)
            }
        case .whileCPUBusy(let threshold):
            if evidence.recordAndCheckCPUEnd(session.id, threshold: threshold,
                                             busy: observers.cpuBusy, now: now) {
                ended.append(session.id)
            }
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower:
            continue // not ours to evaluate
        }
    }
    return ended
}
