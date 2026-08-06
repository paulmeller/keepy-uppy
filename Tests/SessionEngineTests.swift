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
}
