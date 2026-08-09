import XCTest
@testable import KeepyUppy

final class EvidenceLoopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    struct FakeAppRunning: AppRunningObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        init(running: Set<String>) { self.reading = running.isEmpty ? .absent : .present }
        func isRunning(bundleID: String) -> ConditionReading { reading }
    }
    struct FakeDisplay: DisplayObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        init(external: Bool) { self.reading = ConditionReading(external) }
        func hasExternalDisplay() -> ConditionReading { reading }
    }
    struct FakeProcessRunning: ProcessRunningObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        init(running: Set<String>) { self.reading = running.isEmpty ? .absent : .present }
        func isRunning(processName: String) -> ConditionReading { reading }
    }
    /// No `SessionKind` is bound to the frontmost app — deliberately, see
    /// `TriggerConditionKind.bindsSessionLifetime` — so nothing this file
    /// tests can consult it. It is here to satisfy `ObserverSet`, which gives
    /// no member a default, and it answers `.undetermined` for the same
    /// reason `acPower` does below: if a session kind ever does start reading
    /// it, filler that cannot end a session is the filler to have.
    struct FakeFrontmostApp: FrontmostAppObserving {
        func isFrontmost(bundleID: String) -> ConditionReading { .undetermined }
    }
    struct FakeNetworkAddress: NetworkAddressObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        func isOnSubnet(_ subnet: IPv4Subnet) -> ConditionReading { reading }
    }
    struct FakeMountedVolume: MountedVolumeObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        func isMounted(volumeName: String) -> ConditionReading { reading }
    }
    struct FakeVPN: VPNObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading) { self.reading = reading }
        func isVPNActive() -> ConditionReading { reading }
    }

    private func session(_ kind: SessionKind) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"),
               persistence: .detached, origin: .manual, startedAt: t0)
    }

    /// One `sessionsToEnd` tick, with every observer defaulted to something
    /// irrelevant so each test names only the observer it is about.
    ///
    /// The per-observer parameters stay parameters even though `sessionsToEnd`
    /// now takes one `ObserverSet`: the set is assembled here, so a new
    /// condition costs this file one defaulted argument rather than an edit to
    /// every one of the call sites below.
    @discardableResult
    private func tick(_ sessions: [Session],
                      evidence: inout SessionEvidence,
                      app: ConditionReading = .present,
                      display: ConditionReading = .present,
                      process: ConditionReading = .present,
                      volume: ConditionReading = .present,
                      network: ConditionReading = .present,
                      vpn: ConditionReading = .present,
                      busy: CPUBusyReading = .undetermined,
                      at now: Date? = nil) -> [UUID] {
        sessionsToEnd(sessions,
                      // `.whileOnACPower` is the daemon's to evaluate, never
                      // this loop's, so the reading is filler here — and
                      // `.undetermined` is the filler that cannot end a
                      // session if that ever stops being true.
                      observers: ObserverSet(appRunning: FakeAppRunning(app),
                                             display: FakeDisplay(display),
                                             processRunning: FakeProcessRunning(process),
                                             frontmostApp: FakeFrontmostApp(),
                                             mountedVolume: FakeMountedVolume(volume),
                                             networkAddress: FakeNetworkAddress(network),
                                             vpn: FakeVPN(vpn),
                                             acPower: .undetermined,
                                             cpuBusy: busy),
                      evidence: &evidence, now: now ?? t0)
    }

    // MARK: - The tri-state contract
    //
    // These are the tests that make the contract real. `sessionsToEnd` ends a
    // session only on a run of CONFIDENT negatives; `.undetermined` — an
    // observer admitting it could not look — must never end one, because
    // ending a session is what lets the Mac go to sleep.

    func testUndeterminedNeverEndsAProcessSession() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        for tickNumber in 1...50 {
            let ended = tick([s], evidence: &evidence, process: .undetermined)
            XCTAssertTrue(ended.isEmpty,
                          "tick \(tickNumber): an observer that cannot answer must not end a live session")
        }
    }

    func testUndeterminedNeverEndsAnAppOrDisplaySession() {
        let app = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        let screen = session(.whileExternalDisplay)
        var evidence = SessionEvidence()
        for _ in 1...50 {
            XCTAssertTrue(tick([app, screen], evidence: &evidence,
                               app: .undetermined, display: .undetermined).isEmpty)
        }
    }

    func testUndeterminedCPUSampleNeverEndsACPUSession() {
        let s = session(.whileCPUBusy(threshold: 0.5))
        var evidence = SessionEvidence()
        // Far more than the 120s sustained-quiet window, all of it unreadable.
        for step in 0...100 {
            let ended = tick([s], evidence: &evidence, busy: .undetermined,
                             at: t0.addingTimeInterval(Double(step) * 5))
            XCTAssertTrue(ended.isEmpty, "a sample that could not be taken is not a quiet CPU")
        }
    }

    /// The failure this whole change exists to prevent, end to end: a live
    /// `.whileProcessRunning` session, an observer whose `sysctl` is failing
    /// under process churn, and a Mac that must stay awake anyway.
    func testAProcessSessionSurvivesASustainedObserverOutage() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, process: .present).isEmpty)
        for _ in 1...20 {
            XCTAssertTrue(tick([s], evidence: &evidence, process: .undetermined).isEmpty)
        }
        // ...and once the observer recovers and the process really is gone,
        // the session ends normally.
        XCTAssertTrue(tick([s], evidence: &evidence, process: .absent).isEmpty, "first negative debounces")
        XCTAssertEqual(tick([s], evidence: &evidence, process: .absent), [s.id])
    }

    /// The `sessionsToEnd` half of the mounted-volume contract, and the one
    /// that can lose work: `FileManager.mountedVolumeURLs` answering `nil`, or
    /// answering with nothing at all, says the enumeration failed — `/` is
    /// always mounted — and a Mac copying to a backup drive must not be put to
    /// sleep because the volume list could not be read for a while.
    func testAVolumeReadThatFailedNeverEndsASession() {
        let s = session(.whileVolumeMounted(name: "Backup"))
        var evidence = SessionEvidence()
        for tickNumber in 1...50 {
            XCTAssertTrue(tick([s], evidence: &evidence, volume: .undetermined).isEmpty,
                          "tick \(tickNumber): an unreadable volume list is not an unmounted drive")
        }
        // ...and once the read succeeds and the drive really is gone, the
        // session ends normally, on the usual two consecutive negatives.
        XCTAssertTrue(tick([s], evidence: &evidence, volume: .absent).isEmpty, "first negative debounces")
        XCTAssertEqual(tick([s], evidence: &evidence, volume: .absent), [s.id])
    }

    func testAMountedVolumeSessionSurvivesWhileItIsStillMounted() {
        let s = session(.whileVolumeMounted(name: "Backup"))
        var evidence = SessionEvidence()
        for _ in 1...5 {
            XCTAssertTrue(tick([s], evidence: &evidence, volume: .present).isEmpty)
        }
    }

    /// `getifaddrs` failing is not "you left the network". Same shape as the
    /// volume test above, and the same consequence if it were wrong: a Mac
    /// held awake for a long transfer over that very network gets slept.
    func testANetworkReadThatFailedNeverEndsASession() {
        let s = session(.whileOnSubnet(cidr: "192.168.1.0/24"))
        var evidence = SessionEvidence()
        for tickNumber in 1...50 {
            XCTAssertTrue(tick([s], evidence: &evidence, network: .undetermined).isEmpty,
                          "tick \(tickNumber): a failed interface read is not a different subnet")
        }
        XCTAssertTrue(tick([s], evidence: &evidence, network: .absent).isEmpty, "first negative debounces")
        XCTAssertEqual(tick([s], evidence: &evidence, network: .absent), [s.id])
    }

    /// The deliberate asymmetry with `triggersToFire`, which refuses to fire a
    /// rule whose block will not parse: here the same value must **not** end a
    /// live session, because failing to understand a rule is not an
    /// observation, and this is the half that can sleep a Mac.
    func testASessionWhoseBlockCannotBeParsedIsNeverEnded() {
        let s = session(.whileOnSubnet(cidr: "not-a-network"))
        var evidence = SessionEvidence()
        for _ in 1...50 {
            XCTAssertTrue(tick([s], evidence: &evidence, network: .absent).isEmpty,
                          "an unparseable block is undetermined, whatever the observer says")
        }
    }

    /// The most expensive one to get wrong in this direction: a VPN is what a
    /// long remote build or a file copy is running *over*, so a read that
    /// merely failed must never be taken for "the tunnel dropped". The
    /// dynamic-store copy returning nil is the case this stands for.
    func testAVPNReadThatFailedNeverEndsASession() {
        let s = session(.whileVPNActive)
        var evidence = SessionEvidence()
        for tickNumber in 1...50 {
            XCTAssertTrue(tick([s], evidence: &evidence, vpn: .undetermined).isEmpty,
                          "tick \(tickNumber): a configuration read that failed is not a dropped tunnel")
        }
        XCTAssertTrue(tick([s], evidence: &evidence, vpn: .absent).isEmpty, "first negative debounces")
        XCTAssertEqual(tick([s], evidence: &evidence, vpn: .absent), [s.id])
    }

    /// …and a reconnection between two ticks costs the session nothing,
    /// because one confident negative is not enough. This is the concrete
    /// reason `.vpnActive` was judged safe to bind a session's lifetime to.
    func testAVPNThatDropsAndReconnectsInsideTheDebounceKeepsItsSession() {
        let s = session(.whileVPNActive)
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, vpn: .absent).isEmpty)
        XCTAssertTrue(tick([s], evidence: &evidence, vpn: .present).isEmpty)
        XCTAssertTrue(tick([s], evidence: &evidence, vpn: .absent).isEmpty,
                      "the run of negatives restarted when the tunnel came back")
    }

    // MARK: - Debounce

    func testASingleConfidentNegativeDoesNotEndASession() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, process: .absent).isEmpty,
                      "one sample must never decide, exactly as for .whileCPUBusy")
    }

    func testTwoConsecutiveConfidentNegativesEndTheSession() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, process: .absent)
        XCTAssertEqual(tick([s], evidence: &evidence, process: .absent), [s.id])
    }

    func testAPositiveReadingResetsTheRunOfNegatives() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, app: .absent)
        _ = tick([s], evidence: &evidence, app: .present)
        XCTAssertTrue(tick([s], evidence: &evidence, app: .absent).isEmpty,
                      "the app came back, so this is the first negative again, not the second")
    }

    /// `.undetermined` neither advances the run nor erases it. Advancing
    /// would let failed reads end a session; resetting would let a flaky
    /// observer hold one open forever.
    func testUndeterminedPreservesButDoesNotAdvanceTheRun() {
        let s = session(.whileExternalDisplay)
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, display: .absent).isEmpty)
        XCTAssertTrue(tick([s], evidence: &evidence, display: .undetermined).isEmpty,
                      "an unreadable display list is not the second negative")
        XCTAssertEqual(tick([s], evidence: &evidence, display: .absent), [s.id],
                       "but it did not erase the first one either")
    }

    func testEachSessionDebouncesIndependently() {
        let a = session(.whileProcessRunning(processName: "claude"))
        let b = session(.whileProcessRunning(processName: "codex"))
        var evidence = SessionEvidence()
        _ = tick([a], evidence: &evidence, process: .absent)   // a: one negative
        let ended = tick([a, b], evidence: &evidence, process: .absent)
        XCTAssertEqual(ended, [a.id], "b is only on its first negative")
    }

    // MARK: - Steady-state behaviour

    func testAppStillRunningIsNotEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, app: .present).isEmpty)
        XCTAssertTrue(tick([s], evidence: &evidence, app: .present).isEmpty)
    }

    func testAppNoLongerRunningIsEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, app: .absent)
        XCTAssertEqual(tick([s], evidence: &evidence, app: .absent), [s.id])
    }

    func testExternalDisplayDisconnectedEndsTheSession() {
        let s = session(.whileExternalDisplay)
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, display: .absent)
        XCTAssertEqual(tick([s], evidence: &evidence, display: .absent), [s.id])
    }

    func testProcessStillRunningIsNotEnded() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        XCTAssertTrue(tick([s], evidence: &evidence, process: .present).isEmpty)
        XCTAssertTrue(tick([s], evidence: &evidence, process: .present).isEmpty)
    }

    func testProcessNoLongerRunningIsEnded() {
        let s = session(.whileProcessRunning(processName: "claude"))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, process: .absent)
        XCTAssertEqual(tick([s], evidence: &evidence, process: .absent), [s.id])
    }

    func testDaemonEvaluableSessionsAreNeverReturned() {
        let s = session(.indefinite)
        var evidence = SessionEvidence()
        for _ in 1...5 {
            XCTAssertTrue(tick([s], evidence: &evidence, app: .absent, display: .absent,
                               process: .absent, volume: .absent, network: .absent,
                               vpn: .absent, busy: .busy(fraction: 0)).isEmpty,
                          "the agent must never report on sessions it doesn't own evaluation of")
        }
    }

    func testCPUBusySessionUsesItsOwnPerSessionWindow() {
        let s = session(.whileCPUBusy(threshold: 0.5))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, busy: .busy(fraction: 0.1), at: t0)
        let ended = tick([s], evidence: &evidence, busy: .busy(fraction: 0.1),
                         at: t0.addingTimeInterval(121))
        XCTAssertEqual(ended, [s.id])
    }

    /// `.whileCPUBusy` keeps its own 120s sustained-quiet window rather than
    /// also going through the two-sample debounce — a brief lull is a real
    /// reading, not an observation failure, and 120s is the right answer for
    /// it. This pins that the two mechanisms did not get conflated.
    func testCPUBusySessionIsNotEndedByTwoQuietSamplesAlone() {
        let s = session(.whileCPUBusy(threshold: 0.5))
        var evidence = SessionEvidence()
        _ = tick([s], evidence: &evidence, busy: .busy(fraction: 0.1), at: t0)
        XCTAssertTrue(tick([s], evidence: &evidence, busy: .busy(fraction: 0.1),
                           at: t0.addingTimeInterval(5)).isEmpty,
                      "two quiet samples 5s apart are not 120s of sustained quiet")
    }

    // MARK: - Per-session state hygiene

    func testStateIsForgottenForSessionsThatAreNoLongerLive() {
        let a = session(.whileProcessRunning(processName: "claude"))
        let b = session(.whileCPUBusy(threshold: 0.5))
        var evidence = SessionEvidence()
        _ = tick([a, b], evidence: &evidence, process: .absent, busy: .busy(fraction: 0.1))
        XCTAssertEqual(evidence.trackedSessionCount, 2)

        // Both vanish by some route other than this loop — stopped by hand, a
        // safety guard, a deadline. Their evidence must not outlive them.
        _ = tick([], evidence: &evidence)
        XCTAssertEqual(evidence.trackedSessionCount, 0)
    }
}
