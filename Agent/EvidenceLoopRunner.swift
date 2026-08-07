import Foundation

/// Polls the daemon every 5s for its current session list and reports back
/// any agent-evaluated session whose condition has ended (`sessionsToEnd`,
/// in EvidenceLoop.swift). Talks to the daemon over `DaemonConnection`
/// (Task 2's agent-only XPC client), so this type is agent-executable-only
/// — it must never be compiled into the GUI app bundle, unlike the pure
/// `sessionsToEnd` function it wraps.
@MainActor
final class EvidenceLoop {
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
    }
}
