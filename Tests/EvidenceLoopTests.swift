import XCTest
@testable import KeepyUppy

final class EvidenceLoopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    struct FakeAppRunning: AppRunningObserving {
        let running: Set<String>
        func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    }
    struct FakeDisplay: DisplayObserving {
        let external: Bool
        func hasExternalDisplay() -> Bool { external }
    }

    private func session(_ kind: SessionKind) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"),
               persistence: .detached, origin: .manual, startedAt: t0)
    }

    func testAppStillRunningIsNotEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertTrue(ended.isEmpty)
    }

    func testAppNoLongerRunningIsEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertEqual(ended, [s.id])
    }

    func testExternalDisplayDisconnectedEndsTheSession() {
        let s = session(.whileExternalDisplay)
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertEqual(ended, [s.id])
    }

    func testDaemonEvaluableSessionsAreNeverReturned() {
        let s = session(.indefinite)
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertTrue(ended.isEmpty, "the agent must never report on sessions it doesn't own evaluation of")
    }

    func testCPUBusySessionUsesItsOwnPerSessionWindow() {
        let s = session(.whileCPUBusy(threshold: 0.5))
        var cpu: [UUID: CPUBusyWindow] = [:]
        _ = sessionsToEnd([s], appRunning: FakeAppRunning(running: []), display: FakeDisplay(external: false),
                          cpu: &cpu, busyNow: 0.1, now: t0)
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []), display: FakeDisplay(external: false),
                                  cpu: &cpu, busyNow: 0.1, now: t0.addingTimeInterval(121))
        XCTAssertEqual(ended, [s.id])
    }
}
