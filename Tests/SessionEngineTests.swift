import XCTest
import IOKit.pwr_mgt
@testable import KeepyUppy

final class SessionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")

    private func make(_ kind: SessionKind,
                      persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual,
                      userID: UInt32 = 0,
                      wakeMode: WakeMode = .clamshell,
                      keepsDisksAwake: Bool = false) -> Session {
        Session(id: UUID(), kind: kind, owner: alice,
                ownerUID: userID, persistence: persistence,
                origin: origin, startedAt: t0, triggerID: nil,
                wakeMode: wakeMode, keepsDisksAwake: keepsDisksAwake)
    }

    func testStartingASessionKeepsAwake() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite)), now: t0)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    /// The engine is the object `DaemonRuntime` actually holds, and
    /// `applyLocked` reads exactly this property off it on every event and
    /// every tick before handing the result to `PowerPlanHolder.apply`. The
    /// daemon itself is unreachable from this target; this is the closest a
    /// test can stand to its apply path.
    func testThePlanTracksEveryEventThatChangesTheTable() {
        var engine = SessionEngine()
        XCTAssertEqual(engine.desiredPowerPlan, .sleepAllowed)

        let lid = make(.indefinite, wakeMode: .clamshell)
        _ = engine.apply(.start(lid), now: t0)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true))

        let display = make(.duration(until: t0.addingTimeInterval(60)),
                           wakeMode: .systemAndDisplay)
        _ = engine.apply(.start(display), now: t0)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: true))

        // Expiry is part of the apply path too: a swept session must stop
        // counting toward the plan in the very pass that removes it, or the
        // daemon holds the display awake for up to five more seconds.
        _ = engine.apply(.tick, now: t0.addingTimeInterval(61))
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true))

        _ = engine.apply(.stopAll, now: t0.addingTimeInterval(61))
        XCTAssertEqual(engine.desiredPowerPlan, .sleepAllowed,
                       "`keepy-uppy off` must put both mechanisms back, not one")
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

    /// Renewal, as one whole-struct assertion — replacing three separate
    /// tests that each named the fields they happened to think of
    /// (`…PreservesIdentityAndOnlyMovesDeadline`, `…PreservesTriggerID`,
    /// `…PreservesWakeMode`) and, between them, still missed one.
    ///
    /// Three of `Session`'s fields used to carry defaults in its memberwise
    /// initialiser — `ownerUID`, `triggerID`, `wakeMode` — and those three, and
    /// only those three, could be silently omitted from a rebuild without
    /// failing to compile. Two of them had been dropped from this renewal for
    /// real; the third was still open, and deleting `ownerUID` from the copy
    /// left all of `SessionEngineTests`, `SessionIsolationTests` and
    /// `ClientIdentityTests` passing. `Session.init` now defaults nothing, so
    /// an *omission* is a compile error at every site; what this test still
    /// covers is the half the compiler cannot — a field carried across as the
    /// wrong value.
    ///
    /// So this names no fields at all. `Session` is `Equatable`: the lease is
    /// built with *every* field set to a non-default value, and the
    /// expectation comes from the same factory with only the deadline moved.
    /// A field rebuilt wrongly in `Session.renewed(until:)` makes the two
    /// structs unequal and this fails — whether or not anyone thought to name
    /// it, **for the fields the factory sets to something distinguishable**.
    ///
    /// That qualifier is the whole point. The expectation is built with the
    /// *same* memberwise initialiser as the value under test, so a new field
    /// given the same uninteresting value on both sides (a fresh `Bool` left
    /// `false`) compares equal whatever `renewed` does with it. A new field is
    /// covered only once someone gives it a **non-default** value in the
    /// factory below — `keepsDisksAwake` is `true` here for that reason, exactly
    /// as `wakeMode` is `.system` — and nothing but this sentence will say so.
    /// `DaemonConnectionRequestTests` carries the same warning, for the same
    /// reason.
    func testRenewingALeaseMovesTheDeadlineAndChangesNothingElse() {
        let id = UUID()
        let triggerID = UUID()
        func lease(expires: Date) -> Session {
            Session(id: id, kind: .lease(expires: expires),
                    owner: ClientID(rawValue: "agent-501"), ownerUID: 501,
                    persistence: .detached, origin: .trigger, startedAt: t0,
                    triggerID: triggerID, wakeMode: .system, keepsDisksAwake: true)
        }

        var engine = SessionEngine()
        XCTAssertEqual(
            engine.startSession(lease(expires: t0.addingTimeInterval(60)), now: t0,
                                liveAgentConnections: 1),
            .admitted)

        let outcome = engine.renewLease(id: id, until: t0.addingTimeInterval(120),
                                        now: t0.addingTimeInterval(30))

        let expected = lease(expires: t0.addingTimeInterval(120))
        XCTAssertEqual(engine.sessions, [expected])
        XCTAssertEqual(outcome, .renewed(expected))
    }

    /// The consequence the test above exists to prevent, stated in the terms
    /// the daemon actually acts on: `applyLocked` hands `desiredPowerPlan` to
    /// `PowerPlanHolder` on every event, so a renewal that reset the mode
    /// would flip the global setting on for a session that never asked.
    func testRenewingALeaseDoesNotChangeThePowerPlan() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)), wakeMode: .system)
        engine.startSession(session, now: t0, liveAgentConnections: 1)
        let before = engine.desiredPowerPlan
        XCTAssertFalse(before.sleepDisabled, "a .system session must not set the global override")

        _ = engine.renewLease(id: session.id, until: t0.addingTimeInterval(120), now: t0)
        XCTAssertEqual(engine.desiredPowerPlan, before, "a renewal must not change the power plan")
    }

    // MARK: - Plan 8 Task 8: a live session changes its mind

    /// The counterpart of `testRenewingALeaseMovesTheDeadlineAndChangesNothingElse`,
    /// and written the same way and for the same reason: **no field is named**.
    /// The session is built with every field set to something distinguishable
    /// and the expectation comes from the same factory with only the request
    /// moved, so a field rebuilt wrongly makes the two structs unequal whether
    /// or not anyone thought to name it.
    ///
    /// The same qualifier applies as there: a new field left at the same
    /// uninteresting value on both sides compares equal whatever the rebuild
    /// does with it, so a new field is covered only once the factory below gives
    /// it a non-default value.
    func testChangingAPowerRequestChangesThatAndLeavesTheSessionOtherwiseAlone() {
        let id = UUID()
        let triggerID = UUID()
        func session(power: PowerRequest) -> Session {
            Session(id: id, kind: .whileVolumeMounted(name: "Backup"),
                    owner: ClientID(rawValue: "agent-501"), ownerUID: 501,
                    persistence: .detached, origin: .trigger, startedAt: t0,
                    triggerID: triggerID, wakeMode: power.wakeMode,
                    keepsDisksAwake: power.keepsDisksAwake)
        }
        let before = PowerRequest(wakeMode: .system, keepsDisksAwake: true)
        let after = PowerRequest(wakeMode: .clamshell, keepsDisksAwake: true)

        var engine = SessionEngine()
        XCTAssertEqual(engine.startSession(session(power: before), now: t0,
                                           liveAgentConnections: 1),
                       .admitted)

        let outcome = engine.changePower(id: id, to: after, now: t0.addingTimeInterval(30))

        XCTAssertEqual(engine.sessions, [session(power: after)])
        XCTAssertEqual(outcome, .changed(session: session(power: after), from: before),
                       "the outcome must carry the request that was in force, which is what "
                       + "the daemon rolls back to when the machine refuses the new one")
    }

    /// The consequence the test above exists to produce, in the terms the daemon
    /// acts on: `applyLocked` hands `desiredPowerPlan` to `PowerPlanHolder` on
    /// every event, so this is the property the whole feature is for.
    ///
    /// Both directions, because the plan has to converge downward as well as
    /// upward — a promotion that set the global override and a demotion that
    /// failed to clear it would look identical to a test that only promoted.
    func testAChangedRequestMovesThePlanInBothDirections() {
        var engine = SessionEngine()
        let session = make(.indefinite, wakeMode: .system)
        engine.startSession(session, now: t0, liveAgentConnections: 1)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: false))

        engine.changePower(id: session.id,
                           to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: true), now: t0)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventDiskIdle],
                                 sleepDisabled: true),
                       "a promotion must reach the plan the daemon applies")

        engine.changePower(id: session.id,
                           to: PowerRequest(wakeMode: .system, keepsDisksAwake: false), now: t0)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: false),
                       "and a weakening must move it back, on both axes")
    }

    /// A change to a session that is not there is `.notFound` and **mutates
    /// nothing** — including the other sessions, which is the half a bare
    /// outcome assertion would not cover.
    func testChangingAnUnknownSessionIsNotFoundAndTouchesNothing() {
        var engine = SessionEngine()
        let live = make(.indefinite, wakeMode: .system)
        engine.startSession(live, now: t0, liveAgentConnections: 1)
        let before = engine.sessions

        XCTAssertEqual(engine.changePower(id: UUID(),
                                          to: PowerRequest(wakeMode: .clamshell,
                                                           keepsDisksAwake: true),
                                          now: t0),
                       .notFound)
        XCTAssertEqual(engine.sessions, before)
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: false))
    }

    /// **A no-op is a success, reported honestly.** Asking for the request a
    /// session already has is not a failure — nothing was refused and nothing
    /// went wrong — and `from` says it was a no-op without the caller having to
    /// infer it from a second lookup. Reporting it as an error would put a
    /// message on somebody's screen about a session that is doing exactly what
    /// they asked.
    func testAskingForTheRequestASessionAlreadyHasSucceedsAndSaysSo() {
        var engine = SessionEngine()
        let request = PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: true)
        let session = make(.indefinite, wakeMode: request.wakeMode,
                           keepsDisksAwake: request.keepsDisksAwake)
        engine.startSession(session, now: t0, liveAgentConnections: 1)
        let plan = engine.desiredPowerPlan

        guard case .changed(let changed, let from) =
                engine.changePower(id: session.id, to: request, now: t0) else {
            return XCTFail("a no-op change must succeed, not report a failure")
        }
        XCTAssertEqual(from, request, "`from` is what makes a no-op recognisable as one")
        XCTAssertEqual(changed.power, request)
        XCTAssertEqual(engine.sessions, [session])
        XCTAssertEqual(engine.desiredPowerPlan, plan)
    }

    /// Expiry sweeps in the same call, as it does after every other event: an
    /// unrelated session whose deadline has passed must not survive a mode
    /// change made to a different one, and must not still be contributing to the
    /// plan when this returns.
    func testAModeChangeStillSweepsAnExpiredSession() {
        var engine = SessionEngine()
        let expiring = make(.duration(until: t0.addingTimeInterval(60)), wakeMode: .clamshell)
        let lasting = make(.indefinite, wakeMode: .system)
        engine.startSession(expiring, now: t0, liveAgentConnections: 1)
        engine.startSession(lasting, now: t0, liveAgentConnections: 1)

        engine.changePower(id: lasting.id,
                           to: PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: false),
                           now: t0.addingTimeInterval(61))

        XCTAssertEqual(engine.sessions.map(\.id), [lasting.id])
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: false),
                       "the expired clamshell session was still holding the global setting")
    }

    /// The session being changed is swept too, and the sweep wins: a session
    /// whose deadline passed before the request arrived is `.notFound` rather
    /// than something whose mode can be changed for the five seconds until the
    /// next tick. Same rule, and same reason, as
    /// `testRenewLeaseCannotResurrectAnExpiredLeaseBeforeTheNextTick`.
    func testAnExpiredSessionCannotHaveItsModeChangedBeforeTheNextTick() {
        var engine = SessionEngine()
        let expiring = make(.duration(until: t0.addingTimeInterval(60)), wakeMode: .system)
        engine.startSession(expiring, now: t0, liveAgentConnections: 1)

        XCTAssertEqual(engine.changePower(id: expiring.id,
                                          to: PowerRequest(wakeMode: .clamshell,
                                                           keepsDisksAwake: false),
                                          now: t0.addingTimeInterval(61)),
                       .notFound)
        XCTAssertTrue(engine.sessions.isEmpty)
        XCTAssertEqual(engine.desiredPowerPlan, .sleepAllowed)
    }

    /// The event on its own, applied directly, so the guarantee is pinned at the
    /// level `DaemonRuntime`'s rollback uses it at — it re-applies this event
    /// with the previous request rather than re-inserting a saved session.
    func testTheEventIsItsOwnUndo() {
        var engine = SessionEngine()
        let before = PowerRequest(wakeMode: .system, keepsDisksAwake: false)
        let session = make(.indefinite, wakeMode: before.wakeMode,
                           keepsDisksAwake: before.keepsDisksAwake)
        engine.startSession(session, now: t0, liveAgentConnections: 1)

        _ = engine.apply(.changePower(id: session.id,
                                      to: PowerRequest(wakeMode: .clamshell,
                                                       keepsDisksAwake: true)), now: t0)
        XCTAssertTrue(engine.desiredPowerPlan.sleepDisabled)

        _ = engine.apply(.changePower(id: session.id, to: before), now: t0)
        XCTAssertEqual(engine.sessions, [session],
                       "applying the event with the previous request must restore the session "
                       + "exactly, which is what makes the daemon's rollback a rollback")
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
                                      ownerUID: 0, persistence: .clientBound, origin: .manual,
                                      startedAt: t0, triggerID: nil, wakeMode: .clamshell,
                                      keepsDisksAwake: false)
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
                    ownerUID: 0, persistence: .clientBound, origin: .manual, startedAt: t0,
                    triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false),
            now: t0, liveAgentConnections: 0)

        XCTAssertEqual(rejected, .globalLimitReached)
        XCTAssertEqual(engine.sessions.count, SessionAdmission.maxSessionsGlobal, "a rejected start must not grow the table")
        XCTAssertEqual(Set(engine.sessions.map(\.id)), before, "a rejected start must not disturb existing sessions")
    }

    // Regression: closes spec §5's documented known limitation — a client
    // that opens many connections, starts `.detached` sessions on each, and
    // disconnects can otherwise consume the entire global cap with orphaned
    // garbage (detached sessions deliberately survive `clientDisconnected`),
    // denying every other client. The detached sub-cap bounds that.
    func testDetachedSessionCapRejectsBeyondLimitEvenAcrossManyOwners() {
        var engine = SessionEngine()
        // Fill the detached sub-cap using many distinct owners, so this
        // proves the cap is global-to-detached-kind, not per-owner.
        for i in 0..<SessionAdmission.maxDetachedSessionsGlobal {
            let session = Session(id: UUID(), kind: .indefinite,
                                  owner: ClientID(rawValue: "owner-\(i)"), ownerUID: 0,
                                  persistence: .detached, origin: .manual, startedAt: t0,
                                  triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
            XCTAssertEqual(engine.startSession(session, now: t0, liveAgentConnections: 0), .admitted)
        }
        let oneMore = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "owner-extra"),
                              ownerUID: 0, persistence: .detached, origin: .manual, startedAt: t0,
                              triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
        XCTAssertEqual(engine.startSession(oneMore, now: t0, liveAgentConnections: 0), .globalLimitReached)
    }

    func testDetachedCapDoesNotRestrictClientBoundSessions() {
        var engine = SessionEngine()
        for i in 0..<SessionAdmission.maxDetachedSessionsGlobal {
            let session = Session(id: UUID(), kind: .indefinite,
                                  owner: ClientID(rawValue: "owner-\(i)"), ownerUID: 0,
                                  persistence: .detached, origin: .manual, startedAt: t0,
                                  triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
            _ = engine.startSession(session, now: t0, liveAgentConnections: 0)
        }
        // The detached sub-cap must not touch clientBound admission at all —
        // this is the actual guarantee: headroom stays reserved for sessions
        // whose owner is (by construction) still connected.
        let clientBound = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "owner-cb"),
                                  ownerUID: 0, persistence: .clientBound, origin: .manual,
                                  startedAt: t0, triggerID: nil, wakeMode: .clamshell,
                                  keepsDisksAwake: false)
        XCTAssertEqual(engine.startSession(clientBound, now: t0, liveAgentConnections: 0), .admitted)
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

