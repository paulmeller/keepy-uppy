import Foundation

/// Pure: given the daemon's current session list and fresh observer
/// readings, which sessions' conditions have ended? `cpu` is `inout`
/// because each `.whileCPUBusy` session needs its own sustained-quiet
/// window, keyed by session id, surviving across calls.
func sessionsToEnd(
    _ sessions: [Session],
    appRunning: AppRunningObserving,
    display: DisplayObserving,
    processRunning: ProcessRunningObserving,
    cpu: inout [UUID: CPUBusyWindow],
    busyNow: Double?,
    now: Date
) -> [UUID] {
    var ended: [UUID] = []
    for session in sessions {
        switch session.kind {
        case .whileAppRunning(let bundleID):
            if !appRunning.isRunning(bundleID: bundleID) { ended.append(session.id) }
        case .whileExternalDisplay:
            if !display.hasExternalDisplay() { ended.append(session.id) }
        case .whileProcessRunning(let processName):
            if !processRunning.isRunning(processName: processName) { ended.append(session.id) }
        case .whileCPUBusy(let threshold):
            guard let busyNow else { continue }
            var window = cpu[session.id] ?? CPUBusyWindow(threshold: threshold, sustainedFor: 120)
            window.record(busy: busyNow, at: now)
            if window.isSustainedQuiet(at: now) {
                ended.append(session.id)
                cpu.removeValue(forKey: session.id)
            } else {
                cpu[session.id] = window
            }
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower:
            continue // not ours to evaluate
        }
    }
    return ended
}
