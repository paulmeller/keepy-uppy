import XCTest
@testable import KeepyUppy

final class ClientTableTests: XCTestCase {
    func testEmptyTableWantsSleepEnabled() {
        let table = ClientTable<Int>()
        XCTAssertFalse(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 0)
    }

    func testSingleClientRequestingKeepsAwake() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testAnyClientWantingIsEnough() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(2, wantsAwake: false)
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testLastRequesterDisconnectingRestoresSleep() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(2, wantsAwake: true)
        table.remove(1)
        XCTAssertTrue(table.desiredKeepAwake, "second client still wants it")
        table.remove(2)
        XCTAssertFalse(table.desiredKeepAwake, "no clients left, sleep must come back")
    }

    func testClientWithdrawingRequestRestoresSleep() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(1, wantsAwake: false)
        XCTAssertFalse(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 1, "still connected, just not requesting")
    }

    func testRemovingUnknownClientIsHarmless() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.remove(99)
        XCTAssertTrue(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 1)
    }
}