// MARK: - Plan 8 Task 8: the mode change is transactional, proven against a
//         machine that refuses the write

/// A `SleepSettingBackend` that refuses the writes a test names.
///
/// It exists to produce the **one** failure `PowerPlanHolder.apply` reports as a
/// failure — a refused `sleepDisabled: true` — without going anywhere near this
/// Mac's real setting, which is root-only and survives a reboot.
private final class RefusingSleepSetting: SleepSettingBackend {
    /// Values whose write should fail. `[true]` is the machine
    /// `PowerPlanHolder.apply`'s comment contemplates: undeclared SPI that will
    /// not turn the setting on. `[true, false]` is that machine's other half —
    /// SPI that refuses writes outright — where a refused *clear* must still not
    /// be reported as a failed apply.
    var refuses: Set<Bool> = []
    private(set) var writes: [Bool] = []
    var lastWrite: Bool? { writes.last }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        writes.append(disabled)
        return !refuses.contains(disabled)
    }
}

/// Hands out assertion ids without calling IOKit. A test that reached the real
/// backend and failed between create and release would leave this Mac awake
/// after the run.
private final class StubAssertions: PowerAssertionBackend {
    private var nextID: IOPMAssertionID = 100

    func create(type: PowerAssertionType, name: String) -> IOPMAssertionID? {
        defer { nextID += 1 }
        return nextID
    }

