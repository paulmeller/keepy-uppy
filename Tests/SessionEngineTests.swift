import XCTest
@testable import KeepyUppy

final class SessionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")

    private func make(_ kind: SessionKind,
                      persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual,
                      userID: UInt32 = 0) -> Session {
        Session(id: UUID(), kind: kind, owner: alice,
                ownerUID: userID, persistence: persistence,
                origin: origin, startedAt: t0)
    }

    func testStartingASessionKeepsAwake() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite)), now: t0)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    func testSessionCodingPreservesAuthenticatedOwnerUID() throws {
        let original = make(.whileExternalDisplay, userID: 501)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.ownerUID, 501)
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
        let ended = engine.apply(.agentDisappeared(userID: 0), now: t0)
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

        let outcome = engine.renewLease(
            id: original.id, until: t0.addingTimeInterval(120),
            now: t0.addingTimeInterval(30))

        guard let renewed = engine.sessions.first(where: { $0.id == original.id }) else {
            return XCTFail("the renewed session should still be present under its original id")
        }

        XCTAssertEqual(renewed.id, original.id)
        XCTAssertEqual(renewed.owner, original.owner)
        XCTAssertEqual(renewed.persistence, original.persistence)
        XCTAssertEqual(renewed.origin, original.origin)
        XCTAssertEqual(renewed.startedAt, original.startedAt)
        XCTAssertEqual(renewed.kind, .lease(expires: t0.addingTimeInterval(120)), "only the deadline should have moved")
        XCTAssertEqual(outcome, .renewed(renewed))
    }

    // Regression: `.renewLease` reconstructed the session by hand and, before this fix, silently
    // dropped `triggerID`. A renewed trigger-started lease must keep its `triggerID` so
    // `triggersToFire`'s already-active check doesn't refire the same rule after a renewal.
    func testRenewLeasePreservesTriggerID() {
        var engine = SessionEngine()
        let triggerID = UUID()
        let session = Session(id: UUID(), kind: .lease(expires: t0.addingTimeInterval(60)),
                              owner: ClientID(rawValue: "agent"), persistence: .detached,
                              origin: .trigger, startedAt: t0, triggerID: triggerID)
        engine.startSession(session, now: t0, liveAgentConnections: 1)
        _ = engine.renewLease(id: session.id, until: t0.addingTimeInterval(120), now: t0)
        XCTAssertEqual(engine.sessions.first?.triggerID, triggerID)
    }

    // MARK: - Fix 2: renewLease must not launder a non-lease kind, or accept an unbounded deadline

    func testRenewLeaseRejectsNonLeaseKind() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)

        XCTAssertEqual(
            engine.renewLease(id: session.id, until: t0.addingTimeInterval(3600), now: t0),
            .notLease)

        guard let unchanged = engine.sessions.first(where: { $0.id == session.id }) else {
            return XCTFail("the session must still be present")
        }
        XCTAssertEqual(unchanged.kind, .whileExternalDisplay, "must not have been laundered into a daemon-evaluated .lease")

        // Proves the laundering would otherwise have mattered: with the kind
        // unchanged, the agent disappearing still ends it.
        XCTAssertEqual(engine.apply(.agentDisappeared(userID: 0), now: t0).count, 1)
    }

    func testRenewLeaseRejectsDeadlineBeyondMaxSessionDuration() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)

        let tooFar = t0.addingTimeInterval(SessionEngine.maxSessionDuration + 1)
        XCTAssertEqual(engine.renewLease(id: session.id, until: tooFar, now: t0),
                       .invalidDeadline)

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
        XCTAssertEqual(engine.renewLease(id: session.id, until: nonFinite, now: t0),
                       .invalidDeadline)

        guard let unchanged = engine.sessions.first(where: { $0.id == session.id }) else {
            return XCTFail("the session must still be present")
        }
        XCTAssertEqual(unchanged.kind, .lease(expires: t0.addingTimeInterval(60)), "the original deadline must be untouched")
    }

    func testRenewLeaseRejectsAnAlreadyExpiredDeadline() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)

        XCTAssertEqual(
            engine.renewLease(id: session.id, until: t0.addingTimeInterval(20),
                              now: t0.addingTimeInterval(30)),
            .invalidDeadline)
        XCTAssertEqual(engine.sessions, [session])
    }

    func testRenewLeaseCannotResurrectAnExpiredLeaseBeforeTheNextTick() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)

        XCTAssertEqual(
            engine.renewLease(id: session.id, until: t0.addingTimeInterval(120),
                              now: t0.addingTimeInterval(61)),
            .notFound)
        XCTAssertTrue(engine.sessions.isEmpty)
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

    func testWhileOnACPowerCannotStartWhileAlreadyOnBattery() {
        var engine = SessionEngine()
        let result = engine.startSession(
            make(.whileOnACPower), now: t0,
            liveAgentConnections: 0, onACPower: false)
        XCTAssertEqual(result, .conditionNotMet)
        XCTAssertTrue(engine.sessions.isEmpty)
    }

    func testACDisconnectEndsOnlyACBoundSessions() {
        var engine = SessionEngine()
        let ac = make(.whileOnACPower)
        let indefinite = make(.indefinite)
        _ = engine.apply(.start(ac), now: t0)
        _ = engine.apply(.start(indefinite), now: t0)

        let ended = engine.apply(.acPowerDisconnected, now: t0)

        XCTAssertEqual(ended.map(\.id), [ac.id])
        XCTAssertEqual(engine.sessions.map(\.id), [indefinite.id])
    }

    func testSafetySuppressionRejectsTriggersButAllowsManualStarts() {
        var engine = SessionEngine()
        XCTAssertEqual(
            engine.startSession(make(.indefinite, origin: .trigger), now: t0,
                                liveAgentConnections: 0, triggersSuppressed: true),
            .triggerSuppressed)
        XCTAssertEqual(
            engine.startSession(make(.indefinite), now: t0,
                                liveAgentConnections: 0, triggersSuppressed: true),
            .admitted)
    }

    func testAgentDisappearanceIsScopedToTheMatchingUser() {
        var engine = SessionEngine()
        let aliceSession = make(.whileExternalDisplay, userID: 501)
        let bobSession = make(.whileExternalDisplay, userID: 502)
        _ = engine.apply(.start(aliceSession), now: t0)
        _ = engine.apply(.start(bobSession), now: t0)

        let ended = engine.apply(.agentDisappeared(userID: 501), now: t0)

        XCTAssertEqual(ended.map(\.id), [aliceSession.id])
        XCTAssertEqual(engine.sessions.map(\.id), [bobSession.id])
    }

    // MARK: - Fix 6: an agent may only end sessions whose kind is agent-evaluated

    func testEndConditionRejectsADaemonEvaluableSession() {
        var engine = SessionEngine()
        let session = make(.duration(until: t0.addingTimeInterval(3600)))
        _ = engine.apply(.start(session), now: t0)

        let outcome = engine.endCondition(id: session.id, reportedByUserID: 0, now: t0)

        XCTAssertEqual(outcome, .notAgentEvaluated)
        XCTAssertEqual(engine.sessions.count, 1, "the session must survive an out-of-scope condition report")
    }

    func testEndConditionEndsAnAgentEvaluatedSession() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)

        let outcome = engine.endCondition(id: session.id, reportedByUserID: 0, now: t0)

        XCTAssertEqual(outcome, .ended(session))
        XCTAssertTrue(engine.sessions.isEmpty)
    }

    func testEndConditionOnUnknownSessionIsNotFound() {
        var engine = SessionEngine()
        XCTAssertEqual(engine.endCondition(id: UUID(), reportedByUserID: 0, now: t0), .notFound)
    }

    func testAgentCannotEndAnotherUsersConditionSession() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay, userID: 501)
        _ = engine.apply(.start(session), now: t0)

        XCTAssertEqual(
            engine.endCondition(id: session.id, reportedByUserID: 502, now: t0),
            .wrongUser)
        XCTAssertEqual(engine.sessions, [session])
    }

    // MARK: - Security re-review Fix 3a: DaemonRuntime sweeps expiry before
    // evaluating admission/authorization, not only as a side effect of
    // `apply`. `DaemonRuntime.startSession`/`.conditionEnded` cannot be unit
    // tested directly (`Helper/` is not part of the test target's module
    // graph), so these tests exercise the exact call sequence the fix adds
    // there — `engine.apply(.tick, now:)` immediately before the
    // caps/authorization check — directly against `SessionEngine`'s public
    // API, proving the sequence is what actually closes the gap.

    func testPreSweepingBeforeStartSessionStopsAnExpiredSessionCountingTowardTheOwnerCap() {
        func buildOwnerAtCapWithOneAlreadyExpired() -> (SessionEngine, expiredID: UUID) {
            var engine = SessionEngine()
            let expired = make(.duration(until: t0.addingTimeInterval(60)))
            XCTAssertEqual(engine.startSession(expired, now: t0, liveAgentConnections: 0), .admitted)
            for _ in 0..<(SessionAdmission.maxSessionsPerOwner - 1) {
                XCTAssertEqual(engine.startSession(make(.indefinite), now: t0, liveAgentConnections: 0), .admitted)
            }
            XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsPerOwner)
            return (engine, expired.id)
        }

        let later = t0.addingTimeInterval(120) // past the expired session's deadline

        // Without the pre-sweep (the pre-fix behaviour): the expired session
        // is still sitting in the table when the cap is evaluated, so a
        // brand-new, entirely legitimate session is wrongly rejected —
        // exactly the bug Fix 3a closes.
        var (withoutSweep, _) = buildOwnerAtCapWithOneAlreadyExpired()
        XCTAssertEqual(withoutSweep.startSession(make(.indefinite), now: later, liveAgentConnections: 0),
                       .ownerLimitReached,
                       "documents the bug: an expired-but-unswept session still occupies a cap slot")

        // With the pre-sweep `DaemonRuntime.startSession` now performs
        // before evaluating admission (Fix 3a): the expired session is gone
        // before the cap is even checked, so the new session is admitted
        // immediately — not after waiting for the next 5s timer tick.
        var (withSweep, expiredID) = buildOwnerAtCapWithOneAlreadyExpired()
        _ = withSweep.apply(.tick, now: later)
        XCTAssertFalse(withSweep.sessions.contains(where: { $0.id == expiredID }), "the sweep must have already removed it")
        XCTAssertEqual(withSweep.startSession(make(.indefinite), now: later, liveAgentConnections: 0), .admitted)
    }

    func testPreSweepingBeforeStartSessionDropsDesiredKeepAwakeImmediately() {
        var engine = SessionEngine()
        let expired = make(.duration(until: t0.addingTimeInterval(60)))
        XCTAssertEqual(engine.startSession(expired, now: t0, liveAgentConnections: 0), .admitted)
        XCTAssertTrue(engine.desiredKeepAwake)

        let later = t0.addingTimeInterval(120)
        // Not yet due for its own reasons: still true until something
        // sweeps, proving the assertion below isn't vacuous.
        XCTAssertTrue(engine.desiredKeepAwake, "the expired session hasn't been swept yet")

        // The pre-sweep `DaemonRuntime.startSession` now performs before
        // evaluating admission — `desiredKeepAwake` reflects reality on the
        // very next call, not only after the next timer tick.
        _ = engine.apply(.tick, now: later)
        XCTAssertFalse(engine.desiredKeepAwake, "the only session present had already expired")
    }

    func testPreSweepingBeforeEndConditionStopsAnUnrelatedExpiredSessionSurviving() {
        // `endCondition`'s *success* path already reaches `apply` (which
        // always sweeps at the end), so it can't demonstrate the gap. The
        // gap is on the early-return paths — `.notFound` here — which never
        // reach `apply` at all: a report about some other/unknown id must
        // not let a separately-expired session sit in the table.
        func buildTableWithAnExpiredSession() -> (SessionEngine, expiredID: UUID) {
            var engine = SessionEngine()
            let expired = make(.duration(until: t0.addingTimeInterval(60)))
            XCTAssertEqual(engine.startSession(expired, now: t0, liveAgentConnections: 0), .admitted)
            return (engine, expired.id)
        }

        let later = t0.addingTimeInterval(120) // past the expired session's deadline

        // Without the pre-sweep: `endCondition` on an unrelated/unknown id
        // returns `.notFound` before `apply` ever runs on this call, so the
        // separately-expired session is left in the table — still counting
        // toward `desiredKeepAwake` — even though the call itself succeeded
        // in the sense of returning a well-formed answer.
        var (withoutSweep, expiredID1) = buildTableWithAnExpiredSession()
        XCTAssertEqual(withoutSweep.endCondition(id: UUID(), reportedByUserID: 0, now: later), .notFound)
        XCTAssertTrue(withoutSweep.sessions.contains(where: { $0.id == expiredID1 }),
                      "documents the bug: an unrelated expired session survives the call")

        // With the pre-sweep `DaemonRuntime.conditionEnded` now performs
        // before looking anything up (Fix 3a): the expired session is gone
        // immediately, regardless of which session's condition was reported.
        var (withSweep, expiredID2) = buildTableWithAnExpiredSession()
        _ = withSweep.apply(.tick, now: later)
        XCTAssertEqual(withSweep.endCondition(id: UUID(), reportedByUserID: 0, now: later), .notFound)
        XCTAssertFalse(withSweep.sessions.contains(where: { $0.id == expiredID2 }), "the pre-sweep must have already removed it")
        XCTAssertFalse(withSweep.desiredKeepAwake)
    }
}
