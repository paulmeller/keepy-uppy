import XCTest
@testable import KeepyUppy

final class CPUBusyWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A momentary lull mid-job must not end the session — only a
    /// SUSTAINED drop below threshold for the full window should.
    func testBriefDipBelowThresholdDoesNotEndBusyWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.8, at: t0)
        window.record(busy: 0.3, at: t0.addingTimeInterval(10))
        window.record(busy: 0.8, at: t0.addingTimeInterval(20))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(20)))
    }

    func testSustainedQuietForTheFullWindowEndsIt() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.3, at: t0)
        window.record(busy: 0.2, at: t0.addingTimeInterval(60))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(60)), "not yet 120s")
        window.record(busy: 0.1, at: t0.addingTimeInterval(121))
        XCTAssertTrue(window.isSustainedQuiet(at: t0.addingTimeInterval(121)))
    }

    func testGoingBusyAgainResetsTheWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.2, at: t0)
        window.record(busy: 0.9, at: t0.addingTimeInterval(100))
        window.record(busy: 0.2, at: t0.addingTimeInterval(200))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(200)), "quiet period restarted at t=100")
    }
}

/// The delta arithmetic, against a scripted sampler so the three readings
/// that must be `.undetermined` can be asserted exactly rather than waited
/// for. `SystemCPUBusyObserver` had no test of any kind while it shipped a
/// number that could not move.
final class CPUBusyObserverContractTests: XCTestCase {
    /// Hands back a scripted sequence of tick readings. `nil` is a sample
    /// that failed; running off the end also reads as a failure, so an
    /// over-eager observer shows up as `.undetermined` rather than as a crash
    /// somewhere unrelated.
    private final class ScriptedSampler: CPUTickSampling {
        private var remaining: [CPUTickSample?]
        init(_ samples: [CPUTickSample?]) { remaining = samples }
        func sample() -> CPUTickSample? {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }

    private func ticks(idle: Double, total: Double) -> CPUTickSample {
        CPUTickSample(idle: idle, total: total)
    }

    private func fraction(_ reading: CPUBusyReading,
                          file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard case .busy(let value) = reading else {
            XCTFail("expected a measurement, got \(reading)", file: file, line: line)
            return nil
        }
        return value
    }

    /// §3's rule at the moment it is easiest to get wrong. A delta needs a
    /// predecessor and the first call after launch has none — that is "I could
    /// not measure", not "the CPU is idle". A `0` here would start the 120s
    /// quiet clock of every live `.whileCPUBusy` session the instant the agent
    /// restarted.
    func testTheFirstReadingAfterLaunchIsUndetermined() {
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([ticks(idle: 1000, total: 2000)]))
        XCTAssertEqual(observer.currentBusy(), .undetermined,
                       "no predecessor is not a measurement of zero")
    }

