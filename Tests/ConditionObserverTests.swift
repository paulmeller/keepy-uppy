import XCTest
import AppKit
import SystemConfiguration
import IOKit
import IOKit.usb
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
///
/// Loose bounds are not enough on their own, though, because **both** tests
/// here begin by measuring a second they assume is quiet, and neither can tell
/// "the observer is broken" from "this Mac was compiling something". Measured
/// under an all-core burn in another process, they fail like this:
///
/// * `testAQuietIntervalReportsALowFraction` — `("1.0") is not less than ("0.5")`
/// * `testTwoSamplesAroundRealWorkReportDifferentBusyFractions` —
///   `("-0.348...") is not greater than ("0.2") - quiet 0.9498 vs busy 0.6018`
///
/// A failure that goes away on a re-run is how a real one gets waved through,
/// and that is not hypothetical here: it is precisely how the CPU observer's
/// bug survived four plans. So both tests ask first whether this machine can
/// answer their question, and **skip** — saying how busy it was and what to
/// check — rather than failing or, worse, being re-run until green.
///
/// The load they meet in practice is not exotic: it is `xcodebuild`'s own build
/// phase, which is why the gate waits for it to finish rather than skipping the
/// instant it sees a busy second. See `requireAMachineQuietEnoughToMeasure`.
final class SystemCPUBusyObserverLiveTests: XCTestCase {
    /// The busiest a machine may be and still be asked "does an idle interval
    /// read low?".
    ///
    /// Chosen from measurement, not from halving the `0.5` the assertions use.
    /// Ten consecutive one-second samples on this Mac, otherwise idle but with
    /// the usual background of a working machine, ranged 17.2% – 23.3% busy: a
    /// spread of about ±3 points around its mean. `0.35` sits five such spreads
    /// below the `0.5` the assertions need, and far enough above a normal
    /// machine's floor that the gate is not simply always shut — a gate that
    /// always skips has deleted two tests, which is worse than the flake it was
    /// meant to fix.
    ///
    /// It cannot defend against a spike that begins *after* it measures, and
    /// does not pretend to. What it converts into a skip is load that outlasts
    /// the wait below — another window's build, a video call, the all-core burn
    /// used to reproduce the original failures — all of which sit at 0.6 or
    /// above, and none of which a re-run makes honest.
    private static let quietEnoughBusyFraction = 0.35

    /// The fraction of CPU time this machine spent non-idle over `interval`, or
    /// `nil` when the kernel would not hand back its counters at all.
    ///
    /// One helper, shared by both tests, for the same reason
    /// `everyObserverUndetermined` is one fixture: two copies of a quietness
    /// rule are two rules, and the day one of them is loosened the other
    /// silently is not.
    ///
    /// It returns the fraction rather than a `Bool` so the skip message can
    /// name it. A skip that says "the machine was busy" and not *how* busy is a
    /// skip nobody can act on; `PowerControlTests`'
    /// `testHoldingTheDiskAssertionMovesTheSystemWideLevel` is the standard
    /// here, and it names both the measured level and the command to check it
    /// with.
    ///
    /// ## Why this is not the observer marking its own homework
    ///
    /// The gate reads `HostStatisticsCPUTickSampler` — the raw kernel counters
    /// — and differences two samples itself, rather than asking
    /// `SystemCPUBusyObserver.currentBusy()`. The bug these two tests pin lived
    /// in the *differencing*: ratios of counters cumulative since boot,
    /// reported as though they described the last interval. A regression there
    /// therefore cannot move this gate in either direction — it can neither
    /// open it on a busy Mac nor hold it shut on an idle one.
    ///
    /// What the gate does share with the code under test is the sampler, and
    /// that is the failure mode this choice accepts: a
    /// `HostStatisticsCPUTickSampler` that began reporting a constant *idle*
    /// machine would gate open **and** carry
    /// `testAQuietIntervalReportsALowFraction` to a false pass on a busy Mac.
    /// It would not survive the pair, which is why they are gated together:
    /// `testTwoSamplesAroundRealWorkReportDifferentBusyFractions` needs the
    /// number to *move*, and a constant cannot. The opposite fault — a sampler
    /// stuck reporting a busy machine — costs skips rather than false passes,
    /// and says so every run.
    ///
    /// A sampler that fails outright is not skipped past at all: `nil` is an
    /// `XCTUnwrap` failure at the call site, because a skip that hides a dead
    /// detector is worse than a flake.
    ///
    /// The interval is the same one second the tests themselves measure, so the
    /// gate and the assertion see the same shape of number rather than two
    /// differently-smoothed ones.
    private func measuredBusyFraction(over interval: TimeInterval = 1) -> Double? {
        let sampler = HostStatisticsCPUTickSampler()
        guard let first = sampler.sample() else { return nil }
        Thread.sleep(forTimeInterval: interval)
        guard let second = sampler.sample() else { return nil }
        let totalDelta = second.total - first.total
        guard totalDelta > 0 else { return nil }
        return min(1, max(0, 1 - (second.idle - first.idle) / totalDelta))
    }

