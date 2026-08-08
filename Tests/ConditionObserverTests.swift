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
