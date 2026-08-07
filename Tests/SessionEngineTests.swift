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

    // MARK: - Fix 2: renewLease must not launder a non-lease kind, or accept an unbounded deadline

    func testRenewLeaseRejectsNonLeaseKind() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)

        _ = engine.apply(.renewLease(id: session.id, until: t0.addingTimeInterval(3600)), now: t0)

        guard let unchanged = engine.sessions.first(where: { $0.id == session.id }) else {
            return XCTFail("the session must still be present")
        }
        XCTAssertEqual(unchanged.kind, .whileExternalDisplay, "must not have been laundered into a daemon-evaluated .lease")

        // Proves the laundering would otherwise have mattered: with the kind
        // unchanged, the agent disappearing still ends it.
        XCTAssertEqual(engine.apply(.agentDisappeared, now: t0).count, 1)
    }

    func testRenewLeaseRejectsDeadlineBeyondMaxSessionDuration() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)

        let tooFar = t0.addingTimeInterval(SessionEngine.maxSessionDuration + 1)
        _ = engine.apply(.renewLease(id: session.id, until: tooFar), now: t0)

        guard let unchanged = engine.sessions.first(where: { $0.id == session.id }) else {
            return XCTFail("the session must still be present")
        }
        XCTAssertEqual(unchanged.kind, .lease(expires: t0.addingTimeInterval(60)), "the original deadline must be untouched")
    }

    func testRenewLeaseRejectsNonFiniteDeadline() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)

        let nonFinite = Date(timeIntervalSinceReferenceDate: .infinity)
        _ = engine.apply(.renewLease(id: session.id, until: nonFinite), now: t0)

        guard let unchanged = engine.sessions.first(where: { $0.id == session.id }) else {
            return XCTFail("the session must still be present")
        }
        XCTAssertEqual(unchanged.kind, .lease(expires: t0.addingTimeInterval(60)), "the original deadline must be untouched")
    }

    // MARK: - Fix 1: admission caps

    func testSessionStartCapPerOwnerRejectsBeyondLimit() {
        var engine = SessionEngine()
        for _ in 0..<SessionAdmission.maxSessionsPerOwner {
            let result = engine.startSession(make(.indefinite), now: t0, liveAgentConnections: 0)
            XCTAssertEqual(result, .admitted)
        }
        XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsPerOwner)

        let before = Set(engine.sessions.map(\.id))
        let rejected = engine.startSession(make(.indefinite), now: t0, liveAgentConnections: 0)

        XCTAssertEqual(rejected, .ownerLimitReached)
        XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsPerOwner, "a rejected start must not grow the table")
        XCTAssertEqual(Set(engine.sessions.map(\.id)), before, "a rejected start must not disturb existing sessions")
    }

    func testSessionStartCapGlobalRejectsBeyondLimitEvenForAFreshOwner() {
        var engine = SessionEngine()
        var count = 0
        var owner = 0
        while count < SessionAdmission.maxSessionsGlobal {
            let batch = min(SessionAdmission.maxSessionsPerOwner, SessionAdmission.maxSessionsGlobal - count)
            for _ in 0..<batch {
                let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "owner-\(owner)"),
                                      persistence: .clientBound, origin: .manual, startedAt: t0)
                XCTAssertEqual(engine.startSession(session, now: t0, liveAgentConnections: 0), .admitted)
                count += 1
            }
            owner += 1
        }
        XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsGlobal)

        let before = Set(engine.sessions.map(\.id))
        // A brand-new owner, nowhere near their own per-owner cap, is still
        // rejected once the daemon-wide cap is reached.
        let rejected = engine.startSession(
            Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "brand-new-owner"),
                    persistence: .clientBound, origin: .manual, startedAt: t0),
            now: t0, liveAgentConnections: 0)

        XCTAssertEqual(rejected, .globalLimitReached)
        XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsGlobal, "a rejected start must not grow the table")
        XCTAssertEqual(Set(engine.sessions.map(\.id)), before, "a rejected start must not disturb existing sessions")
    }

    func testExpirySweepStillRunsAfterAdmissionIsCapped() {
        // Regression guard alongside `testNonTickEventStillSweepsAnExpiredSession`:
        // the cheap `removeExpired` path introduced for Fix 1 must not
        // accidentally gate expiry on `.tick` the way the sweep itself must not.
        var engine = SessionEngine()
        let expiring = make(.duration(until: t0.addingTimeInterval(60)))
        XCTAssertEqual(engine.startSession(expiring, now: t0, liveAgentConnections: 0), .admitted)

        let ended = engine.apply(.stop(id: UUID()), now: t0.addingTimeInterval(120))

        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.id, expiring.id)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    // MARK: - Fix 3: agent-evaluated kinds require a live agent connection

    func testStartSessionRejectsAgentEvaluatedKindWhenNoAgentConnected() {
        var engine = SessionEngine()
        let before = engine.sessions

        let result = engine.startSession(make(.whileExternalDisplay), now: t0, liveAgentConnections: 0)

        XCTAssertEqual(result, .noAgentConnected)
        XCTAssertEqual(engine.sessions.count, before.count, "a rejected start must not disturb existing sessions")
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testStartSessionAdmitsAgentEvaluatedKindWhenAnAgentIsConnected() {
        var engine = SessionEngine()
        let result = engine.startSession(make(.whileExternalDisplay), now: t0, liveAgentConnections: 1)
        XCTAssertEqual(result, .admitted)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    func testStartSessionNeverRequiresAnAgentForDaemonEvaluableKinds() {
        var engine = SessionEngine()
        let result = engine.startSession(make(.indefinite), now: t0, liveAgentConnections: 0)
        XCTAssertEqual(result, .admitted)
    }

    // MARK: - Fix 6: an agent may only end sessions whose kind is agent-evaluated

    func testEndConditionRejectsADaemonEvaluableSession() {
        var engine = SessionEngine()
        let session = make(.duration(until: t0.addingTimeInterval(3600)))
        _ = engine.apply(.start(session), now: t0)

        let outcome = engine.endCondition(id: session.id, now: t0)

        XCTAssertEqual(outcome, .notAgentEvaluated)
        XCTAssertEqual(engine.sessions.count, 1, "the session must survive an out-of-scope condition report")
    }

    func testEndConditionEndsAnAgentEvaluatedSession() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)

        let outcome = engine.endCondition(id: session.id, now: t0)

        XCTAssertEqual(outcome, .ended(session))
        XCTAssertTrue(engine.sessions.isEmpty)
    }

    func testEndConditionOnUnknownSessionIsNotFound() {
        var engine = SessionEngine()
        XCTAssertEqual(engine.endCondition(id: UUID(), now: t0), .notFound)
    }
}