    /// ...and the second reading, which does have one, describes the interval
    /// between the two — not the machine's life. The fixture makes the two
    /// answers unmistakable: the lifetime average at the second sample is
    /// 0.4764, while only 1 of the 101 ticks that elapsed was idle.
    func testTheSecondReadingMeasuresTheIntervalRatherThanTheLifetime() {
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 1000, total: 2000),
            ticks(idle: 1001, total: 2101),
        ]))
        XCTAssertEqual(observer.currentBusy(), .undetermined)
        guard let busy = fraction(observer.currentBusy()) else { return }
        XCTAssertEqual(busy, 1 - 1.0 / 101.0, accuracy: 1e-9,
                       "the shipping formula would have said 1 - 1001/2101 = 0.4764 here")
    }

    /// Two samples inside one kernel tick period elapse no ticks at all.
    /// `0 / 0` is not a quiet CPU, and reporting it as one would end a session
    /// on the strength of a measurement that was never taken.
    func testNoElapsedTicksIsUndeterminedRatherThanIdle() {
        let stalled = ticks(idle: 1000, total: 2000)
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([stalled, stalled]))
        XCTAssertEqual(observer.currentBusy(), .undetermined, "no predecessor yet")
        XCTAssertEqual(observer.currentBusy(), .undetermined, "no elapsed ticks to measure")
    }

    /// The same guard covers counter wraparound, which is real rather than
    /// theoretical: the kernel's fields are `natural_t` (`UInt32`) and,
    /// measured on this Mac, advance at 1599 ticks/second in aggregate across
    /// 16 cores — about 31 days of uptime. Both deltas go sharply negative,
    /// which must cost one reading and not produce a number.
    func testWrappedCountersAreUndeterminedRatherThanIdle() {
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 4_294_900_000, total: 4_294_960_000),
            ticks(idle: 400, total: 900),
        ]))
        XCTAssertEqual(observer.currentBusy(), .undetermined, "no predecessor yet")
        XCTAssertEqual(observer.currentBusy(), .undetermined, "wrapped counters measure nothing")
    }

    /// ...and the wrap costs exactly one reading, because the failed pair is
    /// still stored as the next one's predecessor.
    func testTheReadingAfterAWrapIsAMeasurementAgain() {
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 4_294_900_000, total: 4_294_960_000),
            ticks(idle: 400, total: 900),
            ticks(idle: 410, total: 1000),
        ]))
        XCTAssertEqual(observer.currentBusy(), .undetermined)
        XCTAssertEqual(observer.currentBusy(), .undetermined)
        guard let busy = fraction(observer.currentBusy()) else { return }
        XCTAssertEqual(busy, 1 - 10.0 / 100.0, accuracy: 1e-9)
    }

    /// A sample that could not be taken is `.undetermined` — and must not cost
    /// the *next* one its predecessor, or one flaky read would silence the
    /// observer for two ticks instead of one.
    func testAFailedSampleKeepsThePredecessorForTheNextOne() {
        let observer = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 1000, total: 2000),
            nil,
            ticks(idle: 1010, total: 2100),
        ]))
        XCTAssertEqual(observer.currentBusy(), .undetermined, "no predecessor yet")
        XCTAssertEqual(observer.currentBusy(), .undetermined, "the sample itself failed")
        guard let busy = fraction(observer.currentBusy()) else { return }
        XCTAssertEqual(busy, 1 - 10.0 / 100.0, accuracy: 1e-9,
                       "measured across the whole span, from the last sample that succeeded")
    }

    /// The previous sample has to survive the trip through the existential
    /// `EvidenceLoopRunner` stores this as, which is what makes `final class`
    /// a requirement rather than a preference: `currentBusy()` is non-mutating
    /// in the protocol, so a `struct` cannot express this at all, and a
    /// `mutating` variant would have its update discarded on the copy.
    func testStateSurvivesThroughTheCPUBusyObservingExistential() {
        let observer: CPUBusyObserving = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 1000, total: 2000),
            ticks(idle: 1000, total: 2100),
        ]))
        XCTAssertEqual(observer.currentBusy(), .undetermined)
        XCTAssertEqual(observer.currentBusy(), .busy(fraction: 1.0),
                       "the second call must remember what the first one sampled")
    }

    /// Whatever the kernel hands back, what reaches `CPUBusyWindow` has to be
    /// a fraction — it is compared directly against a user-chosen threshold in
    /// 0...1, and a -1 or a 1.5 there would make that comparison meaningless.
    func testTheReportedValueIsAlwaysAFraction() {
        let impossiblyIdle = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 1000, total: 2000),
            ticks(idle: 1200, total: 2100),   // idle grew by more than total did
        ]))
        _ = impossiblyIdle.currentBusy()
        XCTAssertEqual(impossiblyIdle.currentBusy(), .busy(fraction: 0.0))

        let impossiblyBusy = SystemCPUBusyObserver(sampler: ScriptedSampler([
            ticks(idle: 1000, total: 2000),
            ticks(idle: 950, total: 2100),    // idle went backwards
        ]))
        _ = impossiblyBusy.currentBusy()
        XCTAssertEqual(impossiblyBusy.currentBusy(), .busy(fraction: 1.0))
    }
}