    /// Fails when this Mac cannot be measured at all, skips when it stays too
    /// busy to be asked, and otherwise returns so the test can run.
    ///
    /// The order is copied from `PowerControlTests`'
    /// `testHoldingTheDiskAssertionMovesTheSystemWideLevel`: a dead measurement
    /// apparatus is a *failure*, and only a live one reporting an unanswerable
    /// machine is a skip.
    ///
    /// ## Why it waits instead of skipping on the first busy second
    ///
    /// The load these tests actually meet is `xcodebuild`'s own build phase.
    /// Measured here: on the first run after touching a source file, every core
    /// is still pinned when the test host launches — the kernel's idle counter
    /// advanced by *exactly zero* ticks across both of this class's tests, three
    /// runs in a row, while an unsandboxed probe outside agreed the machine was
    /// saturated — and on the next run, with nothing to rebuild, the same probe
    /// read 0.18 inside the test host and 0.19 outside, and both tests passed.
    ///
    /// So a gate that skipped on the first busy reading would skip on every run
    /// that followed an edit, which is nearly every run that matters, and the
    /// two tests would be gone in practice while still appearing in the list.
    /// Waiting a few seconds for the compiler's cores to be handed back keeps
    /// them.
    ///
    /// This is emphatically **not** the "re-run until green" this class exists
    /// to refuse. What repeats here is the *precondition*, never the assertion:
    /// each test still measures its interval exactly once, and a machine that is
    /// busy for a reason that outlasts the wait — a build in another window, a
    /// video call, the all-core burn used to reproduce the original failures —
    /// still skips, and says how busy it was.
    private func requireAMachineQuietEnoughToMeasure(waitingUpTo attempts: Int = 6) throws {
        var lastMeasured = 0.0
        for _ in 0..<attempts {
            lastMeasured = try XCTUnwrap(measuredBusyFraction(), """
                This Mac would not report its CPU tick counters at all, so \
                neither test in this class can be asked its question. That is a \
                dead measurement apparatus, not a busy machine, and it is a \
                failure rather than a skip.
                """)
            if lastMeasured <= Self.quietEnoughBusyFraction { return }
        }
        throw XCTSkip("""
            This Mac was still \(String(format: "%.0f%%", lastMeasured * 100)) \
            busy after \(attempts) seconds of waiting, above the \
            \(String(format: "%.0f%%", Self.quietEnoughBusyFraction * 100)) this \
            class allows, so "an idle interval reads low" cannot be answered \
            honestly here — what it would measure is whatever else is running, \
            not the observer's arithmetic. Both tests in this class are \
            meaningful only on an otherwise-idle Mac. Find the load with \
            `top -o cpu` or Activity Monitor and re-run once it is gone. Do not \
            simply re-run until green: a test re-run until it passes is how a \
            real failure gets waved through, and is exactly how the bug these \
            two tests pin survived four plans.
            """)
    }

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
    func testTwoSamplesAroundRealWorkReportDifferentBusyFractions() throws {
        try requireAMachineQuietEnoughToMeasure()

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
    func testAQuietIntervalReportsALowFraction() throws {
        try requireAMachineQuietEnoughToMeasure()

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

/// The live frontmost-app observer, against whatever is actually in front of
/// the machine running the suite.
///
/// Every test here **skips** rather than fails when there is no frontmost app,
/// and that is not defensiveness — "no app is in front" is exactly the
/// `.undetermined` case this observer exists to report (a locked screen, the
/// login window, another user switched in, a CI runner with no session). A
/// test that failed there would be asserting a fact about the machine running
/// it rather than about the observer.
///
/// What is *not* covered here, said plainly: the `.undetermined` paths
/// themselves. Both of them — `frontmostApplication` nil and
/// `runningApplications` empty — are properties of Launch Services that this
/// process cannot make happen on demand without locking the screen, so they
/// are verified by reading, and by the fact that `triggersToFire` treats the
/// reading and not the observer as the source of truth
/// (`testFrontmostAppUndeterminedNeverFires`).
final class SystemFrontmostAppObserverTests: XCTestCase {
    /// The bundle identifier of whatever is in front, or a skip.
    private func frontmostBundleID() throws -> String {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            throw XCTSkip("no app is frontmost here, which is the .undetermined case, not a failure")
        }
        return bundleID
    }

    func testTheAppThatIsActuallyInFrontReadsPresent() throws {
        let frontmost = try frontmostBundleID()
        XCTAssertEqual(SystemFrontmostAppObserver().isFrontmost(bundleID: frontmost), .present)
    }

    /// The distinction the whole condition rests on: running is not frontmost.
    /// Exactly one app can be in front, so every *other* running app must read
    /// `.absent` from the same observer, in the same instant.
    func testAnAppThatIsRunningButNotInFrontReadsAbsent() throws {
        let frontmost = try frontmostBundleID()
        let others = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { $0 != frontmost }
        guard let other = others.first else {
            throw XCTSkip("nothing else with a bundle identifier is running here")
        }
        XCTAssertEqual(SystemFrontmostAppObserver().isFrontmost(bundleID: other), .absent,
                       "\(other) is running, but \(frontmost) is the one in front")
    }

    func testAnAppThatIsNotRunningAtAllReadsAbsent() throws {
        _ = try frontmostBundleID()
        XCTAssertEqual(
            SystemFrontmostAppObserver().isFrontmost(bundleID: "au.com.workwireless.definitely-not-running"),
            .absent,
            "a successful read that found a different app in front is a confident negative")
    }
}

/// The matching and the memoization, against a scripted reader so the
/// `.undetermined` path can be asserted exactly rather than waited for.
final class MountedVolumeObserverContractTests: XCTestCase {
    private final class CountingReader: MountedVolumeReader {
        let result: MountedVolumeReading
        private(set) var reads = 0
        init(_ result: MountedVolumeReading) { self.result = result }
        func read() -> MountedVolumeReading {
            reads += 1
            return result
        }
    }

    /// The whole safety contract for this observer, in one line: an
    /// enumeration that failed is not an unmounted drive.
    func testAFailedEnumerationIsUndeterminedRatherThanUnmounted() {
        let observer = SystemMountedVolumeObserver(reader: CountingReader(.unavailable))
        XCTAssertEqual(observer.isMounted(volumeName: "Backup"), .undetermined,
                       "a volume list that could not be read says nothing about Backup")
    }

    func testASuccessfulEnumerationDistinguishesPresentFromAbsent() {
        let observer = SystemMountedVolumeObserver(
            reader: CountingReader(.names(["Macintosh HD", "Backup"])))
        XCTAssertEqual(observer.isMounted(volumeName: "Backup"), .present)
        XCTAssertEqual(observer.isMounted(volumeName: "Archive"), .absent)
    }

    /// Names are matched exactly, including case and spaces — the string is
    /// what Finder shows, and "backup" is not "Backup".
    func testNamesAreMatchedExactly() {
        let observer = SystemMountedVolumeObserver(reader: CountingReader(.names(["Time Machine"])))
        XCTAssertEqual(observer.isMounted(volumeName: "Time Machine"), .present)
        XCTAssertEqual(observer.isMounted(volumeName: "time machine"), .absent)
        XCTAssertEqual(observer.isMounted(volumeName: "TimeMachine"), .absent)
    }

    func testOneObserverEnumeratesAtMostOncePerTick() {
        let reader = CountingReader(.names(["Backup"]))
        let observer = SystemMountedVolumeObserver(reader: reader)
        for _ in 1...20 {
            _ = observer.isMounted(volumeName: "Backup")
            _ = observer.isMounted(volumeName: "Archive")
        }
        XCTAssertEqual(reader.reads, 1)
    }

    /// ...and the cache cannot go stale, because it does not outlive the
    /// observer, and `EvidenceLoopRunner` builds a new one every tick.
    func testANewObserverEnumeratesAgain() {
        let reader = CountingReader(.names(["Backup"]))
        _ = SystemMountedVolumeObserver(reader: reader).isMounted(volumeName: "Backup")
        _ = SystemMountedVolumeObserver(reader: reader).isMounted(volumeName: "Backup")
        XCTAssertEqual(reader.reads, 2)
    }
}

/// The live reader, against the volumes this Mac actually has mounted.
final class MountedVolumeURLsReaderTests: XCTestCase {
    private func names() throws -> Set<String> {
        guard case .names(let names) = MountedVolumeURLsReader().read() else {
            throw XCTSkip("the volume list could not be read at all, which is the .unavailable case")
        }
        return names
    }

    /// The read succeeds and contains the boot volume. `/` is always mounted
    /// and is never hidden, which is the fact the `.unavailable`-on-empty
    /// guard rests on — if this ever stops being true, that guard is wrong and
    /// this test is where it shows up.
    func testItContainsTheVolumeMountedAtTheRoot() throws {
        let root = try XCTUnwrap(
            (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName,
            "the root volume must have a name")
        XCTAssertTrue(try names().contains(root), "expected the boot volume (\"\(root)\") to be listed")
    }

    /// The reader must not offer the hidden system volumes — `VM`, `Preboot`,
    /// `Update`, `xART` and friends — as things a rule can name. They are not
    /// in Finder, so a user cannot mean them, and they would give the Add
    /// sheet's picker a list of nine rows nobody recognises.
    func testItDoesNotListTheHiddenSystemVolumes() throws {
        let listed = try names()
        for hidden in ["VM", "Preboot", "Update", "xART", "iSCPreboot"] {
            XCTAssertFalse(listed.contains(hidden), "\(hidden) is a hidden system volume")
        }
    }

    /// A successful read that found nothing matching is a confident negative,
    /// not a failure — the distinction the whole tri-state exists for.
    func testANameNothingCouldBeMountedUnderReadsAbsent() {
        XCTAssertEqual(
            SystemMountedVolumeObserver().isMounted(volumeName: "keepy-uppy-\(UUID().uuidString)"),
            .absent)
    }
}

/// The matching, the memoization, and the one place this observer's tri-state
/// differs from the other two — against a scripted reader, so all three are
/// asserted rather than inferred.
final class NetworkAddressObserverContractTests: XCTestCase {
    private final class CountingReader: NetworkAddressReader {
        let result: NetworkAddressReading
        private(set) var reads = 0
        init(_ result: NetworkAddressReading) { self.result = result }
        func read() -> NetworkAddressReading {
            reads += 1
            return result
        }
    }

    private func subnet(_ cidr: String) throws -> IPv4Subnet {
        try XCTUnwrap(IPv4Subnet(cidr: cidr))
    }

    private func address(_ dotted: String) throws -> UInt32 {
        try XCTUnwrap(IPv4Subnet(cidr: dotted)).network
    }

    func testAFailedGetifaddrsIsUndeterminedRatherThanADifferentSubnet() throws {
        let observer = SystemNetworkAddressObserver(reader: CountingReader(.unavailable))
        XCTAssertEqual(observer.isOnSubnet(try subnet("192.168.1.0/24")), .undetermined,
                       "an interface list that could not be read says nothing about where this Mac is")
    }

    /// **The deliberate difference from `SystemMountedVolumeObserver` and
    /// `SystemAppRunningObserver`, whose empty lists are `.undetermined`.** A
    /// Mac with Wi-Fi off and no cable genuinely holds no non-loopback IPv4
    /// address, and that is exactly "not on that subnet" — a confident
    /// negative, which correctly ends a `.whileOnSubnet` session. There is no
    /// always-present member here to make emptiness impossible, the way `/`
    /// and this very process are for those two.
    func testNoAddressesAtAllIsAConfidentNegativeRatherThanAFailure() throws {
        let observer = SystemNetworkAddressObserver(reader: CountingReader(.addresses([])))
        XCTAssertEqual(observer.isOnSubnet(try subnet("192.168.1.0/24")), .absent)
    }

    func testASuccessfulReadDistinguishesInsideFromOutside() throws {
        let observer = SystemNetworkAddressObserver(
            reader: CountingReader(.addresses([try address("192.168.1.50")])))
        XCTAssertEqual(observer.isOnSubnet(try subnet("192.168.1.0/24")), .present)
        XCTAssertEqual(observer.isOnSubnet(try subnet("192.168.1.50")), .present, "a bare address is a /32")
        XCTAssertEqual(observer.isOnSubnet(try subnet("10.0.0.0/8")), .absent)
    }

    /// A Mac on two networks at once — Ethernet and a VPN tunnel, which is the
    /// ordinary case, not an exotic one — is on *both*, and a rule naming
    /// either must match.
    func testAnyOneOfSeveralAddressesIsEnough() throws {
        let observer = SystemNetworkAddressObserver(reader: CountingReader(
            .addresses([try address("192.168.86.26"), try address("100.78.130.78")])))
        XCTAssertEqual(observer.isOnSubnet(try subnet("192.168.86.0/24")), .present)
        XCTAssertEqual(observer.isOnSubnet(try subnet("100.64.0.0/10")), .present)
        XCTAssertEqual(observer.isOnSubnet(try subnet("172.16.0.0/12")), .absent)
    }

    func testOneObserverReadsTheInterfaceListAtMostOncePerTick() throws {
        let reader = CountingReader(.addresses([try address("192.168.1.50")]))
        let observer = SystemNetworkAddressObserver(reader: reader)
        for _ in 1...20 {
            _ = observer.isOnSubnet(try subnet("192.168.1.0/24"))
            _ = observer.isOnSubnet(try subnet("10.0.0.0/8"))
        }
        XCTAssertEqual(reader.reads, 1)
    }

    func testANewObserverReadsAgain() throws {
        let reader = CountingReader(.addresses([]))
        _ = SystemNetworkAddressObserver(reader: reader).isOnSubnet(try subnet("192.168.1.0/24"))
        _ = SystemNetworkAddressObserver(reader: reader).isOnSubnet(try subnet("192.168.1.0/24"))
        XCTAssertEqual(reader.reads, 2)
    }
}

/// The live `getifaddrs` reader, against this Mac's real interfaces.
final class GetifaddrsNetworkAddressReaderTests: XCTestCase {
    private func addresses() throws -> Set<UInt32> {
        guard case .addresses(let addresses) = GetifaddrsNetworkAddressReader().read() else {
            throw XCTSkip("getifaddrs failed, which is the .unavailable case rather than a defect here")
        }
        return addresses
    }

    /// Loopback is skipped, and this is the test that matters most for a
    /// machine with no network: 127.0.0.1 exists on every Mac that has ever
    /// booted, so leaving it in would make a `/0` rule — or a `127.0.0.0/8`
    /// one — hold a Mac awake forever with nothing plugged in.
    func testLoopbackIsNotReported() throws {
        let loopback = try XCTUnwrap(IPv4Subnet(cidr: "127.0.0.0/8"))
        XCTAssertFalse(try addresses().contains(where: loopback.contains),
                       "127.0.0.1 must not count as being on a network")
    }

    /// Every address reported has to be one this Mac can actually be asked
    /// about, and the round trip through `IPv4Subnet` is what proves the byte
    /// order is right: a `sin_addr` left in network order would come back with
    /// its octets reversed, so `192.168.86.26` would answer to `26.86.168.192`
    /// and every real rule would silently never match.
    func testEachAddressIsInsideItsOwnSlash32AndItsOwnSlash24() throws {
        for address in try addresses() {
            let octets = (0..<4).map { (address >> (24 - 8 * $0)) & 0xFF }
            let dotted = octets.map(String.init).joined(separator: ".")
            let ownSlash32 = try XCTUnwrap(IPv4Subnet(cidr: dotted))
            let ownSlash24 = try XCTUnwrap(IPv4Subnet(cidr: "\(octets[0]).\(octets[1]).\(octets[2]).0/24"))
            XCTAssertTrue(ownSlash32.contains(address), dotted)
            XCTAssertTrue(ownSlash24.contains(address), dotted)
        }
    }

    /// The live observer answering two different questions in the same
    /// instant: the block this Mac is genuinely on, and a block reserved by
    /// RFC 5737 for documentation that it cannot be on. Skipped rather than
    /// failed when this Mac has no network — which is a legitimate state, and
    /// one CI can be in.
    func testTheLiveObserverSeparatesTheNetworkThisMacIsOnFromOneItIsNot() throws {
        guard let address = try addresses().first else {
            throw XCTSkip("this Mac holds no non-loopback IPv4 address, so there is nothing to be on")
        }
        let octets = (0..<4).map { (address >> (24 - 8 * $0)) & 0xFF }
        let mine = try XCTUnwrap(IPv4Subnet(cidr: "\(octets[0]).\(octets[1]).\(octets[2]).0/24"))
        // TEST-NET-3: reserved for documentation, so no interface can hold one.
        let notMine = try XCTUnwrap(IPv4Subnet(cidr: "203.0.113.0/24"))

        let observer = SystemNetworkAddressObserver()
        XCTAssertEqual(observer.isOnSubnet(mine), .present)
        XCTAssertEqual(observer.isOnSubnet(notMine), .absent,
                       "a successful read that found nothing matching is a confident negative")
    }
}

/// The memoization and failure behaviour, against a fake table reader so they
/// can be asserted exactly rather than inferred.
final class VPNObserverContractTests: XCTestCase {
    private final class CountingReader: VPNServiceReader {
        let result: VPNServiceReading
        private(set) var reads = 0
        init(_ result: VPNServiceReading) { self.result = result }
        func read() -> VPNServiceReading {
            reads += 1
            return result
        }
    }

    func testAFailedConfigurationReadIsUndeterminedRatherThanNoVPN() {
        XCTAssertEqual(SystemVPNObserver(reader: CountingReader(.unavailable)).isVPNActive(), .undetermined,
                       "a dynamic store that would not answer says nothing about the tunnel")
    }

    /// **The deliberate difference from `SystemMountedVolumeObserver`, and the
    /// same call `SystemNetworkAddressObserver` makes.** A Mac with no VPN
    /// configured — or with one configured and disconnected — genuinely has no
    /// VPN up, and that is exactly "the tunnel is down": a confident negative,
    /// which correctly ends a `.whileVPNActive` session. There is no
    /// always-present member to make emptiness impossible here, the way `/` is
    /// for volumes and this process is for `runningApplications`.
    func testNoLiveVPNServiceIsAConfidentNegativeRatherThanAFailure() {
        XCTAssertEqual(SystemVPNObserver(reader: CountingReader(.liveServiceIDs([]))).isVPNActive(), .absent)
    }

    func testAnyLiveVPNServiceIsEnough() {
        XCTAssertEqual(SystemVPNObserver(reader: CountingReader(.liveServiceIDs(["A"]))).isVPNActive(), .present)
        XCTAssertEqual(SystemVPNObserver(reader: CountingReader(.liveServiceIDs(["A", "B"]))).isVPNActive(), .present,
                       "two tunnels at once is still a tunnel")
    }

    func testOneObserverReadsTheConfigurationAtMostOncePerTick() {
        let reader = CountingReader(.liveServiceIDs(["A"]))
        let observer = SystemVPNObserver(reader: reader)
        for _ in 1...20 { _ = observer.isVPNActive() }
        XCTAssertEqual(reader.reads, 1)
    }

    func testANewObserverReadsAgain() {
        let reader = CountingReader(.liveServiceIDs([]))
        _ = SystemVPNObserver(reader: reader).isVPNActive()
        _ = SystemVPNObserver(reader: reader).isVPNActive()
        XCTAssertEqual(reader.reads, 2)
    }
}

/// The live `SCDynamicStore` reader, against this Mac's real network services.
///
/// The reading it produces is machine-dependent by nature — whether a VPN is up
/// right now is not something a test can arrange — so these pin the things that
/// are true either way, and `.superpowers/sdd/plan5-vpn-research.md` carries the
/// measurements taken with a real VPN connected.
final class SCDynamicStoreVPNServiceReaderTests: XCTestCase {
    /// The key parse, which is the one piece of this reader that can be checked
    /// exactly. A wrong component index would silently produce identifiers that
    /// match nothing, and the observer would then answer `.absent` forever —
    /// ending every `.whileVPNActive` session on a Mac whose VPN is up.
    func testTheServiceIdentifierIsTakenFromTheRightPathComponent() {
        let parse = SCDynamicStoreVPNServiceReader.serviceID(inKey:)
        XCTAssertEqual(parse("Setup:/Network/Service/ABC-123/Interface"), "ABC-123")
        XCTAssertEqual(parse("State:/Network/Service/ABC-123/IPv4"), "ABC-123")
        XCTAssertEqual(parse("State:/Network/Service/ABC-123/IPv6"), "ABC-123")
        XCTAssertEqual(parse("State:/Network/Service/ABC-123"), "ABC-123",
                       "the bare service key carries the same identifier")
    }

    func testAKeyWithNoServiceIdentifierIsRefusedRatherThanGuessedAt() {
        let parse = SCDynamicStoreVPNServiceReader.serviceID(inKey:)
        XCTAssertNil(parse("State:/Network/Global/IPv4"))
        XCTAssertNil(parse("State:/Network/Service/"), "an empty component is not an identifier")
        XCTAssertNil(parse(""))
    }

    /// Three of the five are `kSCNetworkInterfaceType*` constants and one
    /// (`VPN`) has no public constant at all, which is why the set is written
    /// out rather than derived. This pins that the undocumented one — the type
    /// every NetworkExtension VPN actually reports, and therefore the only one
    /// that matters on a modern Mac — is in it.
    func testTheVPNInterfaceTypesCoverTheModernAndTheLegacyOnes() {
        let types = SCDynamicStoreVPNServiceReader.vpnInterfaceTypes
        XCTAssertTrue(types.contains("VPN"), "every NetworkExtension VPN reports this type")
        XCTAssertTrue(types.contains(kSCNetworkInterfaceTypePPP as String))
        XCTAssertTrue(types.contains(kSCNetworkInterfaceTypeIPSec as String))
        XCTAssertTrue(types.contains(kSCNetworkInterfaceTypeL2TP as String))
        XCTAssertFalse(types.contains(kSCNetworkInterfaceTypeEthernet as String),
                       "an Ethernet service is not a VPN")
        XCTAssertFalse(types.contains(kSCNetworkInterfaceTypeIEEE80211 as String),
                       "Wi-Fi is not a VPN")
    }

    /// The live read must at least *complete* and answer one of its two cases
    /// on a real Mac. A crash, a hang, or a permission failure here would be
    /// the whole feature, and this runs every 5s for as long as the agent
    /// lives.
    func testTheLiveReadAnswersWithoutFailing() throws {
        guard case .liveServiceIDs(let ids) = SCDynamicStoreVPNServiceReader().read() else {
            throw XCTSkip("the dynamic store declined, which is the .unavailable case rather than a defect")
        }
        // Whatever this Mac's VPN state is, an identifier that came back has to
        // be one the store could be asked about again.
        for id in ids { XCTAssertFalse(id.isEmpty) }
    }

    /// The observer built on the live reader agrees with the reader, which is
    /// the join the memoization could break.
    func testTheLiveObserverAgreesWithTheLiveReader() throws {
        guard case .liveServiceIDs(let ids) = SCDynamicStoreVPNServiceReader().read() else {
            throw XCTSkip("the dynamic store declined")
        }
        XCTAssertEqual(SystemVPNObserver().isVPNActive(), ConditionReading(!ids.isEmpty))
    }

    /// Every tunnel-named interface this Mac holds, which is what the rejected
    /// heuristic would have counted. Nine of them on the machine this was
    /// written on, of which exactly one was a VPN.
    private func tunnelInterfaceNames() throws -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw XCTSkip("getifaddrs failed") }
        defer { freeifaddrs(head) }
        var tunnels: Set<String> = []
        var cursor = head
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            cursor = entry.pointee.ifa_next
            if ["utun", "ppp", "ipsec", "tap"].contains(where: name.hasPrefix) { tunnels.insert(name) }
        }
        return tunnels
    }

