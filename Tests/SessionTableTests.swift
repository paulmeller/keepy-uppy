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
}