/// The live observer against real load, which is the only thing that would
/// have caught the shipped bug: every reading it produced was a plausible
/// fraction, and the fraction simply never changed.
///
/// Deliberately loose bounds. This asserts "does the number move at all",
/// which is exactly what was broken; a tight bound would be flaky on any
/// machine doing something else at the same time.
final class SystemCPUBusyObserverLiveTests: XCTestCase {
    /// Pins every core until a deadline, and joins every worker before
    /// returning so nothing outlives the test.
    private func burnEveryCore(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        let group = DispatchGroup()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var x = 1.000_001
                while Date() < deadline {
                    for _ in 0..<100_000 { x = x * 1.000_000_1 + 0.000_000_1 }
                    if x > 1e9 { x = 1.000_001 }
                }
                Self.blackhole(x)
            }
        }
        group.wait()
    }

    /// Keeps a release-configuration optimizer from deleting the loop above,
    /// which would leave the test measuring nothing and passing anyway.
    @inline(never) private static func blackhole(_ value: Double) {
        if value == .infinity { fatalError("unreachable") }
    }

    private func fraction(_ reading: CPUBusyReading,
                          file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard case .busy(let value) = reading else {
            XCTFail("a sample taken a second after its predecessor must succeed, got \(reading)",
                    file: file, line: line)
            return nil
        }
        return value
    }

    /// The bug, pinned. Two intervals a second long, one idle and one with
    /// every core pinned, must not report the same number. The shipping
    /// formula divided counters cumulative since boot, so both came back as
    /// the machine's lifetime average — measured on this Mac, 0.1660 idle and
    /// 0.1662 after two seconds of all-core burn, a swing of 0.0002. The same
    /// two intervals measured as deltas gave 0.0506 and 0.9969.
    func testTwoSamplesAroundRealWorkReportDifferentBusyFractions() {
        let observer = SystemCPUBusyObserver()
        XCTAssertEqual(observer.currentBusy(), .undetermined, "the first call has no predecessor")

        Thread.sleep(forTimeInterval: 1)
        guard let quiet = fraction(observer.currentBusy()) else { return }

        burnEveryCore(for: 1)
        guard let busy = fraction(observer.currentBusy()) else { return }

        XCTAssertGreaterThan(busy, 0.5, "every core was pinned for the whole interval")
        XCTAssertGreaterThan(busy - quiet, 0.2,
                             "quiet \(quiet) vs busy \(busy): a lifetime average moves by ~0.0002 here")
    }

    /// The floor, which is what actually ends sessions: an idle interval must
    /// report *low*, not "17% because that is the machine's lifetime average".
    /// A user asking to stay awake while the CPU is above 25% got a session
    /// that never ended, because 0.17 was reported forever whatever the CPU did.
    func testAQuietIntervalReportsALowFraction() {
        let observer = SystemCPUBusyObserver()
        XCTAssertEqual(observer.currentBusy(), .undetermined, "the first call has no predecessor")

        Thread.sleep(forTimeInterval: 1)
        guard let quiet = fraction(observer.currentBusy()) else { return }
        XCTAssertLessThan(quiet, 0.5, "nothing but this test was asked to run during that second")
    }
}