    /// A VPN that is up owns a tunnel interface, so the read cannot report one
    /// where there are none. The direction that can be asserted on any machine
    /// in any state, and it would catch a read that had started returning
    /// something other than live VPN services.
    func testALiveVPNServiceImpliesATunnelInterfaceExists() throws {
        guard case .liveServiceIDs(let live) = SCDynamicStoreVPNServiceReader().read() else {
            throw XCTSkip("the dynamic store declined")
        }
        guard !live.isEmpty else { return }
        XCTAssertFalse(try tunnelInterfaceNames().isEmpty,
                       "\(live.count) live VPN service(s) but no tunnel interface to carry them")
    }

    /// The whole point of the condition, stated as a test: tunnel interfaces
    /// existing is **not** what makes this `.present`. Nine exist on a Mac with
    /// one VPN, and `utun0`–`utun3` exist on essentially every Mac with none.
    ///
    /// Skipped rather than failed when a VPN genuinely is up, because then both
    /// the real read and the rejected heuristic answer `.present` for good
    /// reasons and there is nothing to tell apart. The measurement that *did*
    /// separate them — eight non-VPN tunnels contributing nothing while one VPN
    /// was connected — is in `.superpowers/sdd/plan5-vpn-research.md`, because
    /// no test can arrange either half of it.
    func testTunnelInterfacesAloneDoNotMakeTheReadPresent() throws {
        let tunnels = try tunnelInterfaceNames()
        guard !tunnels.isEmpty else {
            throw XCTSkip("this Mac holds no tunnel-named interface, so there is no false positive to rule out")
        }
        guard case .liveServiceIDs(let live) = SCDynamicStoreVPNServiceReader().read() else {
            throw XCTSkip("the dynamic store declined")
        }
        guard live.isEmpty else {
            throw XCTSkip("a VPN really is up here (\(tunnels.count) tunnel interfaces, "
                          + "\(live.count) live VPN service(s)), so both reads agree for a good reason")
        }
        XCTAssertEqual(SystemVPNObserver().isVPNActive(), .absent,
                       "\(tunnels.sorted()) exist and none of them is a VPN")
    }
}

