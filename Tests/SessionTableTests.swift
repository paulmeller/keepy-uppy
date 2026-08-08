import XCTest
@testable import KeepyUppy

final class SessionTableTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")
    private let bob = ClientID(rawValue: "bob")

    private func session(_ id: String, owner: ClientID,
                         persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                kind: .indefinite, owner: owner,
                persistence: persistence, origin: .manual, startedAt: t0)
    }

    func testEmptyTableWantsSleepEnabled() {
        XCTAssertFalse(SessionTable().desiredKeepAwake)
    }

    func testAnySessionKeepsAwake() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemovingLastSessionRestoresSleep() {
        var table = SessionTable()
        let a = session("01", owner: alice)
        let b = session("02", owner: bob)
        table.insert(a); table.insert(b)
        table.remove(id: a.id)
        XCTAssertTrue(table.desiredKeepAwake, "bob's session still holds it")
        table.remove(id: b.id)
        XCTAssertFalse(table.desiredKeepAwake, "no sessions left, sleep must come back")
    }

    func testRemoveAllOwnedByEndsOnlyClientBoundSessions() {
        var table = SessionTable()
        table.insert(session("01", owner: alice, persistence: .clientBound))
        table.insert(session("02", owner: alice, persistence: .detached))
        let ended = table.removeAll(ownedBy: alice)
        XCTAssertEqual(ended.count, 1, "detached sessions survive their owner")
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemoveAllOwnedByLeavesOtherOwnersAlone() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.insert(session("02", owner: bob))
        _ = table.removeAll(ownedBy: alice)
        XCTAssertEqual(table.sessions.count, 1)
        XCTAssertEqual(table.sessions.first?.owner, bob)
    }

    func testRemovingUnknownSessionIsHarmless() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.remove(id: UUID())
        XCTAssertTrue(table.desiredKeepAwake)
        XCTAssertEqual(table.sessions.count, 1)
    }

    // MARK: - Fix 1: count/lookup accessors that don't materialise the whole table

    func testCountReflectsInsertsAndRemoves() {
        var table = SessionTable()
        XCTAssertEqual(table.count, 0)
        let a = session("01", owner: alice)
        table.insert(a)
        XCTAssertEqual(table.count, 1)
        table.remove(id: a.id)
        XCTAssertEqual(table.count, 0)
    }

    func testCountOwnedByCountsOnlyThatOwner() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.insert(session("02", owner: alice))
        table.insert(session("03", owner: bob))
        XCTAssertEqual(table.count(ownedBy: alice), 2)
        XCTAssertEqual(table.count(ownedBy: bob), 1)
    }

    func testSessionLookupByID() {
        var table = SessionTable()
        let a = session("01", owner: alice)
        table.insert(a)
        XCTAssertEqual(table.session(id: a.id), a)
        XCTAssertNil(table.session(id: UUID()))
    }

    // MARK: - Fix 1: removeExpired

    private func timedSession(_ id: String, deadline: Date, owner: ClientID) -> Session {
        Session(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                kind: .duration(until: deadline), owner: owner,
                persistence: .clientBound, origin: .manual, startedAt: t0)
    }

    func testRemoveExpiredIsANoOpWhenNothingIsDue() {
        var table = SessionTable()
        table.insert(timedSession("01", deadline: t0.addingTimeInterval(3600), owner: alice))
        XCTAssertTrue(table.removeExpired(at: t0).isEmpty)
        XCTAssertEqual(table.count, 1)
    }

    func testRemoveExpiredRemovesOnlyDueSessions() {
        var table = SessionTable()
        let due = timedSession("01", deadline: t0.addingTimeInterval(60), owner: alice)
        let notDue = timedSession("02", deadline: t0.addingTimeInterval(3600), owner: bob)
        table.insert(due)
        table.insert(notDue)

        let expired = table.removeExpired(at: t0.addingTimeInterval(61))

        XCTAssertEqual(expired.map(\.id), [due.id])
        XCTAssertEqual(table.sessions.map(\.id), [notDue.id])
    }

    func testRemoveExpiredSelfHealsSoALaterDueSessionIsStillCaught() {
        var table = SessionTable()
        let soon = timedSession("01", deadline: t0.addingTimeInterval(60), owner: alice)
        let later = timedSession("02", deadline: t0.addingTimeInterval(120), owner: bob)
        table.insert(soon)
        table.insert(later)

        XCTAssertEqual(table.removeExpired(at: t0.addingTimeInterval(61)).map(\.id), [soon.id])
        // The cached earliest-deadline bound must have been tightened to
        // `later`'s deadline, not left stale, or this second call would
        // wrongly report nothing due.
        XCTAssertEqual(table.removeExpired(at: t0.addingTimeInterval(121)).map(\.id), [later.id])
        XCTAssertTrue(table.sessions.isEmpty)
    }

    func testIndefiniteSessionsAreNeverConsideredDue() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertTrue(table.removeExpired(at: .distantFuture).isEmpty)
        XCTAssertEqual(table.count, 1)
    }
}

/// `isDaemonEvaluable` decides whether a session survives the agent going
/// away (spec §5). A wrong answer here is a safety bug that the type checker
/// cannot catch, so every case is pinned explicitly.
final class SessionKindEvaluationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDaemonEvaluableKinds() {
        XCTAssertTrue(SessionKind.indefinite.isDaemonEvaluable)
        XCTAssertTrue(SessionKind.duration(until: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.untilTime(t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.lease(expires: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.whileOnACPower.isDaemonEvaluable)
    }

    func testAgentEvaluatedKinds() {
        XCTAssertFalse(SessionKind.whileAppRunning(bundleID: "com.apple.dt.Xcode").isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileExternalDisplay.isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileCPUBusy(threshold: 0.5).isDaemonEvaluable)
        // Added with the kind itself, but not with this test: only the agent
        // can see the process table, so a `.whileProcessRunning` session that
        // outlived the agent would be a session nothing could ever end.
        XCTAssertFalse(SessionKind.whileProcessRunning(processName: "claude").isDaemonEvaluable)
    }

    /// `.whileProcessRunning` was added to `SessionKind` and to
    /// `isDaemonEvaluable` without being added to the two tests above, and
    /// nothing complained — which is precisely the hole the comment on this
    /// class describes. The `switch` below closes it: it is exhaustive, so
    /// the next `SessionKind` case stops this file compiling until somebody
    /// writes down, here, which half of the world it belongs to.
    func testEveryKindHasAPinnedAnswer() {
        let allKinds: [SessionKind] = [
            .indefinite, .duration(until: t0), .untilTime(t0), .lease(expires: t0), .whileOnACPower,
            .whileAppRunning(bundleID: "com.apple.dt.Xcode"), .whileExternalDisplay,
            .whileCPUBusy(threshold: 0.5), .whileProcessRunning(processName: "claude"),
        ]
        for kind in allKinds {
            let daemonCanEvaluateItAlone: Bool
            switch kind {
            case .indefinite, .duration, .untilTime, .lease:
                daemonCanEvaluateItAlone = true   // pure clock arithmetic
            case .whileOnACPower:
                daemonCanEvaluateItAlone = true   // the daemon reads IOKit power itself
            case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy, .whileProcessRunning:
                daemonCanEvaluateItAlone = false  // needs the agent's observers
            }
            XCTAssertEqual(kind.isDaemonEvaluable, daemonCanEvaluateItAlone, "\(kind)")
        }
        XCTAssertEqual(allKinds.count, 9, "a case was added to SessionKind but not to allKinds")
    }
}
