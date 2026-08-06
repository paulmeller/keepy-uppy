import XCTest
@testable import KeepyUppy

final class SessionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")

    private func make(_ kind: SessionKind,
                      persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(), kind: kind, owner: alice,
                persistence: persistence, origin: .manual, startedAt: t0)
    }

    func testStartingASessionKeepsAwake() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite)), now: t0)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    func testDurationSessionExpiresOnTick() {
        var engine = SessionEngine()
        let session = make(.duration(until: t0.addingTimeInterval(3600)))
        _ = engine.apply(.start(session), now: t0)

        let early = engine.apply(.tick, now: t0.addingTimeInterval(3599))
        XCTAssertTrue(early.isEmpty)
        XCTAssertTrue(engine.desiredKeepAwake)

        let late = engine.apply(.tick, now: t0.addingTimeInterval(3601))
        XCTAssertEqual(late.count, 1)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testEightHourSessionIsTestedInstantly() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.duration(until: t0.addingTimeInterval(8 * 3600)))), now: t0)
        XCTAssertTrue(engine.apply(.tick, now: t0.addingTimeInterval(8 * 3600 - 1)).isEmpty)
        XCTAssertEqual(engine.apply(.tick, now: t0.addingTimeInterval(8 * 3600 + 1)).count, 1)
    }

    func testExpiredLeaseEndsButRenewalExtendsIt() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)
        _ = engine.apply(.renewLease(id: session.id, until: t0.addingTimeInterval(120)), now: t0.addingTimeInterval(30))
        XCTAssertTrue(engine.apply(.tick, now: t0.addingTimeInterval(90)).isEmpty, "renewed")
        XCTAssertEqual(engine.apply(.tick, now: t0.addingTimeInterval(121)).count, 1, "expired")
    }

    func testClientDisconnectEndsClientBoundButNotDetached() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite, persistence: .clientBound)), now: t0)
        _ = engine.apply(.start(make(.indefinite, persistence: .detached)), now: t0)
        let ended = engine.apply(.clientDisconnected(alice), now: t0)
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(engine.desiredKeepAwake, "the detached session survives")
    }

    func testAgentDisappearanceEndsOnlyAgentEvaluatedSessions() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.duration(until: t0.addingTimeInterval(3600)))), now: t0)
        _ = engine.apply(.start(make(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))), now: t0)
        let ended = engine.apply(.agentDisappeared, now: t0)
        XCTAssertEqual(ended.count, 1, "the app-watching session cannot be verified any more")
        XCTAssertEqual(ended.first?.kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(engine.desiredKeepAwake, "the daemon-evaluable session is unaffected")
    }

    func testConditionEndedStopsThatSession() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)
        XCTAssertEqual(engine.apply(.conditionEnded(id: session.id), now: t0).count, 1)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testStopAllEndsEverythingIncludingDetached() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite, persistence: .detached)), now: t0)
        _ = engine.apply(.start(make(.indefinite, persistence: .clientBound)), now: t0)
        XCTAssertEqual(engine.apply(.stopAll, now: t0).count, 2)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    // Regression: prevents the expiry sweep from being gated to `case .tick`, which would let a
    // stale session be observed alive when any other, non-tick event is applied.
    func testNonTickEventStillSweepsAnExpiredSession() {
        var engine = SessionEngine()
        let expiring = make(.duration(until: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(expiring), now: t0)
        let unrelated = make(.indefinite)
        _ = engine.apply(.start(unrelated), now: t0)

        // `.stop` only touches `unrelated` in its own case; only the unconditional
        // post-event sweep can account for `expiring`, whose deadline has already passed.
        let ended = engine.apply(.stop(id: unrelated.id), now: t0.addingTimeInterval(120))

        XCTAssertEqual(ended.count, 2, "both the stopped session and the separately-expired session should be reported")
        XCTAssertTrue(ended.contains(where: { $0.id == expiring.id }), "the expired session must be swept even though this event wasn't a tick")
        XCTAssertFalse(engine.desiredKeepAwake, "no sessions remain, so the Mac must not be kept awake")
    }

    // Regression: prevents `.renewLease` from rebuilding the session with a fresh id or dropped
    // fields, which would corrupt the max-duration backstop that keys off the original `startedAt`.
    func testRenewLeasePreservesIdentityAndOnlyMovesDeadline() {
        var engine = SessionEngine()
        let original = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(original), now: t0)

        _ = engine.apply(.renewLease(id: original.id, until: t0.addingTimeInterval(120)), now: t0.addingTimeInterval(30))

        guard let renewed = engine.sessions.first(where: { $0.id == original.id }) else {
            return XCTFail("the renewed session should still be present under its original id")
        }

        XCTAssertEqual(renewed.id, original.id)
        XCTAssertEqual(renewed.owner, original.owner)
        XCTAssertEqual(renewed.persistence, original.persistence)
        XCTAssertEqual(renewed.origin, original.origin)
        XCTAssertEqual(renewed.startedAt, original.startedAt)
        XCTAssertEqual(renewed.kind, .lease(expires: t0.addingTimeInterval(120)), "only the deadline should have moved")
    }
}
