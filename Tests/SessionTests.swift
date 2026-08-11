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
                               startedAt: Date(timeIntervalSince1970: 0), triggerID: nil,
                               wakeMode: .systemAndDisplay, keepsDisksAwake: false)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded.wakeMode, .systemAndDisplay)
    }

    // `testMemberwiseInitializerDefaultsToClamshell` used to sit here, asserting
    // that a `Session` built without a `wakeMode:` came back `.clamshell`. That
    // default is gone — every parameter of `Session.init` is now required — so
    // the test no longer compiles, and there is nothing left for it to assert:
    // the guarantee it stood for is now the compiler's, at every construction
    // site rather than at this one. The *decode*-time default it was often
    // confused with is a different mechanism and is still pinned, one test up.
}

/// The third power axis at the `Session` layer: it is stored, it is
/// client-chosen, and it crosses the wire — nothing here knows what an
/// assertion is (that is `PowerRequest`'s and `PowerPlan`'s job).
///
/// The two decode-time defaults point in **opposite directions on purpose**,
/// and these tests are where that is written down as behaviour rather than as
/// a comment. An absent `wakeMode` decodes to `.clamshell`, the *strongest*
/// mode, because every session that existed before that field did was a
/// clamshell session and weakening one on decode loses a user's work. An absent
/// `keepsDisksAwake` decodes to `false`, the *weakest* state, because no
/// session that existed before this field asked for it, and inventing a held
/// assertion for a session that never requested one is over-application: a Mac
/// whose disks never spin down, for a reason nothing on screen explains.
final class SessionDiskAxisTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDecodingASessionWithoutTheDiskAxisDefaultsToFalse() throws {
        // The same real payload `testDecodingASessionWithoutAWakeModeDefaultsToClamshell`
        // uses — a session written before either field existed — so both
        // directions are read off one document rather than two that could
        // drift.
        let legacy = #"{"ownerUID":501,"id":"A4C6403A-9AC7-49FD-8276-C740C220A1C2","origin":"manual","kind":{"indefinite":{}},"startedAt":-978307200,"owner":"cli-501","persistence":"detached"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(legacy.utf8))

