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
/// exactly once if it was ever incremented, and never otherwise. A single
/// spurious `false` from `releaseOnce()` after a real prove leaks a
/// connection's count forever (the Mac never sleeps again); a single spurious
/// `true` decrements a count nobody incremented (ending sessions that should
/// have lived).
final class ConnectionProofLatchTests: XCTestCase {

    // MARK: - prove → release: the ordinary life of a legitimate connection

    func testFirstProofSucceedsAndIsTheOnlyOne() {
        let latch = ConnectionProofLatch()
        XCTAssertTrue(latch.proveOnce(), "the first message on a connection must be the one that counts it")
        XCTAssertFalse(latch.proveOnce(), "a second message must not count the same connection twice")
        XCTAssertFalse(latch.proveOnce())
    }

    func testReleaseAfterProofSucceedsExactlyOnce() {
        let latch = ConnectionProofLatch()
        XCTAssertTrue(latch.proveOnce())
        XCTAssertTrue(latch.releaseOnce(), "a proven connection must decrement when it goes away")
        // `invalidationHandler` and `interruptionHandler` can both fire for
        // one connection; only the first may decrement.
        XCTAssertFalse(latch.releaseOnce(), "the second teardown callback must not decrement again")
        XCTAssertFalse(latch.releaseOnce())
    }

    func testManyMessagesThenTeardownStillDecrementsOnce() {
        let latch = ConnectionProofLatch()
        let proofs = (0..<50).filter { _ in latch.proveOnce() }.count
        XCTAssertEqual(proofs, 1, "a chatty client is still one connection")
        XCTAssertTrue(latch.releaseOnce())
        XCTAssertFalse(latch.releaseOnce())
    }

    // MARK: - release without prove: the rogue that never satisfied the requirement

    func testReleaseWithoutProofDoesNotDecrement() {
        let latch = ConnectionProofLatch()
        XCTAssertFalse(latch.releaseOnce(),
                       "a connection that was accepted but never proved itself incremented nothing, so it must decrement nothing")
        XCTAssertFalse(latch.releaseOnce())
    }

    func testProofAfterReleaseIsRefused() {
        // Prove and release genuinely race: a message can be in flight while
        // the connection tears down. If teardown wins, the latch is terminal
        // — counting afterwards would increment a refcount that nothing is
        // left to decrement, since teardown runs at most once.
        let latch = ConnectionProofLatch()
        XCTAssertFalse(latch.releaseOnce())
        XCTAssertFalse(latch.proveOnce(), "a released connection must never be counted late")
        XCTAssertFalse(latch.releaseOnce(), "and must still not decrement")
    }

    // MARK: - thread safety: XPC callbacks arrive on arbitrary threads

    func testConcurrentProofsCountTheConnectionExactlyOnce() {
        for _ in 0..<200 {
            let latch = ConnectionProofLatch()
            let counter = WinCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if latch.proveOnce() { counter.record() }
            }
            XCTAssertEqual(counter.value, 1, "concurrent messages on one connection must increment once")
        }
    }

    func testConcurrentReleasesDecrementExactlyOnce() {
        for _ in 0..<200 {
            let latch = ConnectionProofLatch()
            XCTAssertTrue(latch.proveOnce())
            let counter = WinCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if latch.releaseOnce() { counter.record() }
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
                    if latch.proveOnce() { proofs.record() }
                } else {
                    if latch.releaseOnce() { releases.record() }
                }
            }
            // Drain any straggler teardown, exactly as the real
            // invalidation/interruption pair would.
            if latch.releaseOnce() { releases.record() }

            XCTAssertLessThanOrEqual(proofs.value, 1)
            XCTAssertLessThanOrEqual(releases.value, 1)
            XCTAssertEqual(releases.value, proofs.value,
                           "every counted connection must be uncounted exactly once, and an uncounted one never")
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
