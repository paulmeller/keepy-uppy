import XCTest
@testable import KeepyUppy

/// Security review (refcount-before-proof): the daemon used to increment
/// `DaemonRuntime`'s liveness refcounts inside
/// `shouldAcceptNewConnection`, but XPC adjudicates the peer's code-signing
/// requirement *after* accept — so any local process could hold those counts
/// above zero without ever satisfying the requirement. The increment now
/// happens when the connection proves itself (a message reaching
/// `HelperService`), and `ConnectionProofLatch` is the piece that decides,
/// once, whether that has happened.
///
/// The `Helper/` wiring around it is not reachable from this test target
/// (`Helper` is compiled only into the daemon), which is exactly why the
/// primitive lives in `Shared/`: the exactly-once property everything else
/// rests on is testable here even though the XPC plumbing is not.
///
/// The property under test is *balance*: a refcount must be decremented
/// exactly once if it was ever incremented, and never otherwise. A skipped
/// decrement after a real prove leaks a connection's count forever (the Mac
/// never sleeps again); a decrement nobody incremented ends sessions that
/// should have lived.
///
/// Balance has two halves, and the second is the one a `Bool`-returning latch
/// silently failed. Every test up to `testProofAndTeardownRacingNeverDecrement…`
/// asserts that the latch's *decisions* balance, which they do either way.
/// `testRacingProveAndTeardownNeverStrandTheRefcount…` at the bottom asserts
/// that the decisions' *effects* balance — that is what forces the refcount
/// work to run under the latch's lock rather than after it.
final class ConnectionProofLatchTests: XCTestCase {

    // MARK: - prove → release: the ordinary life of a legitimate connection

    func testFirstProofSucceedsAndIsTheOnlyOne() {
        let latch = ConnectionProofLatch()
        XCTAssertTrue(latch.provedNow(), "the first message on a connection must be the one that counts it")
        XCTAssertFalse(latch.provedNow(), "a second message must not count the same connection twice")
        XCTAssertFalse(latch.provedNow())
    }

    func testReleaseAfterProofSucceedsExactlyOnce() {
        let latch = ConnectionProofLatch()
        XCTAssertTrue(latch.provedNow())
        XCTAssertTrue(latch.releasedNow(), "a proven connection must decrement when it goes away")
        // `invalidationHandler` and `interruptionHandler` can both fire for
        // one connection; only the first may decrement.
        XCTAssertFalse(latch.releasedNow(), "the second teardown callback must not decrement again")
        XCTAssertFalse(latch.releasedNow())
    }

    func testManyMessagesThenTeardownStillDecrementsOnce() {
        let latch = ConnectionProofLatch()
        let proofs = (0..<50).filter { _ in latch.provedNow() }.count
        XCTAssertEqual(proofs, 1, "a chatty client is still one connection")
        XCTAssertTrue(latch.releasedNow())
        XCTAssertFalse(latch.releasedNow())
    }

    // MARK: - release without prove: the rogue that never satisfied the requirement

    func testReleaseWithoutProofDoesNotDecrement() {
        let latch = ConnectionProofLatch()
        XCTAssertFalse(latch.releasedNow(),
                       "a connection that was accepted but never proved itself incremented nothing, so it must decrement nothing")
        XCTAssertFalse(latch.releasedNow())
    }

    func testProofAfterReleaseIsRefused() {
        // Prove and release genuinely race: a message can be in flight while
        // the connection tears down. If teardown wins, the latch is terminal
        // — counting afterwards would increment a refcount that nothing is
        // left to decrement, since teardown runs at most once.
        let latch = ConnectionProofLatch()
        XCTAssertFalse(latch.releasedNow())
        XCTAssertFalse(latch.provedNow(), "a released connection must never be counted late")
        XCTAssertFalse(latch.releasedNow(), "and must still not decrement")
    }

    // MARK: - thread safety: XPC callbacks arrive on arbitrary threads

