import XCTest
@testable import KeepyUppy

/// The daemon used to mint `ClientID(rawValue: UUID().uuidString)` for every
/// accepted XPC connection, so no two invocations of anything were ever the
/// same "client". `keepy-uppy off` (no flags) scopes to the caller's own
/// `ClientID` (`SessionIsolation.sessionsToStop(all: false, ...)`), so it
/// could never stop a session a *previous* `keepy-uppy on` had started: it
/// matched nothing and still exited 0 while the Mac stayed awake.
///
/// The fix derives the identity from two server-side facts instead — the
/// accepting listener's role and the peer's authenticated uid — which makes
/// it stable across invocations without making it forgeable. The derivation
/// lives in `Shared/ClientIdentity.swift` as a pure function precisely so it
/// is testable here: `Helper/` is not reachable from the test target.
final class ClientIdentityTests: XCTestCase {
    // MARK: - Stability: the property the bug was the absence of

    func testSameRoleAndSameUserAlwaysProduceTheSameIdentity() {
        // Two separate `keepy-uppy` invocations by the same user: two
        // processes, two connections, one owner.
        XCTAssertEqual(ClientRole.cli.clientID(forUserID: 501),
                       ClientRole.cli.clientID(forUserID: 501))
    }

    func testIdentityIsStableForEveryRole() {
        for role in ClientRole.allCases {
            XCTAssertEqual(role.clientID(forUserID: 501), role.clientID(forUserID: 501),
                           "\(role.rawValue) must derive one stable identity per user")
        }
    }

    // MARK: - Isolation: what stability must not cost

    func testDifferentRolesForTheSameUserAreDifferentIdentities() {
        let ids = ClientRole.allCases.map { $0.clientID(forUserID: 501) }
        XCTAssertEqual(Set(ids).count, ClientRole.allCases.count,
                       "app, agent and CLI must stay isolated from each other: \(ids.map(\.rawValue))")
    }

    func testTheSameRoleForDifferentUsersAreDifferentIdentities() {
        for role in ClientRole.allCases {
            XCTAssertNotEqual(role.clientID(forUserID: 501), role.clientID(forUserID: 502),
                              "\(role.rawValue) must stay isolated per user on a multi-user Mac")
        }
    }

    /// Every (role, uid) pair across a plausible multi-user machine must be
    /// distinct — no two combinations may collide into one owner, which
    /// would silently merge two clients' session ownership.
    func testNoRoleAndUserCombinationCollides() {
        var seen: Set<String> = []
        for role in ClientRole.allCases {
            for uid in UInt32(0)...UInt32(64) {
                let id = role.clientID(forUserID: uid).rawValue
                XCTAssertTrue(seen.insert(id).inserted, "identity collision on \(id)")
            }
        }
    }

    func testIdentityIsTheDocumentedRoleAndUserComposition() {
        XCTAssertEqual(ClientRole.cli.clientID(forUserID: 501).rawValue, "cli-501")
        XCTAssertEqual(ClientRole.app.clientID(forUserID: 501).rawValue, "app-501")
        XCTAssertEqual(ClientRole.agent.clientID(forUserID: 501).rawValue, "agent-501")
    }

    // MARK: - isAgent is preserved exactly

    /// `isAgent` gates `reportConditionEnded` and `registerAsAgent`
    /// (`HelperService`). Replacing the old `isAgent: Bool` init parameter
    /// with a role must not have widened it by one case.
    func testOnlyTheAgentRoleIsTheAgent() {
        XCTAssertTrue(ClientRole.agent.isAgent)
        XCTAssertFalse(ClientRole.app.isAgent)
        XCTAssertFalse(ClientRole.cli.isAgent)
    }
}

