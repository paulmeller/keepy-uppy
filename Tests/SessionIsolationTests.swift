import XCTest
@testable import KeepyUppy

/// Task 10: cross-client isolation ("every client is equally entitled to
/// start and stop *its own* sessions" — spec §4) is pure logic, kept in
/// `SessionIsolation` precisely so it is unit-testable without XPC or a
/// running daemon.
///
/// **Plan 8 Task 5 added the one exception to that sentence**, and the bulk of
/// this file is now about the exception's *edges* rather than about the
/// exception. One case is newly permitted (`testTheAppMayStopItsOwnUsersTrigger`
/// -`Session`); five say what stayed refused, and there is one test per clause
/// of the conjunction, so deleting any clause turns exactly one of them red.
/// See `SessionIsolation.authorize`'s AMENDMENT block for the argument.
final class SessionIsolationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")
    private let bob = ClientID(rawValue: "bob")

    /// Two accounts, because half the amendment is a uid comparison and a
    /// second user is the only way to describe that at all.
    private let me: UInt32 = 501
    private let someoneElse: UInt32 = 502

    private func app(_ uid: UInt32) -> ClientID { ClientRole.app.clientID(forUserID: uid) }
    private func agent(_ uid: UInt32) -> ClientID { ClientRole.agent.clientID(forUserID: uid) }
    private func cli(_ uid: UInt32) -> ClientID { ClientRole.cli.clientID(forUserID: uid) }

    private func session(owner: ClientID, persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(), kind: .indefinite, owner: owner, ownerUID: 0,
                persistence: persistence, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
    }

    /// A session with the two fields the amendment reads spelled out. `kind` is
    /// a lease throughout so that the same session can be handed to both verbs
    /// without `renewLease`'s `.notLease` path standing in for a refusal that
    /// isolation was supposed to make.
    private func session(owner: ClientID, uid: UInt32, origin: SessionOrigin) -> Session {
        Session(id: UUID(), kind: .lease(expires: t0.addingTimeInterval(600)),
                owner: owner, ownerUID: uid, persistence: .detached, origin: origin,
                startedAt: t0, triggerID: origin == .trigger ? UUID() : nil,
                wakeMode: .clamshell, keepsDisksAwake: false)
    }

    /// The caller's `ClientID` is **derived** from the role and uid being
    /// tested rather than passed in beside them, exactly as
    /// `HelperListenerDelegate` derives it (`ClientRole.clientID(forUserID:)`).
    /// A test that could supply `app-501` while claiming to be `.cli` would be
    /// testing an identity the daemon cannot produce.
    private func decision(_ action: SessionIsolation.Action, on session: Session,
                          as role: ClientRole, uid: UInt32,
                          among sessions: [Session]? = nil) -> SessionIsolation.Authorization {
        SessionIsolation.authorize(sessionID: session.id, action: action,
                                   requestedBy: role.clientID(forUserID: uid),
                                   uid: uid, role: role,
                                   among: sessions ?? [session])
    }

    // MARK: - authorize: the ownership check behind stopSession / renewLease

    func testOwnerIsAuthorizedToActOnTheirOwnSession() {
        let mine = session(owner: alice)
        // `.cli` and a uid that matches nothing: the ownership rule below is
        // older than the amendment and answers on its own, without either.
        XCTAssertEqual(SessionIsolation.authorize(sessionID: mine.id, action: .stop,
                                                  requestedBy: alice, uid: me, role: .cli,
                                                  among: [mine]), .authorized)
    }

    func testNonOwnerIsForbiddenFromActingOnAnothersSession() {
        let theirs = session(owner: bob)
        XCTAssertEqual(SessionIsolation.authorize(sessionID: theirs.id, action: .stop,
                                                  requestedBy: alice, uid: me, role: .cli,
                                                  among: [theirs]), .forbidden)
    }

    func testActingOnAnUnknownSessionIsNotFoundRatherThanForbidden() {
        // Distinguished so the caller (HelperService) can report and log
        // "already gone" separately from a rejected cross-client attempt.
        XCTAssertEqual(SessionIsolation.authorize(sessionID: UUID(), action: .stop,
                                                  requestedBy: alice, uid: me, role: .cli,
                                                  among: []), .notFound)
    }

    /// `.notFound` outranks the amendment as well as ownership: a session the
    /// app *would* have been allowed to stop, but which is already gone, is
    /// still routine rather than a rejected cross-client access worth an
    /// error log.
    func testAnAlreadyEndedTriggerSessionIsNotFoundRatherThanAuthorized() {
        let gone = session(owner: agent(me), uid: me, origin: .trigger)
        XCTAssertEqual(decision(.stop, on: gone, as: .app, uid: me, among: []), .notFound)
    }

    // MARK: - The amendment (spec §4's one exception; Plan 8 Task 5)

    /// The only case this task adds. Everything else in this section is a
    /// boundary that had to survive it.
    func testTheAppMayStopItsOwnUsersTriggerSession() {
        let automatic = session(owner: agent(me), uid: me, origin: .trigger)
        XCTAssertEqual(decision(.stop, on: automatic, as: .app, uid: me), .authorized,
                       "the app must be able to end a session this user's own rule started")
    }

    /// Clause: `ownerUID == callerUID`. The amendment must never cross an
    /// account boundary — that is the one this product can never re-earn.
    func testTheAppMayNotStopAnotherUsersTriggerSession() {
        let theirs = session(owner: agent(someoneElse), uid: someoneElse, origin: .trigger)
        XCTAssertEqual(decision(.stop, on: theirs, as: .app, uid: me), .forbidden)
    }

    /// Clause: the owner's role. A `cli-<uid>` session is this user's, but it
    /// is another client's work and `keepy-uppy off` is its own way out.
    ///
    /// It is written with `origin: .trigger` **deliberately**: `origin` is
    /// client-chosen (`HelperProtocol.startSession` passes it through
    /// untouched), so a terminal can simply say "trigger". If the amendment
    /// asked `origin` without asking whose client the owner is, that claim
    /// alone would hand the app authority over this user's command-line
    /// sessions.
    func testTheAppMayNotStopThisUsersCommandLineSession() {
        let terminal = session(owner: cli(me), uid: me, origin: .trigger)
        XCTAssertEqual(decision(.stop, on: terminal, as: .app, uid: me), .forbidden,
                       "a terminal saying \"trigger\" is a claim, not a fact")
    }

    /// Clause: `ownerUID == callerUID`, on its own, which no other test here
    /// can isolate.
    ///
    /// `owner == agent-<callerUID>` already implies the right account for every
    /// session the daemon itself stamped, since it stamps both fields from one
    /// connection — so deleting the uid comparison would leave every other test
    /// in this file green. The case that separates them is a session whose two
    /// owner fields **disagree**, which is exactly the state
    /// `MenuSessionGroup.yoursOtherClient` was written for: not reachable
    /// today, defined anyway, because "unreachable" is a property of the
    /// current three clients and not of the wire, where a `Session` is JSON
    /// this daemon decodes.
    ///
    /// It must be refused. The uid is what binds a session to an account
    /// (`Session.ownerUID` is what `agentDisappeared` and `reportConditionEnded`
    /// key off), so a payload that claims one account in one field and another
    /// in the other is not something to resolve in the amendment's favour.
    func testASessionWhoseOwnerAndOwnerUIDDisagreeIsNotStoppable() {
        let contradictory = Session(id: UUID(), kind: .indefinite,
                                    owner: agent(me), ownerUID: someoneElse,
                                    persistence: .detached, origin: .trigger, startedAt: t0,
                                    triggerID: UUID(), wakeMode: .clamshell, keepsDisksAwake: false)
        XCTAssertEqual(decision(.stop, on: contradictory, as: .app, uid: me), .forbidden)
        XCTAssertEqual(decision(.stop, on: contradictory, as: .app, uid: someoneElse), .forbidden,
                       "and not from the other side either — neither field alone decides")
    }

    /// Clause: the *caller's* role. The widening is the app's alone, because
    /// the app is the surface that shows the session and takes the click. The
    /// CLI already has `off --all`, which is explicit and logged.
    func testTheCLIMayNotStopThisUsersTriggerSession() {
        let automatic = session(owner: agent(me), uid: me, origin: .trigger)
        XCTAssertEqual(decision(.stop, on: automatic, as: .cli, uid: me), .forbidden)
    }

    /// Unchanged direction, and the one that would be worst to lose: the agent
    /// evaluates conditions on the daemon's behalf and must not acquire
    /// authority over the sessions a person started by hand.
    func testTheAgentMayNotStopTheAppsSessions() {
        let manual = session(owner: app(me), uid: me, origin: .manual)
        XCTAssertEqual(decision(.stop, on: manual, as: .agent, uid: me), .forbidden)
    }

    /// Clause: `origin == .trigger`. The agent can start a session no rule
    /// asked for, and that session is the agent's own business.
    func testAnAgentOwnedSessionWithManualOriginIsNotStoppable() {
        let notATrigger = session(owner: agent(me), uid: me, origin: .manual)
        XCTAssertEqual(decision(.stop, on: notATrigger, as: .app, uid: me), .forbidden)
    }

    /// Clause: the **verb**. `authorize` gates `renewLease` as well as
    /// `stopSession`, and the amendment is about ending a session, not about
    /// extending one.
    ///
    /// Not a hypothetical distinction, and not a symmetric one: stopping moves
    /// the Mac towards being allowed to sleep, while renewing keeps it awake
    /// for longer. Nothing in "the app may end what your rules started"
    /// argues for letting the app hold this Mac awake on the agent's behalf,
    /// so the widening stops at the one verb the spec sentence names.
    func testTheAppMayNotRenewItsOwnUsersTriggerSession() {
        let automatic = session(owner: agent(me), uid: me, origin: .trigger)
        XCTAssertEqual(decision(.renew, on: automatic, as: .app, uid: me), .forbidden,
                       "the amendment authorises stopping, not extending")
        XCTAssertEqual(decision(.renew, on: automatic, as: .agent, uid: me), .authorized,
                       "the owner may still renew its own lease")
    }

    /// The widening is a comparison against the caller's **own** uid, not a
    /// second way of saying "any trigger session". The app of one account and
    /// the trigger of another are both real on a shared Mac.
    func testTheAppOfOneAccountGetsNoAuthorityOverAnothersAutomaticSession() {
        let table = [
            session(owner: agent(me), uid: me, origin: .trigger),
            session(owner: agent(someoneElse), uid: someoneElse, origin: .trigger),
        ]
        XCTAssertEqual(decision(.stop, on: table[0], as: .app, uid: me, among: table), .authorized)
        XCTAssertEqual(decision(.stop, on: table[1], as: .app, uid: me, among: table), .forbidden)
        XCTAssertEqual(decision(.stop, on: table[0], as: .app, uid: someoneElse, among: table), .forbidden)
        XCTAssertEqual(decision(.stop, on: table[1], as: .app, uid: someoneElse, among: table), .authorized)
    }

    /// The amendment is **defined as** `Session.startedByTrigger(forUserID:)`
    /// rather than as a fresh conjunction that agrees with it today — the same
    /// weld `menuSessionGroup` has. This is what stops the daemon's rule and
    /// the menu's row from drifting apart: a row with a Stop button that the
    /// daemon refuses, or a session the daemon would end that the menu never
    /// offers.
    func testTheWideningIsExactlyTheTriggerPredicateAndNothingElse() {
        let table = [
            session(owner: agent(me), uid: me, origin: .trigger),
            session(owner: agent(me), uid: me, origin: .manual),
            session(owner: cli(me), uid: me, origin: .trigger),
            session(owner: app(me), uid: me, origin: .trigger),
            session(owner: agent(someoneElse), uid: someoneElse, origin: .trigger),
            session(owner: ClientID(rawValue: "shortcuts-\(me)"), uid: me, origin: .trigger),
        ]
        for candidate in table {
            let authorized = decision(.stop, on: candidate, as: .app, uid: me, among: table) == .authorized
            let wouldBeOursAnyway = candidate.owner == app(me)
            XCTAssertEqual(authorized,
                           wouldBeOursAnyway || candidate.startedByTrigger(forUserID: me),
                           "the app may stop exactly its own sessions plus its own user's "
                           + "trigger sessions: \(candidate.owner.rawValue)/\(candidate.origin.rawValue)")
        }
    }

    // MARK: - end to end: authorization actually gates the mutation

    // Mirrors what DaemonRuntime.stopSession does under its queue: only
    // mutate the engine when SessionIsolation says the caller may.
    private func stop(_ id: UUID, requestedBy: ClientID, uid: UInt32, role: ClientRole,
                      in engine: inout SessionEngine) -> SessionIsolation.Authorization {
        let authorization = SessionIsolation.authorize(sessionID: id, action: .stop,
                                                       requestedBy: requestedBy, uid: uid,
                                                       role: role, among: engine.sessions)
        if authorization == .authorized {
            _ = engine.apply(.stop(id: id), now: t0)
        }
        return authorization
    }

    func testClientStoppingItsOwnSessionSucceeds() {
        var engine = SessionEngine()
        let mine = session(owner: alice)
        _ = engine.apply(.start(mine), now: t0)

        XCTAssertEqual(stop(mine.id, requestedBy: alice, uid: me, role: .cli, in: &engine), .authorized)
        XCTAssertTrue(engine.sessions.isEmpty)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testClientCannotStopAnotherClientsSessionAndItSurvives() {
        var engine = SessionEngine()
        let theirs = session(owner: bob)
        _ = engine.apply(.start(theirs), now: t0)

        XCTAssertEqual(stop(theirs.id, requestedBy: alice, uid: me, role: .cli, in: &engine), .forbidden)
        XCTAssertEqual(engine.sessions.count, 1, "bob's session must survive alice's attempt to stop it")
        XCTAssertEqual(engine.sessions.first?.owner, bob)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    /// The amendment reaching the table, not just the decision: a trigger
    /// session the app asked to end is really gone, and the Mac is really
    /// released when it was the last one.
    func testTheAppsStopOfItsOwnUsersTriggerSessionReallyEndsIt() {
        var engine = SessionEngine()
        let automatic = session(owner: agent(me), uid: me, origin: .trigger)
        _ = engine.apply(.start(automatic), now: t0)

        XCTAssertEqual(stop(automatic.id, requestedBy: app(me), uid: me, role: .app, in: &engine),
                       .authorized)
        XCTAssertTrue(engine.sessions.isEmpty)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    // MARK: - sessionsToStop: the stopAllSessions scoping rule

    /// **The decision Plan 8 Task 5 made about the sweep, as a test.**
    ///
    /// `stopAllSessions(all: false)` was deliberately *not* widened alongside
    /// `authorize`; `SessionIsolation.sessionsToStop`'s doc comment carries the
    /// argument. This pins it, because "we chose not to" and "we forgot" look
    /// identical in a diff a year later.
    func testTheScopedSweepIsNotWidenedByTheAmendment() {
        let mine = session(owner: app(me), uid: me, origin: .manual)
        let automatic = session(owner: agent(me), uid: me, origin: .trigger)
        XCTAssertEqual(SessionIsolation.sessionsToStop(all: false, requestedBy: app(me),
                                                       among: [mine, automatic]),
                       [mine.id],
                       "a sweep still touches only what the caller itself started; the "
                       + "amendment is a per-session decision made on a named row")
    }

    func testScopedStopAllTargetsOnlyTheCallersOwnSessions() {
        let mine = session(owner: alice)
        let theirs = session(owner: bob)
        let ids = SessionIsolation.sessionsToStop(all: false, requestedBy: alice, among: [mine, theirs])
        XCTAssertEqual(ids, [mine.id])
    }

    func testScopedStopAllLeavesOtherClientsSessionsAlone() {
        var engine = SessionEngine()
        let mine = session(owner: alice)
        // A detached session, deliberately outliving whoever started it —
        // exactly the case Task 9's review flagged as vulnerable to an
        // unscoped stopAll from a completely different client.
        let theirsDetached = session(owner: bob, persistence: .detached)
        _ = engine.apply(.start(mine), now: t0)
        _ = engine.apply(.start(theirsDetached), now: t0)

        let ids = SessionIsolation.sessionsToStop(all: false, requestedBy: alice, among: engine.sessions)
        for id in ids { _ = engine.apply(.stop(id: id), now: t0) }

        XCTAssertEqual(engine.sessions.map(\.owner), [bob], "bob's detached session must not be ended by alice's scoped off")
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    func testUnscopedStopAllClearsEverything() {
        var engine = SessionEngine()
        _ = engine.apply(.start(session(owner: alice)), now: t0)
        _ = engine.apply(.start(session(owner: bob, persistence: .detached)), now: t0)

        let ids = SessionIsolation.sessionsToStop(all: true, requestedBy: alice, among: engine.sessions)
        for id in ids { _ = engine.apply(.stop(id: id), now: t0) }

        XCTAssertTrue(engine.sessions.isEmpty, "explicit --all must end every client's sessions, including detached ones")
        XCTAssertFalse(engine.desiredKeepAwake)
    }
}