final class USBDeviceIDTests: XCTestCase {
    func testTheFormsPeopleActuallyWriteAllParseToTheSamePair() throws {
        let apple = USBDeviceID(vendorID: 0x05ac, productID: 0x024f)
        for text in ["05ac:024f", "0x05ac:0x024f", "0X05AC:0X024F", "5ac:24f", "05AC:024F"] {
            XCTAssertEqual(USBDeviceID(text: text), apple, text)
        }
    }

    func testTheShapeIsRefusedRatherThanGuessedAt() {
        for bad in ["", "05ac", "05ac:", ":024f", "::", "05ac:024f:0", "zzzz:024f", "05ac:zzzz",
                    "05ac024f", "12345:024f", "05ac:12345", " 05ac:024f", "05ac: 024f", "0x:0x"] {
            XCTAssertNil(USBDeviceID(text: bad), "'\(bad)' is not a device identifier")
        }
    }

    /// Zero-padded, lowercase, four digits each — the form every USB tool
    /// prints, so a value copied out of one of them goes straight back in.
    func testTheTextFormIsPaddedAndRoundTrips() {
        XCTAssertEqual(USBDeviceID(vendorID: 0x05ac, productID: 0x024f).text, "0x05ac:0x024f")
        XCTAssertEqual(USBDeviceID(vendorID: 0, productID: 0).text, "0x0000:0x0000")
        XCTAssertEqual(USBDeviceID(vendorID: 0xffff, productID: 0xffff).text, "0xffff:0xffff")
        for id in [USBDeviceID(vendorID: 0x05ac, productID: 0x024f),
                   USBDeviceID(vendorID: 0, productID: 0xbeef),
                   USBDeviceID(vendorID: 0xffff, productID: 1)] {
            XCTAssertEqual(USBDeviceID(text: id.text), id)
        }
    }

