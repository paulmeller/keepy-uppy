import XCTest
@testable import KeepyUppy

final class WakeModeTests: XCTestCase {
    func testClamshellIsTheOnlyModeRequiringTheGlobalSetting() {
        XCTAssertTrue(WakeMode.clamshell.requiresSleepDisabled)
        XCTAssertFalse(WakeMode.system.requiresSleepDisabled)
        XCTAssertFalse(WakeMode.systemAndDisplay.requiresSleepDisabled)
    }

    func testOnlyDisplayModesHoldTheDisplayAssertion() {
        XCTAssertFalse(WakeMode.system.holdsDisplayAwake)
        XCTAssertTrue(WakeMode.systemAndDisplay.holdsDisplayAwake)
        // Clamshell means the lid is shut; there is no display to hold awake,
        // and asking for one would be a contradiction rather than a no-op.
        XCTAssertFalse(WakeMode.clamshell.holdsDisplayAwake)
    }

    func testDecodingASessionWithoutAWakeModeDefaultsToClamshell() throws {
        // Every session that exists today is a clamshell session; a stored
        // session predating this field must not silently become weaker.
        //
        // This is the *actual* shape JSONEncoder produces for a real
        // Session (round-tripped and confirmed empirically, not copied from
        // the brief's illustrative sample): ClientID encodes as a bare
        // string via its RawRepresentable Codable conformance, Date encodes
        // as a Double (seconds since the 2001 reference date, not since
        // 1970), and an absent `triggerID` key is simply omitted. This
        // legacy payload has no "wakeMode" key at all.
        let legacy = #"{"ownerUID":501,"id":"A4C6403A-9AC7-49FD-8276-C740C220A1C2","origin":"manual","kind":{"indefinite":{}},"startedAt":-978307200,"owner":"cli-501","persistence":"detached"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(legacy.utf8))
        XCTAssertEqual(session.wakeMode, .clamshell)
    }

    func testWakeModeRoundTripsThroughEncodingWhenNotClamshell() throws {
        // Guards against the trap this task turned up while implementing:
        // giving `wakeMode` a default value at the *property declaration*
        // (`let wakeMode: WakeMode = .clamshell`) makes Swift exclude it
        // from synthesized Decodable entirely, so it always decodes back to
        // .clamshell regardless of what was actually encoded. A real
        // non-clamshell wakeMode must survive an encode/decode round trip.
        let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                               ownerUID: 501, persistence: .detached, origin: .manual,
                               startedAt: Date(timeIntervalSince1970: 0), wakeMode: .systemAndDisplay)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded.wakeMode, .systemAndDisplay)
    }

    func testMemberwiseInitializerDefaultsToClamshell() {
        let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                               persistence: .detached, origin: .manual, startedAt: Date())
        XCTAssertEqual(session.wakeMode, .clamshell)
    }
}