        XCTAssertFalse(session.keepsDisksAwake,
                       "an absent disk axis must decode to the WEAKEST state: nobody asked for it")
        XCTAssertEqual(session.wakeMode, .clamshell,
                       "and an absent wake mode must still decode to the STRONGEST mode, "
                       + "which is the opposite direction and stays that way")
    }

    func testTheDiskAxisRoundTripsThroughEncoding() throws {
        // The declaration-site-default trap `testWakeModeRoundTripsThroughEncodingWhenNotClamshell`
        // documents, on the new field: `let keepsDisksAwake: Bool = false` would
        // make Swift exclude the property from synthesized Decodable entirely,
        // so a real `true` would come back `false` after any round trip — a
        // session silently dropping the axis it was started for.
        let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                              ownerUID: 501, persistence: .detached, origin: .manual,
                              startedAt: t0, triggerID: nil, wakeMode: .system,
                              keepsDisksAwake: true)
        let decoded = try JSONDecoder().decode(Session.self,
                                               from: try JSONEncoder().encode(session))

        XCTAssertTrue(decoded.keepsDisksAwake)
        XCTAssertEqual(decoded, session, "and nothing else moved on the way through")
    }

    /// `renewed(until:)` must carry every field but the deadline across, as one
    /// `Session == Session` comparison rather than a field list that can forget
    /// the field that matters — the shape
    /// `SessionEngineTests.testRenewingALeaseMovesTheDeadlineAndChangesNothingElse`
    /// established, here at the level of the function itself rather than through
    /// the engine.
    ///
    /// Both values, not just `true`: a `renewed` that hard-coded `true` would
    /// pass a one-value test while inventing an assertion for every renewed
    /// lease, which is precisely the over-application half of the mutator rule.
    func testRenewalCarriesTheDiskAxisAcross() {
        for wanted in [false, true] {
            let id = UUID()
            let triggerID = UUID()
            func lease(expires: Date) -> Session {
                Session(id: id, kind: .lease(expires: expires),
                        owner: ClientID(rawValue: "agent-501"), ownerUID: 501,
                        persistence: .detached, origin: .trigger, startedAt: t0,
                        triggerID: triggerID, wakeMode: .system, keepsDisksAwake: wanted)
            }

            let renewed = lease(expires: t0.addingTimeInterval(60))
                .renewed(until: t0.addingTimeInterval(120))

            XCTAssertEqual(renewed, lease(expires: t0.addingTimeInterval(120)),
                           "renewing a lease that asked for keepsDisksAwake=\(wanted) "
                           + "must move the deadline and nothing else")
        }
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
    /// That qualifier is the whole point, and it used to have to be maintained
    /// by hand: the expectation is built with the *same* memberwise initialiser
    /// as the value under test, so a **defaulted** field added to `Session` later
    /// and named on neither side was absent from both and compared
    /// default-to-default — silently uncovered, in precisely the way dropping
    /// `wakeMode:` from `authorized` once was.
    ///
    /// `Session.init` now has **no defaulted parameters at all**, so that hole is
    /// closed structurally: a new field cannot be left off either side of this
    /// comparison, because neither side would compile. What is still on a human
    /// is giving it a **non-default value** here — a new `Bool` named `false` on
    /// both sides compiles and proves nothing. `keepsDisksAwake` is therefore
    /// `true` below, exactly as `wakeMode` is `.systemAndDisplay`.
    /// `DaemonConnectionRequestTests` carries the same warning, for the same
    /// reason.
    func testAuthorizingKeepsWhatTheClientChoseAndOverwritesWhatItCannotBeTrustedWith() {
        let triggerID = UUID()
        let requested = Session(id: UUID(), kind: .whileProcessRunning(processName: "claude"),
                                owner: ClientID(rawValue: "root"), ownerUID: 0,
                                persistence: .detached, origin: .trigger,
                                startedAt: t0, triggerID: triggerID,
                                wakeMode: .systemAndDisplay, keepsDisksAwake: true)

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
                               wakeMode: .systemAndDisplay, keepsDisksAwake: true))
    }

    /// The disk axis is **client-chosen**, like `kind` and `wakeMode`, and not
    /// server-owned like `owner` — whether a session also holds disks out of
    /// idle is the caller's business, and no value of it lets one client affect
    /// another's session (the daemon unions every live session's request itself).
    ///
    /// Not a duplicate of the test above, which pins one value: an `authorized`
    /// that hard-coded `keepsDisksAwake: true` would pass it while inventing an
    /// assertion for every session that never asked for one. Both directions,
    /// each as a whole-struct comparison, is what rules that out.
    func testAuthorizingCarriesTheDiskAxisAcross() {
        for wanted in [false, true] {
            let requested = Session(id: UUID(), kind: .indefinite,
                                    owner: ClientID(rawValue: "root"), ownerUID: 0,
                                    persistence: .detached, origin: .manual,
                                    startedAt: t0, triggerID: nil,
                                    wakeMode: .system, keepsDisksAwake: wanted)

            let serverID = UUID()
            let authorized = requested.authorized(id: serverID,
                                                  owner: ClientID(rawValue: "cli-501"),
                                                  ownerUID: 501, startedAt: t0)

            XCTAssertEqual(authorized,
                           Session(id: serverID, kind: .indefinite,
                                   owner: ClientID(rawValue: "cli-501"), ownerUID: 501,
                                   persistence: .detached, origin: .manual,
                                   startedAt: t0, triggerID: nil,
                                   wakeMode: .system, keepsDisksAwake: wanted),
                           "a client asking for keepsDisksAwake=\(wanted) must get exactly that")
        }
    }

    /// The reason the four server-owned fields are server-owned, stated as
    /// the attacks they refuse rather than as a list.
    func testAClientCannotMintASessionOwnedBySomebodyElse() {
        let claimed = Session(id: UUID(), kind: .indefinite,
                              owner: ClientID(rawValue: "app-502"), ownerUID: 502,
                              persistence: .clientBound, origin: .manual,
                              startedAt: .distantPast, triggerID: nil,
                              wakeMode: .clamshell, keepsDisksAwake: false)

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
    /// Echoes back the **whole `PowerRequest`** it decoded, as `startSession`'s
    /// "session id" reply. Every other method is an unused stub:
    /// `HelperProtocol` is an `@objc` protocol, so conformance must be complete
    /// even though this test sends exactly one message.
    ///
    /// Both axes in one string, rather than the wake mode alone: the claim under
    /// test is that `Session` crossing as JSON carries a client's *request*, and
    /// a reply that mentioned one axis would pass while the other was dropped on
    /// the wire — which is exactly the failure a new field can have.
    private final class EchoingHelper: NSObject, HelperProtocol {
        static func echo(_ power: PowerRequest) -> String {
            "\(power.wakeMode.rawValue)/disks=\(power.keepsDisksAwake)"
        }

        func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) {
            guard let session = try? JSONDecoder().decode(Session.self, from: sessionJSON) else {
                return reply(nil, "invalid session payload")
            }
            reply(Self.echo(session.power), nil)
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

    /// Every mode crossed with both disk answers, not one of each: this is the
    /// check that the *values* survive, so testing only `.system` would pass
    /// even if every payload arrived as the same mode, and testing only
    /// `keepsDisksAwake: true` would pass against a decoder that hard-coded it.
    ///
    /// This is also Plan 6 Task 6's proof that the disk axis needs **no protocol
    /// change**: `HelperProtocol.startSession(_ sessionJSON: Data, …)` takes a
    /// blob, so a new `Session` field rides along — a claim about the transport
    /// that the in-process encode/decode tests cannot make, because they never
    /// touch NSXPC.
    func testEveryPowerRequestSurvivesARealXPCRoundTrip() throws {
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

        let requests = WakeMode.allCases.flatMap { mode in
            [false, true].map { PowerRequest(wakeMode: mode, keepsDisksAwake: $0) }
        }
        for request in requests {
            let described = EchoingHelper.echo(request)
            let replied = expectation(description: "reply for \(described)")
            // The error handler and the reply block arrive on different
            // queues and either may be the one that runs; the expectation
            // tolerates both rather than trapping on over-fulfilment.
            replied.assertForOverFulfill = false
            var echoed: String?
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                XCTFail("XPC error for \(described): \(error.localizedDescription)")
                replied.fulfill()
            } as? HelperProtocol
            let session = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "cli-501"),
                                  ownerUID: 501, persistence: .detached, origin: .manual,
                                  startedAt: Date(), triggerID: nil, wakeMode: request.wakeMode,
                                  keepsDisksAwake: request.keepsDisksAwake)
            let payload = try JSONEncoder().encode(session)
            proxy?.startSession(payload) { decoded, _ in
                echoed = decoded
                replied.fulfill()
            }
            wait(for: [replied], timeout: 10)
            XCTAssertEqual(echoed, described,
                           "\(described) did not survive the XPC round trip")
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