    /// Hexadecimal always, with no decimal fallback — stated as a test so that
    /// nobody "helpfully" adds one. `1452:591` is the decimal spelling of
    /// Apple's `05ac:024f`, and it must **not** parse to the same pair: there
    /// is nothing in the string to tell the two readings apart, so guessing
    /// would silently produce a rule for a different device.
    func testTheDecimalSpellingIsNotQuietlyAccepted() {
        XCTAssertNotEqual(USBDeviceID(text: "1452:591"), USBDeviceID(vendorID: 0x05ac, productID: 0x024f))
        XCTAssertEqual(USBDeviceID(text: "1452:591"), USBDeviceID(vendorID: 0x1452, productID: 0x0591))
    }
}

final class USBDeviceObserverContractTests: XCTestCase {
    private final class CountingReader: USBDeviceReader {
        let result: USBDeviceReading
        private(set) var reads = 0
        init(_ result: USBDeviceReading) { self.result = result }
        func read() -> USBDeviceReading {
            reads += 1
            return result
        }
    }

    private func device(_ text: String, name: String? = nil) -> AttachedUSBDevice {
        AttachedUSBDevice(id: USBDeviceID(text: text)!, name: name)
    }

    func testAFailedEnumerationIsUndeterminedRatherThanUnplugged() {
        XCTAssertEqual(SystemUSBDeviceObserver(reader: CountingReader(.unavailable))
                        .isPresent(vendorID: 0x05ac, productID: 0x024f), .undetermined,
                       "a registry that could not be enumerated says nothing about what is plugged in")
    }