    func testConcurrentProofsCountTheConnectionExactlyOnce() {
        for _ in 0..<200 {
            let latch = ConnectionProofLatch()
            let counter = WinCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if latch.provedNow() { counter.record() }
            }
            XCTAssertEqual(counter.value, 1, "concurrent messages on one connection must increment once")
        }
    }

    func testConcurrentReleasesDecrementExactlyOnce() {
        for _ in 0..<200 {
            let latch = ConnectionProofLatch()
            XCTAssertTrue(latch.provedNow())
            let counter = WinCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if latch.releasedNow() { counter.record() }
            }
            XCTAssertEqual(counter.value, 1, "invalidation and interruption together must decrement once")
        }
    }

    func testProofAndTeardownRacingNeverDecrementWithoutIncrementing() {
        // The invariant that actually matters under concurrency, whichever
        // side wins: at most one increment, at most one decrement, and never
        // a decrement without a matching increment.
        for _ in 0..<500 {
            let latch = ConnectionProofLatch()
            let proofs = WinCounter()
            let releases = WinCounter()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index.isMultiple(of: 2) {
                    if latch.provedNow() { proofs.record() }
                } else {
                    if latch.releasedNow() { releases.record() }
                }
            }
            // Drain any straggler teardown, exactly as the real
            // invalidation/interruption pair would.
            if latch.releasedNow() { releases.record() }

            XCTAssertLessThanOrEqual(proofs.value, 1)
            XCTAssertLessThanOrEqual(releases.value, 1)
            XCTAssertEqual(releases.value, proofs.value,
                           "every counted connection must be uncounted exactly once, and an uncounted one never")
        }
    }

    // MARK: - ordering: the decisions balancing is not enough

    func testRacingProveAndTeardownNeverStrandTheRefcountTheyMutate() {
        // Every test above passes against a latch that decides under its lock
        // and lets the caller act *after* releasing it — and that latch
        // strands refcounts. Deciding "prove happened first" does not stop the
        // teardown thread, parked on `lock.lock()` and woken by prove's
        // unlock, from reaching `DaemonRuntime` first. So this asserts on the
        // counter the bodies mutate, not on which body ran.
        //
        // `RefcountedRuntime` mirrors the two properties that make the strand
        // permanent rather than self-correcting:
        //   - the mutation goes through a serial queue, as every
        //     `DaemonRuntime` method does (`queue.sync`). That dispatch is the
        //     reordering point: once both threads are past the latch, whichever
        //     enqueues first wins.
        //   - the decrement clamps at zero, as `DaemonRuntime.decrementToZero`
        //     does. A decrement that lands first is therefore *lost*, not
        //     netted off against the increment behind it, and the count is
        //     left at 1 with the connection dead and its one teardown spent.
        let trials = 2_000
        let pool = DispatchQueue(label: "connection-proof-latch-race", attributes: .concurrent)
        var strandedTrials = 0

        for trial in 0..<trials {
            let latch = ConnectionProofLatch()
            let runtime = RefcountedRuntime()
            // Both orderings, alternating, so neither side is systematically
            // the one that gets to the latch first.
            let proveIsIndexZero = trial.isMultiple(of: 2)
            let gate = StartGate(parties: 2)
            let group = DispatchGroup()

            for index in 0..<2 {
                pool.async(group: group) {
                    // Line the two threads up so they hit the latch as close
                    // to simultaneously as the scheduler allows: this is the
                    // maximal-contention case, where one genuinely blocks on
                    // the other's lock.
                    gate.arriveAndWait()
                    if (index == 0) == proveIsIndexZero {
                        latch.proveOnce { runtime.increment() }
                    } else {
                        latch.releaseOnce { runtime.decrementToZero() }
                    }
                }
            }
            group.wait()
            // Drain the straggler teardown, exactly as the real
            // invalidation/interruption pair would.
            latch.releaseOnce { runtime.decrementToZero() }

            if runtime.value != 0 { strandedTrials += 1 }
        }

        XCTAssertEqual(
            strandedTrials, 0,
            "a connection's refcount must come back to zero however prove and teardown interleave, but \(strandedTrials) of \(trials) trials left it stranded above baseline — an increment applied after the connection's one teardown had already been spent, which nothing will ever decrement")
    }
}

/// Reduces a call back to the decision it made — did the body run? — so the
/// tests above that are only about *which* caller wins stay one-liners.
///
/// Deliberately test-only. The daemon must never ask the latch a question and
/// then act on the answer outside the lock; that is precisely the shape this
/// round removed, and `testRacingProveAndTeardownNeverStrandTheRefcountTheyMutate`
/// pointedly does not use these.
private extension ConnectionProofLatch {
    func provedNow() -> Bool {
        var ran = false
        proveOnce { ran = true }
        return ran
    }

    func releasedNow() -> Bool {
        var ran = false
        releaseOnce { ran = true }
        return ran
    }
}

/// The part of `DaemonRuntime` the latch's bodies actually touch: a refcount
/// mutated behind a serial queue, whose decrement clamps at zero
/// (`DaemonRuntime.decrementToZero`) instead of going negative. Both details
/// are load-bearing — see the test above.
private final class RefcountedRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "connection-proof-latch-test.runtime")
    private var count = 0

    /// Stands in for `clientConnected` / `agentConnectionOpened`.
    func increment() { queue.sync { count += 1 } }

    /// Stands in for `clientDisconnected` / `agentConnectionClosed`.
    func decrementToZero() { queue.sync { count = max(0, count - 1) } }

    var value: Int { queue.sync { count } }
}

/// A two-party barrier, so the racing threads start together rather than
/// whenever the thread pool gets round to each. Spins first (the point is to
/// release both within nanoseconds of each other), then falls back to yielding
/// so a constrained scheduler can never turn the wait into a livelock.
private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let parties: Int
    private var arrived = 0

    init(parties: Int) { self.parties = parties }

    func arriveAndWait() {
        lock.lock()
        arrived += 1
        lock.unlock()

        var spins = 0
        while true {
            lock.lock()
            let ready = arrived >= parties
            lock.unlock()
            if ready { return }
            spins += 1
            if spins > 10_000 { sched_yield() }
        }
    }
}

/// A counter safe to bump from several threads at once, so a test can assert
/// how many callers a latch let through. Not part of the fix — the latch under
/// test must not be used to police its own test.
private final class WinCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
