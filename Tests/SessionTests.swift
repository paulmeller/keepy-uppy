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

/// `HelperService.startSession`'s trusted/untrusted split — which fields of a
/// client's request the daemon honours and which it overwrites with facts only
/// it can establish. It is the most security-relevant step in starting a
/// session, and while it was written out inline in `Helper/` no test could
/// reach it at all (`Helper/` is not in this target's module graph), so
/// dropping `wakeMode:` or `triggerID:` from it was undetectable — exactly how
/// every session in production ended up `.clamshell` regardless of what was
/// asked for. `Session.authorized(id:owner:ownerUID:startedAt:)` moved it into
/// `Shared/` for the same reason `SessionTable.desiredPowerPlan` lives there.
final class SessionAuthorizationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The whole struct in one comparison, rather than a field list that can
    /// forget the field that matters: `Session` is `Equatable`, the request
    /// below sets every client-chosen field to a non-default value *and*
    /// every server-owned field to something the daemon must refuse to
    /// believe, and the expectation states exactly which of the two each
    /// field should have come from. A field dropped from `authorized` takes
    /// its initialiser default and this fails — **for the fields named
    /// below**.
    ///
    /// That qualifier is the whole point, and it does not stretch to fields
    /// that do not exist yet. The expectation is built with the *same*
    /// memberwise initialiser as the value under test, so a defaulted field
    /// added to `Session` later and named on neither side is absent from both
    /// and compares default-to-default — silently uncovered, in precisely the
    /// way dropping `wakeMode:` from `authorized` once was. Adding a defaulted
    /// field to `Session` means naming it here with a **non-default** value,
    /// and nothing but this sentence will say so.
    /// `DaemonConnectionRequestTests` carries the same warning, for the same
    /// reason.
    func testAuthorizingKeepsWhatTheClientChoseAndOverwritesWhatItCannotBeTrustedWith() {
        let triggerID = UUID()
        let requested = Session(id: UUID(), kind: .whileProcessRunning(processName: "claude"),
                                owner: ClientID(rawValue: "root"), ownerUID: 0,
                                persistence: .detached, origin: .trigger,
                                startedAt: t0, triggerID: triggerID,
                                wakeMode: .systemAndDisplay)

        let serverID = UUID()
        let serverStartedAt = t0.addingTimeInterval(3600)
        let authorized = requested.authorized(id: serverID,
                                              owner: ClientID(rawValue: "cli-501"),
                                              ownerUID: 501, startedAt: serverStartedAt)

        XCTAssertEqual(authorized,
                       Session(id: serverID, kind: .whileProcessRunning(processName: "claude"),
                               owner: ClientID(rawValue: "cli-501"), ownerUID: 501,
                               persistence: .detached, origin: .trigger,
                               startedAt: serverStartedAt, triggerID: triggerID,
                               wakeMode: .systemAndDisplay))
    }

    /// The reason the four server-owned fields are server-owned, stated as
    /// the attacks they refuse rather than as a list.
    func testAClientCannotMintASessionOwnedBySomebodyElse() {
        let claimed = Session(id: UUID(), kind: .indefinite,
                              owner: ClientID(rawValue: "app-502"), ownerUID: 502,
                              persistence: .clientBound, origin: .manual,
                              startedAt: .distantPast)

        let authorized = claimed.authorized(id: UUID(), owner: ClientID(rawValue: "cli-501"),
                                            ownerUID: 501, startedAt: t0)

        XCTAssertEqual(authorized.owner, ClientID(rawValue: "cli-501"),
                       "a client must not be able to start a session owned by another client")
        XCTAssertEqual(authorized.ownerUID, 501,
                       "ownerUID is what binds an agent-evaluated session to a user's agent")
        XCTAssertNotEqual(authorized.id, claimed.id,
                          "a client must not be able to choose an id, and so collide with a live session")
        XCTAssertEqual(authorized.startedAt, t0,
                       "a backdated startedAt would dodge the max-duration backstop, which keys off it")
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

        /// The one other method here that is not a stub. `reset` acts on
        /// *both* of these values — `DaemonRemoval.next(after:)` refuses to
        /// unregister when the second is `false` — so both have to make it
        /// across, and the test sets them to something no default could
        /// accidentally match.
        var removalReply: (stopped: Int, sleepRestored: Bool) = (0, true)

        func prepareForRemoval(reply: @escaping (Int, Bool) -> Void) {
            reply(removalReply.stopped, removalReply.sleepRestored)
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

    /// `reset`'s converge step crosses the same boundary, and unlike everything
    /// else on this protocol its reply is two bare scalars rather than an
    /// encoded payload — a shape `NSXPCInterface` adjudicates when the message
    /// is sent, not when the file compiles. A wrong block signature therefore
    /// shows up as an XPC error at the one moment nobody is watching: partway
    /// through evicting the daemon.
    ///
    /// The values are chosen so no default could pass by accident — `false` is
    /// the one that stops `reset` from unregistering, and it is not what
    /// `EchoingHelper` starts with.
    ///
    /// Own listener and connection, deliberately: the trap called out on the
    /// test above applies verbatim here (`NSXPCListener.delegate` is weak, so a
    /// delegate created inline is deallocated before the first connection
    /// arrives and every connection is silently refused).
    func testTheRemovalReplyCarriesBothValuesOverARealXPCRoundTrip() {
        let listener = NSXPCListener.anonymous()
        let delegate = ListenerDelegate()
        delegate.exported.removalReply = (stopped: 4, sleepRestored: false)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "prepareForRemoval reply")
        replied.assertForOverFulfill = false
        var received: (Int, Bool)?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC error: \(error.localizedDescription)")
            replied.fulfill()
        } as? HelperProtocol
        proxy?.prepareForRemoval { stopped, sleepRestored in
            received = (stopped, sleepRestored)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 10)

        XCTAssertEqual(received?.0, 4, "the session count did not survive the round trip")
        XCTAssertEqual(received?.1, false,
                       "the flag `reset` refuses to unregister on did not survive the round trip")
    }
}