    /// **The deliberate difference from `SystemMountedVolumeObserver`, and the
    /// same call `SystemNetworkAddressObserver` makes.** A laptop with nothing
    /// plugged into it genuinely has no USB devices — measured: three host
    /// controllers and zero devices on the machine this was written on, agreed
    /// by `ioreg` and `system_profiler`. There is no always-present member to
    /// make emptiness impossible, the way `/` is for volumes.
    func testAnEmptyUSBTreeIsAConfidentNegativeRatherThanAFailure() {
        XCTAssertEqual(SystemUSBDeviceObserver(reader: CountingReader(.attached([])))
                        .isPresent(vendorID: 0x05ac, productID: 0x024f), .absent)
    }

    /// **Both** identifiers, not either. Matching the vendor alone would hold a
    /// Mac awake for any peripheral from the same manufacturer.
    func testBothIdentifiersHaveToMatch() {
        let observer = SystemUSBDeviceObserver(reader: CountingReader(
            .attached([device("05ac:024f", name: "Magic Keyboard")])))
        XCTAssertEqual(observer.isPresent(vendorID: 0x05ac, productID: 0x024f), .present)
        XCTAssertEqual(observer.isPresent(vendorID: 0x05ac, productID: 0x0250), .absent,
                       "same vendor, different product")
        XCTAssertEqual(observer.isPresent(vendorID: 0x1234, productID: 0x024f), .absent,
                       "same product id, different vendor")
    }