    func release(_ id: IOPMAssertionID) -> Bool { true }
}

/// **Does a refused promotion leave the session exactly as it was?**
///
/// `DaemonRuntime.changeSessionPower` is in `Helper/`, which is not in this
/// target's module graph, so the composition it performs is reproduced here —
/// the same shape `SessionIsolationTests`' "authorization actually gates the
/// mutation" section uses for `stopSession`, and for the same reason. Both
/// halves of the composition are real: a real `SessionEngine` and a real
/// `PowerPlanHolder`, with only the two machine-touching backends stubbed.
///
/// What is verified by reading alone is that `DaemonRuntime` performs *this*
/// sequence. What is verified here is that this sequence has the property the
/// reply claims.
final class PowerChangeTransactionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ power: PowerRequest) -> Session {
        Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                ownerUID: 501, persistence: .detached, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: power.wakeMode,
                keepsDisksAwake: power.keepsDisksAwake)
    }

    /// `DaemonRuntime.changeSessionPower`'s body, minus the queue and the
    /// authorisation (which `SessionIsolationTests` covers): change, apply, and
    /// on a failed apply put the previous request back and re-apply before
    /// reporting failure.
    ///
    /// Returns what the daemon would reply — `true` for `.changed`.
    @discardableResult
    private func changePower(id: UUID, to power: PowerRequest, now: Date,
                             in engine: inout SessionEngine,
                             holder: PowerPlanHolder) -> Bool {
        guard case .changed(_, let previous) = engine.changePower(id: id, to: power, now: now)
        else { return false }
        guard holder.apply(engine.desiredPowerPlan) else {
            _ = engine.changePower(id: id, to: previous, now: now)
            _ = holder.apply(engine.desiredPowerPlan)
            return false
        }
        return true
    }

    /// **The transaction.** A promotion to `.clamshell` on a Mac whose
    /// `SleepDisabled` write does not land must leave the session running with
    /// the request it already had — not with the one that was asked for, and not
    /// destroyed.
    ///
    /// Three things are asserted, and the third is the one a naive rollback
    /// fails: the reply is a failure, the *table* holds the old request, and the
    /// *machine* was converged back onto the old plan rather than left holding
    /// whatever the attempted plan had established before the write failed.
    func testARefusedPromotionLeavesTheSessionAndTheMachineExactlyAsTheyWere() {
        let sleepSetting = RefusingSleepSetting()
        sleepSetting.refuses = [true]
        let holder = PowerPlanHolder(assertions: StubAssertions(), sleepSetting: sleepSetting)

        let before = PowerRequest(wakeMode: .system, keepsDisksAwake: true)
        var engine = SessionEngine()
        let running = session(before)
        engine.startSession(running, now: t0, liveAgentConnections: 1)
        XCTAssertTrue(holder.apply(engine.desiredPowerPlan), "the starting state must be honoured")

        let changed = changePower(id: running.id,
                                  to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: true),
                                  now: t0, in: &engine, holder: holder)

        XCTAssertFalse(changed, "a promotion the machine refused must be reported as a failure")
        XCTAssertEqual(engine.sessions, [running],
                       "the session must be left exactly as it was, request included")
        XCTAssertEqual(engine.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventDiskIdle],
                                 sleepDisabled: false))
        XCTAssertEqual(sleepSetting.lastWrite, false,
                       "the last thing written to the machine must be the old plan's answer, "
                       + "not the refused promotion's")
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventDiskIdle],
                       "the rollback must re-converge the assertion axis too, not only the "
                       + "axis that failed")
    }

    /// The positive control, without which the test above would pass against an
    /// implementation that never changes anything at all.
    func testThePromotionTheMachineAcceptsIsKept() {
        let sleepSetting = RefusingSleepSetting()
        let holder = PowerPlanHolder(assertions: StubAssertions(), sleepSetting: sleepSetting)

        var engine = SessionEngine()
        let running = session(PowerRequest(wakeMode: .system, keepsDisksAwake: true))
        engine.startSession(running, now: t0, liveAgentConnections: 1)
        _ = holder.apply(engine.desiredPowerPlan)

        let wanted = PowerRequest(wakeMode: .clamshell, keepsDisksAwake: true)
        XCTAssertTrue(changePower(id: running.id, to: wanted, now: t0,
                                  in: &engine, holder: holder))
        XCTAssertEqual(engine.sessions.first?.power, wanted)
        XCTAssertEqual(sleepSetting.lastWrite, true)
    }

    /// **Weakening is not special-cased, and does not need to be.** On the
    /// machine whose SPI refuses writes outright — the case
    /// `PowerPlanHolder.apply` names — a demotion still succeeds, because a
    /// refused *clear* leaves the Mac awake for longer than asked, which is the
    /// direction that cannot lose a user's work. One path, and the invariant is
    /// what makes it safe rather than a second branch.
    func testAWeakeningSucceedsEvenWhereTheSettingCannotBeWrittenAtAll() {
        let sleepSetting = RefusingSleepSetting()
        sleepSetting.refuses = [true, false]
        let holder = PowerPlanHolder(assertions: StubAssertions(), sleepSetting: sleepSetting)

        var engine = SessionEngine()
        let running = session(PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
        engine.startSession(running, now: t0, liveAgentConnections: 1)
        _ = holder.apply(engine.desiredPowerPlan)

        let wanted = PowerRequest(wakeMode: .system, keepsDisksAwake: false)
        XCTAssertTrue(changePower(id: running.id, to: wanted, now: t0,
                                  in: &engine, holder: holder),
                      "a refused clear is not a broken promise, so the weakening stands")
        XCTAssertEqual(engine.sessions.first?.power, wanted)
    }

    /// The change converges **inside this call**, which is Plan 8's finding 6 and
    /// the reason the surfaces can report a result at all rather than saying
    /// "within five seconds".
    ///
    /// Nothing here ticks: one `changePower`, one `apply`, and the machine is in
    /// the new state — in both directions, because `PowerPlanHolder.apply`
    /// releasing what the new plan no longer wants is the half that would leave
    /// a stale assertion held until the next tick if it did not.
    func testTheMachineIsInTheNewStateWhenTheCallReturnsWithNoTickInBetween() {
        let holder = PowerPlanHolder(assertions: StubAssertions(),
                                     sleepSetting: RefusingSleepSetting())
        var engine = SessionEngine()
        let running = session(PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: false))
        engine.startSession(running, now: t0, liveAgentConnections: 1)
        _ = holder.apply(engine.desiredPowerPlan)
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])

        changePower(id: running.id,
                    to: PowerRequest(wakeMode: .system, keepsDisksAwake: true),
                    now: t0, in: &engine, holder: holder)

        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventDiskIdle],
                       "the display assertion was still held after the call that dropped it")
    }
}
