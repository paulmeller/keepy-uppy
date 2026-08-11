import XCTest
@testable import KeepyUppy

/// Task 10: cross-client isolation ("every client is equally entitled to
/// start and stop *its own* sessions" — spec §4) is pure logic, kept in
/// `SessionIsolation` precisely so it is unit-testable without XPC or a
/// running daemon.
final class SessionIsolationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")
    private let bob = ClientID(rawValue: "bob")

    private func session(owner: ClientID, persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(), kind: .indefinite, owner: owner, ownerUID: 0,
                persistence: persistence, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
    }

    // MARK: - authorize: the ownership check behind stopSession / renewLease

    func testOwnerIsAuthorizedToActOnTheirOwnSession() {
        let mine = session(owner: alice)
        XCTAssertEqual(SessionIsolation.authorize(sessionID: mine.id, requestedBy: alice, among: [mine]), .authorized)
    }

    func testNonOwnerIsForbiddenFromActingOnAnothersSession() {
        let theirs = session(owner: bob)
        XCTAssertEqual(SessionIsolation.authorize(sessionID: theirs.id, requestedBy: alice, among: [theirs]), .forbidden)
    }

    func testActingOnAnUnknownSessionIsNotFoundRatherThanForbidden() {
        // Distinguished so the caller (HelperService) can report and log
        // "already gone" separately from a rejected cross-client attempt.
        XCTAssertEqual(SessionIsolation.authorize(sessionID: UUID(), requestedBy: alice, among: []), .notFound)
    }

    // MARK: - end to end: authorization actually gates the mutation

    // Mirrors what DaemonRuntime.stopSession does under its queue: only
    // mutate the engine when SessionIsolation says the caller may.
    private func stop(_ id: UUID, requestedBy: ClientID, in engine: inout SessionEngine) -> SessionIsolation.Authorization {
        let authorization = SessionIsolation.authorize(sessionID: id, requestedBy: requestedBy, among: engine.sessions)
        if authorization == .authorized {
            _ = engine.apply(.stop(id: id), now: t0)
        }
        return authorization
    }

    func testClientStoppingItsOwnSessionSucceeds() {
        var engine = SessionEngine()
        let mine = session(owner: alice)
        _ = engine.apply(.start(mine), now: t0)

        XCTAssertEqual(stop(mine.id, requestedBy: alice, in: &engine), .authorized)
        XCTAssertTrue(engine.sessions.isEmpty)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testClientCannotStopAnotherClientsSessionAndItSurvives() {
        var engine = SessionEngine()
        let theirs = session(owner: bob)
        _ = engine.apply(.start(theirs), now: t0)

        XCTAssertEqual(stop(theirs.id, requestedBy: alice, in: &engine), .forbidden)
        XCTAssertEqual(engine.sessions.count, 1, "bob's session must survive alice's attempt to stop it")
        XCTAssertEqual(engine.sessions.first?.owner, bob)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    // MARK: - sessionsToStop: the stopAllSessions scoping rule

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