    /// The name plays no part in matching — two identical dongles report the
    /// same one, and plenty of devices report none.
    func testANamelessDeviceStillMatches() {
        let observer = SystemUSBDeviceObserver(reader: CountingReader(
            .attached([device("05ac:024f", name: nil)])))
        XCTAssertEqual(observer.isPresent(vendorID: 0x05ac, productID: 0x024f), .present)
    }

    func testOneObserverEnumeratesAtMostOncePerTick() {
        let reader = CountingReader(.attached([device("05ac:024f")]))
        let observer = SystemUSBDeviceObserver(reader: reader)
        for _ in 1...20 {
            _ = observer.isPresent(vendorID: 0x05ac, productID: 0x024f)
            _ = observer.isPresent(vendorID: 0xdead, productID: 0xbeef)
        }
        XCTAssertEqual(reader.reads, 1)
    }

    func testANewObserverEnumeratesAgain() {
        let reader = CountingReader(.attached([]))
        _ = SystemUSBDeviceObserver(reader: reader).isPresent(vendorID: 1, productID: 2)
        _ = SystemUSBDeviceObserver(reader: reader).isPresent(vendorID: 1, productID: 2)
        XCTAssertEqual(reader.reads, 2)
    }
}

/// The live IOKit reader, against this Mac's real USB tree.
///
/// **The machine this was written on had nothing plugged in**, so the "a real
/// device appears with readable identifiers" half is a manual-checklist item
/// rather than a test — see `.superpowers/sdd/plan5-device-research.md`, which
/// records how the enumeration machinery and the device class were established
/// instead (the same code path against a class with instances, and ten shipping
/// kexts that declare `IOUSBHostDevice` as their provider). These pin what is
/// true whatever is attached.
final class IOKitUSBDeviceReaderTests: XCTestCase {
    private func attached() throws -> [AttachedUSBDevice] {
        guard case .attached(let devices) = IOKitUSBDeviceReader().read() else {
            throw XCTSkip("the USB tree could not be enumerated, which is the .unavailable case")
        }
        return devices
    }