/// Tests against the real process table. Hermetic: every one of them spawns
/// the process it looks for, so nothing here depends on Claude Code — or any
/// other tool — happening to be installed on the machine running the suite.
final class SystemProcessRunningObserverTests: XCTestCase {
    private var spawned: [Process] = []
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keepy-uppy-observer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning { process.terminate() }
        for process in spawned { process.waitUntilExit() }
        spawned = []
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    /// Starts `/bin/sleep` through a symlink of our choosing and waits until
    /// the kernel has actually published it. The symlink is the point: the
    /// kernel takes `p_comm` from the *resolved* binary, so the process shows
    /// up as `p_comm` = `sleep` while `argv[0]` is the link's name. That is
    /// exactly the shape of the `claude` bug — npm installs Claude Code as a
    /// `claude` symlink to `claude.exe`, so `p_comm` reads `claude.exe` and
    /// only `argv[0]` ever says `claude`.
    @discardableResult
    private func spawnSleep(named name: String) throws -> Process {
        let link = scratch.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let process = Process()
        process.executableURL = link
        process.arguments = ["30"]
        try process.run()
        spawned.append(process)

        // `Process.run()` returns once the fork/exec is under way; give the
        // process table a moment to actually contain it. A fresh observer per
        // poll, because each one memoizes its single read for its lifetime.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if SystemProcessRunningObserver().isRunning(processName: name) == .present { return process }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("spawned process \"\(name)\" never appeared in the process table")
        return process
    }

    func testFindsAProcessItSpawnedItself() throws {
        let name = "keepy-uppy-probe-\(UInt32.random(in: 0..<1_000_000))"
        try spawnSleep(named: name)
        XCTAssertEqual(SystemProcessRunningObserver().isRunning(processName: name), .present)
    }

    func testReportsAbsentForANameNothingCouldBeRunningUnder() {
        let name = "keepy-uppy-definitely-not-running-\(UUID().uuidString)"
        XCTAssertEqual(SystemProcessRunningObserver().isRunning(processName: name), .absent,
                       "a successful read that found nothing is a confident negative, not a failure")
    }

    func testStopsFindingTheProcessOnceItExits() throws {
        let name = "keepy-uppy-probe-exit-\(UInt32.random(in: 0..<1_000_000))"
        let process = try spawnSleep(named: name)
        process.terminate()
        process.waitUntilExit()

        // A fresh observer each time: the cache is meant to last exactly one
        // tick, and this is a different tick.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if SystemProcessRunningObserver().isRunning(processName: name) == .absent { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("the observer still reports \"\(name)\" running after it exited")
    }

    /// C1, hermetically. The name is 30+ characters and reachable only via
    /// `argv[0]` / the executable path — `p_comm` for this process says
    /// `sleep`, and is truncated at `MAXCOMLEN` (16) besides. A matcher that
    /// looked at `p_comm` alone, as this one used to, fails both halves.
    func testMatchesANameThatOnlyArgv0EverCarries() throws {
        let name = "keepy-uppy-argv0-only-probe-\(UInt32.random(in: 100_000..<1_000_000))"
        XCTAssertGreaterThan(name.count, Int(MAXCOMLEN), "the point of this test is a name p_comm cannot hold")
        try spawnSleep(named: name)

        let observer = SystemProcessRunningObserver()
        XCTAssertEqual(observer.isRunning(processName: name), .present)
        // ...and the p_comm the kernel actually recorded for it is a
        // different string entirely, which is what makes the above load-bearing.
        XCTAssertEqual(observer.isRunning(processName: "sleep"), .present)
        XCTAssertEqual(observer.isRunning(processName: String(name.prefix(Int(MAXCOMLEN)))), .absent,
                       "the truncation p_comm would have imposed must not be what we match")
    }

    /// uid scoping. Everything this observer reports must belong to the user
    /// whose agent is asking — otherwise another account's `claude` holds
    /// your session awake. `launchd` (pid 1, uid 0) is the cheapest process
    /// that is guaranteed to exist and guaranteed not to be ours.
    func testDoesNotSeeAnotherUsersProcesses() throws {
        try XCTSkipIf(geteuid() == 0, "running as root, so root's processes legitimately are ours")
        XCTAssertEqual(SystemProcessRunningObserver().isRunning(processName: "launchd"), .absent,
                       "pid 1 runs as uid 0 and must be invisible to a non-root user's observer")
    }
}

