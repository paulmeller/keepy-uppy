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

/// Plan 4 Task 4 rests on the claim that `wakeMode` needs **no XPC protocol
/// change**, because `Session` already crosses the boundary as a JSON blob
/// (`HelperProtocol.startSession(_ sessionJSON: Data, …)`). That is a claim
/// about the *transport*, and `WakeModeTests` above cannot check it — those
/// tests round-trip through `JSONEncoder` in one process and never touch
/// NSXPC.
///
/// So this drives a real `NSXPCConnection`, over the real
/// `NSXPCInterface(with: HelperProtocol.self)` both ends of the product use,
/// with the exact bytes `CLI/main.swift` puts on the wire. The far side
/// replies with the `wakeMode` it decoded from what it actually received, so
/// a value lost or flattened anywhere between `encode` and `decode` shows up
/// as a wrong string rather than as a silent `.clamshell`.
///
/// An anonymous listener rather than the daemon's Mach service, deliberately:
/// no privileged service, no code-signing requirement, and nothing to install
/// — this exercises the serialization path, which is the only part of the
/// claim that could be false.
final class SessionOverXPCTransportTests: XCTestCase {
    /// Echoes back the `wakeMode` it decoded, as `startSession`'s "session
    /// id" reply. Every other method is an unused stub: `HelperProtocol` is
    /// an `@objc` protocol, so conformance must be complete even though this
    /// test sends exactly one message.
    private final class EchoingHelper: NSObject, HelperProtocol {
        func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) {
            guard let session = try? JSONDecoder().decode(Session.self, from: sessionJSON) else {
                return reply(nil, "invalid session payload")
            }
            reply(session.wakeMode.rawValue, nil)
        }

        func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void) { reply(0, "unused") }
        func listSessions(reply: @escaping (Data?, String?) -> Void) { reply(nil, "unused") }
        func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func registerAsAgent(reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func currentState(reply: @escaping (Bool) -> Void) { reply(false) }
        func version(reply: @escaping (String) -> Void) { reply("test") }
    }

    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        let exported = EchoingHelper()
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
            new.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            new.exportedObject = exported
            new.resume()
            return true
        }
    }

    /// Every mode, not just one: this is the check that the enum's *values*
    /// survive, so testing only `.system` would pass even if every payload
    /// arrived as the same mode.
    func testEveryWakeModeSurvivesARealXPCRoundTrip() throws {
        let listener = NSXPCListener.anonymous()
        // `NSXPCListener.delegate` is weak — see Helper/main.swift's comment
        // on the same trap. A delegate created inline would be deallocated
        // before the first connection arrives, and every connection silently
        // refused.
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        for mode in WakeMode.allCases {
            let replied = expectation(description: "reply for \(mode.rawValue)")
            // The error handler and the reply block arrive on different
            // queues and either may be the one that runs; the expectation
            // tolerates both rather than trapping on over-fulfilment.
            replied.assertForOverFulfill = false
            var echoed: String?
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                XCTFail("XPC error for \(mode.rawValue): \(error.localizedDescription)")
                replied.fulfill()
            } as? HelperProtocol
            let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                                  ownerUID: 501, persistence: .detached, origin: .manual,
                                  startedAt: Date(), wakeMode: mode)
            let payload = try JSONEncoder().encode(session)
            proxy?.startSession(payload) { decoded, _ in
                echoed = decoded
                replied.fulfill()
            }
            wait(for: [replied], timeout: 10)
            XCTAssertEqual(echoed, mode.rawValue,
                           "wakeMode \(mode.rawValue) did not survive the XPC round trip")
        }
    }
}