    /// The class name, pinned. `kIOUSBDeviceClassName` no longer exists in this
    /// SDK, and the near-miss is not hypothetical: `IOUSBHostController` matches
    /// **nothing** on Apple Silicon despite three host controllers being
    /// present, because the class chain runs through `AppleUSBHostController`.
    func testTheClassNameIsTheOneThisSDKStillHas() {
        XCTAssertEqual(kIOUSBHostDeviceClassName, "IOUSBHostDevice")
    }

    /// The two property names, quoted from `IOUSBHostFamilyDefinitions.h`. A
    /// typo in either would make every device report no identifiers, which this
    /// reader treats as a per-device shortfall — so the observer would answer
    /// `.absent` forever rather than failing loudly.
    func testThePropertyNamesAreTheOnesIOKitPublishes() {
        XCTAssertEqual(IOKitUSBDeviceReader.vendorIDProperty, kUSBHostMatchingPropertyVendorID)
        XCTAssertEqual(IOKitUSBDeviceReader.productIDProperty, kUSBHostMatchingPropertyProductID)
    }

    /// A Mac with nothing plugged in is `.attached([])`, not `.unavailable` —
    /// the read has to *complete* whatever the answer is. This runs every 5s
    /// for as long as the agent lives.
    func testTheLiveReadCompletes() throws {
        _ = try attached()
    }

    /// Whatever is attached, every device it reports must be one a rule could
    /// actually name: identifiers inside `UInt16`, and a name that is either
    /// absent or non-empty rather than a blank string that would render as a
    /// nameless row.
    func testEveryDeviceReportedIsOneARuleCouldName() throws {
        for device in try attached() {
            XCTAssertEqual(USBDeviceID(text: device.id.text), device.id, device.id.text)
            if let name = device.name { XCTAssertFalse(name.isEmpty, device.id.text) }
        }
    }

    /// The live observer agrees with the live reader — the join the
    /// memoization could break — and a made-up pair is a confident negative
    /// rather than a failure.
    func testTheLiveObserverAgreesWithTheLiveReader() throws {
        let devices = try attached()
        let observer = SystemUSBDeviceObserver()
        for device in devices {
            XCTAssertEqual(observer.isPresent(vendorID: device.id.vendorID,
                                              productID: device.id.productID), .present,
                           device.id.text)
        }
        XCTAssertEqual(SystemUSBDeviceObserver().isPresent(vendorID: 0xdead, productID: 0xbeef), .absent,
                       "a successful enumeration that found no match is a confident negative")
    }

    /// The display helper's fallback, against the live tree: a pair nothing can
    /// be reporting renders as its identifiers rather than as an empty string.
    func testTheDisplayHelperFallsBackToTheIdentifiers() {
        XCTAssertEqual(usbDeviceDisplayName(vendorID: 0xdead, productID: 0xbeef), "0xdead:0xbeef")
    }
}

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