/// The memoization and failure behaviour, against a fake table reader so they
/// can be asserted exactly rather than inferred.
final class ProcessRunningObserverContractTests: XCTestCase {
    private final class CountingReader: ProcessTableReading {
        let result: ProcessTableReadResult
        private(set) var reads = 0
        init(_ result: ProcessTableReadResult) { self.result = result }
        func read() -> ProcessTableReadResult {
            reads += 1
            return result
        }
    }

    func testAFailedReadIsUndeterminedRatherThanNotRunning() {
        let observer = SystemProcessRunningObserver(reader: CountingReader(.unavailable))
        XCTAssertEqual(observer.isRunning(processName: "claude"), .undetermined,
                       "a sysctl that failed says nothing about whether claude is running")
    }

    func testASuccessfulReadDistinguishesPresentFromAbsent() {
        let observer = SystemProcessRunningObserver(reader: CountingReader(.names(["claude"])))
        XCTAssertEqual(observer.isRunning(processName: "claude"), .present)
        XCTAssertEqual(observer.isRunning(processName: "codex"), .absent)
    }

    /// One observer, one process-table read, however many questions. The
    /// evidence loop asks once per live session and once per enabled rule; on
    /// this Mac each read enumerates ~530 processes.
    func testOneObserverReadsTheProcessTableAtMostOnce() {
        let reader = CountingReader(.names(["claude", "codex"]))
        let observer = SystemProcessRunningObserver(reader: reader)
        for _ in 1...20 {
            _ = observer.isRunning(processName: "claude")
            _ = observer.isRunning(processName: "codex")
            _ = observer.isRunning(processName: "nothing")
        }
        XCTAssertEqual(reader.reads, 1)
    }

    /// ...and the memoization does not outlive the observer, which is how the
    /// cache is kept from going stale: `EvidenceLoopRunner` makes a new one
    /// every tick, so a new tick always re-reads.
    func testANewObserverReadsAgain() {
        let reader = CountingReader(.names(["claude"]))
        _ = SystemProcessRunningObserver(reader: reader).isRunning(processName: "claude")
        _ = SystemProcessRunningObserver(reader: reader).isRunning(processName: "claude")
        XCTAssertEqual(reader.reads, 2)
    }

    /// A failed read is cached for the tick too — retrying a failing sysctl
    /// once per session and once per rule is exactly the hammering the
    /// memoization exists to stop, and `SysctlProcessTableReader` has already
    /// done its own retries inside that one call.
    func testAFailedReadIsAlsoOnlyAttemptedOncePerTick() {
        let reader = CountingReader(.unavailable)
        let observer = SystemProcessRunningObserver(reader: reader)
        for _ in 1...10 { XCTAssertEqual(observer.isRunning(processName: "claude"), .undetermined) }
        XCTAssertEqual(reader.reads, 1)
    }
}

/// The live `sysctl` reader, separately from the matching built on it.
final class SysctlProcessTableReaderTests: XCTestCase {
    func testReadsTheProcessTableSuccessfully() {
        guard case .names(let names) = SysctlProcessTableReader().read() else {
            return XCTFail("reading this user's own process table must succeed")
        }
        XCTAssertFalse(names.isEmpty)
    }

    /// The test runner is itself a process owned by this uid, so a uid-scoped
    /// read must contain it. This is the cheapest end-to-end proof that the
    /// argv/executable-path extraction produces real names.
    func testContainsTheTestRunnerItself() {
        guard case .names(let names) = SysctlProcessTableReader().read() else {
            return XCTFail("reading this user's own process table must succeed")
        }
        let me = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        XCTAssertTrue(names.contains(me), "expected to find this process (\"\(me)\") in its own uid's table")
    }

    /// Repeated reads must not degrade. Under process churn the old
    /// exact-sized single-shot read returned `ENOMEM` on roughly one poll in
    /// two hundred during a real compile; over-allocating and retrying is
    /// what removed it.
    func testRepeatedReadsAllSucceed() {
        for attempt in 1...200 {
            if case .unavailable = SysctlProcessTableReader().read() {
                XCTFail("read \(attempt) of 200 failed")
                return
            }
        }
    }
}