/// The bug end to end, at the level `keepy-uppy off` actually runs: a session
/// started by one CLI invocation, then the scoped stop a *separate*
/// invocation issues. Pure logic — `SessionIsolation` + the identity
/// derivation — so no daemon or XPC connection is involved.
final class StableIdentityStopScopingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let uid: UInt32 = 501

    /// What `HelperService.startSession` builds: the client's payload with
    /// `owner` overwritten by the server-derived identity.
    private func serverStartedSession(role: ClientRole,
                                      userID: UInt32,
                                      persistence: SessionPersistence = .detached) -> Session {
        Session(id: UUID(), kind: .duration(until: t0.addingTimeInterval(300)),
                owner: role.clientID(forUserID: userID), ownerUID: userID,
                persistence: persistence, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
    }

    func testASeparateCLIInvocationStopsTheSessionAnEarlierOneStarted() {
        // `keepy-uppy on --for 5m` — detached, so it deliberately outlives
        // the process that started it.
        var engine = SessionEngine()
        let started = serverStartedSession(role: .cli, userID: uid)
        _ = engine.apply(.start(started), now: t0)
        XCTAssertTrue(engine.desiredKeepAwake)

        // A brand-new `keepy-uppy off` process: different pid, different
        // connection, same derived identity.
        let secondInvocation = ClientRole.cli.clientID(forUserID: uid)
        let ids = SessionIsolation.sessionsToStop(all: false, requestedBy: secondInvocation,
                                                  among: engine.sessions)
        XCTAssertEqual(ids, [started.id], "off must match the earlier invocation's session")

        for id in ids { _ = engine.apply(.stop(id: id), now: t0) }
        XCTAssertTrue(engine.sessions.isEmpty)
        XCTAssertFalse(engine.desiredKeepAwake, "sleep must be re-enabled — the whole point of `off`")
    }

    /// The pre-fix behaviour, asserted so the regression is unmistakable: a
    /// fresh per-connection identity matches nothing, which is exactly the
    /// silent no-op `off` used to be.
    func testAPerConnectionRandomIdentityWouldHaveMatchedNothing() {
        let started = serverStartedSession(role: .cli, userID: uid)
        let freshPerConnectionIdentity = ClientID(rawValue: UUID().uuidString)
        XCTAssertEqual(
            SessionIsolation.sessionsToStop(all: false, requestedBy: freshPerConnectionIdentity,
                                            among: [started]),
            [],
            "this is the bug: a per-connection identity can never own a previous invocation's session")
    }

    func testTheCLIsScopedOffDoesNotStopTheAppsSessions() {
        let cliSession = serverStartedSession(role: .cli, userID: uid)
        let appSession = serverStartedSession(role: .app, userID: uid, persistence: .clientBound)
        let ids = SessionIsolation.sessionsToStop(all: false,
                                                  requestedBy: ClientRole.cli.clientID(forUserID: uid),
                                                  among: [cliSession, appSession])
        XCTAssertEqual(ids, [cliSession.id],
                       "stable identities must not merge the CLI and the menu-bar app into one owner")
    }

    func testOneUsersScopedOffDoesNotStopAnothersSessions() {
        let mine = serverStartedSession(role: .cli, userID: 501)
        let theirs = serverStartedSession(role: .cli, userID: 502)
        let ids = SessionIsolation.sessionsToStop(all: false,
                                                  requestedBy: ClientRole.cli.clientID(forUserID: 501),
                                                  among: [mine, theirs])
        XCTAssertEqual(ids, [mine.id], "per-user isolation must survive stable identities")
    }

    func testExplicitAllStillEndsEveryonesSessions() {
        let mine = serverStartedSession(role: .cli, userID: 501)
        let theirs = serverStartedSession(role: .app, userID: 502)
        let ids = SessionIsolation.sessionsToStop(all: true,
                                                  requestedBy: ClientRole.cli.clientID(forUserID: 501),
                                                  among: [mine, theirs])
        XCTAssertEqual(Set(ids), Set([mine.id, theirs.id]))
    }

    /// `authorize` (behind `off --session <id>` and `renewLease`) reads the
    /// same identity, so a separate invocation can now target a specific
    /// session it started earlier too.
    ///
    /// The second assertion is the cross-role half, and it survived Plan 8
    /// Task 5 untouched: the app still cannot stop this user's *command-line*
    /// session. That amendment is `agent-<uid>`-owned trigger sessions and
    /// nothing else — `origin` is `.manual` here, and the owner is the CLI on
    /// both counts.
    func testASeparateInvocationIsAuthorizedOnItsEarlierSession() {
        let started = serverStartedSession(role: .cli, userID: uid)
        XCTAssertEqual(
            SessionIsolation.authorize(sessionID: started.id, action: .stop,
                                       requestedBy: ClientRole.cli.clientID(forUserID: uid),
                                       uid: uid, role: .cli,
                                       among: [started]),
            .authorized)
        XCTAssertEqual(
            SessionIsolation.authorize(sessionID: started.id, action: .stop,
                                       requestedBy: ClientRole.app.clientID(forUserID: uid),
                                       uid: uid, role: .app,
                                       among: [started]),
            .forbidden)
    }

    /// `SessionAdmission.maxSessionsPerOwner` was "close to decorative"
    /// while reconnecting minted a new owner. With a stable identity the
    /// same client's 21st session is refused however many times it
    /// reconnects in between.
    func testThePerOwnerCapIsNowReachableByOneReconnectingClient() {
        var engine = SessionEngine()
        let owner = ClientRole.cli.clientID(forUserID: uid)
        for _ in 0..<SessionAdmission.maxSessionsPerOwner {
            let session = Session(id: UUID(), kind: .indefinite, owner: owner, ownerUID: uid,
                                  persistence: .detached, origin: .manual, startedAt: t0,
                                  triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
            XCTAssertEqual(engine.startSession(session, now: t0, liveAgentConnections: 1), .admitted)
        }
        let oneMore = Session(id: UUID(), kind: .indefinite, owner: owner, ownerUID: uid,
                              persistence: .detached, origin: .manual, startedAt: t0,
                              triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
        XCTAssertEqual(engine.startSession(oneMore, now: t0, liveAgentConnections: 1),
                       .ownerLimitReached,
                       "a reconnecting client must not get a fresh per-owner allowance")
    }
}
