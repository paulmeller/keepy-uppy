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
    fileprivate final class EchoingHelper: NSObject, HelperProtocol {
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

        /// Not a stub either, since Plan 8 Task 5. The table this authorises
        /// against, and the identity it authorises *as*, are installed by
        /// `AuthorizingListenerDelegate` from the connection XPC actually
        /// accepted — see that type for why this cannot be done from the
        /// payload.
        var authorizeStop: ((UUID) -> SessionIsolation.Authorization)?

        func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
            guard let authorizeStop else { return reply(false, "unused") }
            guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
            // The decision comes back as the error string so the test reads the
            // daemon's own three-case answer rather than a boolean that folds
            // `.notFound` and `.forbidden` together.
            switch authorizeStop(uuid) {
            case .authorized: reply(true, "authorized")
            case .notFound: reply(false, "notFound")
            case .forbidden: reply(false, "forbidden")
            }
        }
        /// Not a stub either, since Plan 8 Task 6: whatever the test hands it,
        /// encoded the way `HelperService.recentSafetyStops` encodes it.
        var safetyStopsReply: [SafetyStopRecord] = []

        func recentSafetyStops(reply: @escaping (Data?, String?) -> Void) {
            guard let data = try? JSONEncoder().encode(safetyStopsReply) else {
                return reply(nil, "encoding failure")
            }
            reply(data, nil)
        }

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

    /// **Plan 8 Task 6's wire proof: a reason crosses XPC intact, for every
    /// reason there is.**
    ///
    /// `SafetyStopRecord` is the only thing in this project that carries a
    /// `SafetyReason` outside the daemon, and `SafetyReason` is an enum with a
    /// `String` raw value inside a `Codable` struct inside a JSON array inside
    /// an `NSData` reply — four layers, any of which could flatten a case into
    /// a neighbouring one without failing to decode.
    ///
    /// Written over `SafetyReason.allCases` (which is what that conformance was
    /// sanctioned for) rather than over three hand-written cases, so a fourth
    /// reason cannot escape this proof by nobody remembering to add it. Every
    /// field of every record is non-default and distinct — a distinct uid, a
    /// distinct instant, its own UUID — so a reason dropped, flattened, or
    /// reordered on the wire shows up as a **wrong value**, and never as an
    /// empty list that a decoder shrug would also produce.
    ///
    /// Compared as whole values (`[SafetyStopRecord] == [SafetyStopRecord]`),
    /// not field by field, for `SessionAuthorizationTests`' reason: a field-wise
    /// comparison silently stops covering a field the day one is added.
    func testEverySafetyStopReasonSurvivesARealXPCRoundTrip() {
        let sent = SafetyReason.allCases.enumerated().map { index, reason in
            SafetyStopRecord(sessionID: UUID(),
                             // Distinct, and none of them 0 or this test host's
                             // own uid: an implementation that lost the field
                             // and substituted either would still pass.
                             ownerUID: UInt32(9_000 + index),
                             reason: reason,
                             // Integral, so nothing here can fail on a float
                             // that survived the trip but not the comparison.
                             endedAt: Date(timeIntervalSinceReferenceDate: Double(800_000_000 + index)))
        }
        XCTAssertEqual(sent.count, SafetyReason.allCases.count)

        let listener = NSXPCListener.anonymous()
        // `NSXPCListener.delegate` is weak — the same trap as the two tests
        // above, and the same fix.
        let delegate = ListenerDelegate()
        delegate.exported.safetyStopsReply = sent
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "recentSafetyStops reply")
        replied.assertForOverFulfill = false
        var received: [SafetyStopRecord]?
        var decodeFailed = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC error: \(error.localizedDescription)")
            replied.fulfill()
        } as? HelperProtocol
        proxy?.recentSafetyStops { data, _ in
            guard let data,
                  let decoded = try? JSONDecoder().decode([SafetyStopRecord].self, from: data) else {
                decodeFailed = true
                return replied.fulfill()
            }
            received = decoded
            replied.fulfill()
        }
        wait(for: [replied], timeout: 10)

        XCTAssertFalse(decodeFailed, "the reply did not decode as [SafetyStopRecord] at all")
        XCTAssertEqual(received, sent,
                       "a safety stop record did not survive the XPC round trip intact")
    }
}

/// **Plan 8 Task 5's amendment, reached over a real XPC connection.**
///
/// `SessionIsolationTests` proves the *decision*: hand `authorize` a uid, a
/// role and a `ClientID` and it answers correctly. That is a test of a pure
/// function, and it can pass while the daemon computes the decision from the
/// wrong inputs — because the inputs are exactly the part it does not exercise.
/// A caller's uid and role are not in any payload and never can be: `origin` is
/// client-chosen and `stopSession` carries nothing but a session id string, so
/// **the only thing that establishes who is asking is the connection itself.**
///
/// So this drives the identity the way the daemon does
/// (`Helper/HelperListenerDelegate.swift`): a listener fixed to one
/// `ClientRole`, reading `NSXPCConnection.effectiveUserIdentifier` off the
/// accepted connection — which XPC fills in from the peer's audit credentials,
/// not from anything the client sent — and composing the two with
/// `ClientRole.clientID(forUserID:)`. The far side then answers with the
/// authorisation it computed, so a uid that failed to cross, a role taken from
/// the wrong end, or an identity assembled differently from the daemon's shows
/// up as a wrong decision rather than as a green unit test.
///
/// An anonymous listener rather than the daemon's Mach service, deliberately
/// and for the reasons `SessionOverXPCTransportTests` gives: no privileged
/// service, no code-signing requirement, nothing installed, and — the part that
/// matters here — no contact of any kind with the live root daemon serving this
/// Mac.
final class StopAuthorizationOverXPCTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The daemon's accept path, reduced to the two facts the amendment reads.
    ///
    /// `role` is a property of the *listener*, exactly as it is in the product:
    /// one `NSXPCListener` per Mach service, so a peer's role is established by
    /// which one accepted it and is never derived from the peer afterwards. The
    /// uid is read per connection.
    /// The exported object is `SessionOverXPCTransportTests.EchoingHelper`,
    /// reused rather than re-implemented: a second complete `HelperProtocol`
    /// conformance is nine more methods that can drift from the protocol under
    /// test.
    private final class AuthorizingListenerDelegate: NSObject, NSXPCListenerDelegate {
        let role: ClientRole
        let sessions: [Session]
        let exported = SessionOverXPCTransportTests.EchoingHelper()
        /// What the server saw, so the test can assert the uid genuinely
        /// crossed rather than assuming it did.
        private(set) var observedUID: UInt32?

        init(role: ClientRole, sessions: [Session]) {
            self.role = role
            self.sessions = sessions
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
            let uid = UInt32(new.effectiveUserIdentifier)
            observedUID = uid
            let clientID = role.clientID(forUserID: uid)
            let table = sessions
            let acceptedAs = role
            exported.authorizeStop = { id in
                SessionIsolation.authorize(sessionID: id, action: .stop,
                                           requestedBy: clientID, uid: uid, role: acceptedAs,
                                           among: table)
            }
            new.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            new.exportedObject = exported
            new.resume()
            return true
        }
    }

    private func session(owner: ClientID, uid: UInt32, origin: SessionOrigin) -> Session {
        Session(id: UUID(), kind: .indefinite, owner: owner, ownerUID: uid,
                persistence: .detached, origin: origin, startedAt: t0,
                triggerID: origin == .trigger ? UUID() : nil,
                wakeMode: .clamshell, keepsDisksAwake: false)
    }

    private func decision(for session: Session, askingAs role: ClientRole,
                          among sessions: [Session]) -> (reply: String?, uid: UInt32?) {
        let listener = NSXPCListener.anonymous()
        // `NSXPCListener.delegate` is weak — the same trap the transport tests
        // above document. A delegate created inline is deallocated before the
        // first connection arrives, and every connection is silently refused.
        let delegate = AuthorizingListenerDelegate(role: role, sessions: sessions)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "stopSession reply")
        replied.assertForOverFulfill = false
        var answer: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC error: \(error.localizedDescription)")
            replied.fulfill()
        } as? HelperProtocol
        proxy?.stopSession(session.id.uuidString) { _, detail in
            answer = detail
            replied.fulfill()
        }
        wait(for: [replied], timeout: 10)
        return (answer, delegate.observedUID)
    }

    /// The permitted case. The uid is not written down anywhere in this test:
    /// it is whatever the connection carried, and the session is built from the
    /// same value, so the assertion is that the two met.
    func testTheAppMayStopThisUsersTriggerSessionOverARealConnection() {
        let uid = UInt32(getuid())
        let automatic = session(owner: ClientRole.agent.clientID(forUserID: uid),
                                uid: uid, origin: .trigger)
        let outcome = decision(for: automatic, askingAs: .app, among: [automatic])
        XCTAssertEqual(outcome.uid, uid,
                       "the peer's uid must reach the server from its audit credentials, "
                       + "which is the whole reason this test exists")
        XCTAssertEqual(outcome.reply, "authorized")
    }

    /// Refused case one: the caller's role. Same bytes on the wire, same uid,
    /// same session — only the listener that accepted the connection differs,
    /// which is exactly the axis a payload can never carry.
    func testTheCLIIsRefusedTheSameStopOverTheSameWire() {
        let uid = UInt32(getuid())
        let automatic = session(owner: ClientRole.agent.clientID(forUserID: uid),
                                uid: uid, origin: .trigger)
        XCTAssertEqual(decision(for: automatic, askingAs: .cli, among: [automatic]).reply,
                       "forbidden")
    }

    /// Refused case two: the account boundary, over a real connection. The
    /// server derives the caller's uid from the peer, so a session belonging to
    /// a *different* uid cannot be reached however the request is phrased.
    func testAnotherAccountsTriggerSessionIsRefusedOverARealConnection() {
        let uid = UInt32(getuid())
        let theirs = session(owner: ClientRole.agent.clientID(forUserID: uid &+ 1),
                             uid: uid &+ 1, origin: .trigger)
        XCTAssertEqual(decision(for: theirs, askingAs: .app, among: [theirs]).reply,
                       "forbidden")
    }

    /// Refused case three, and the one that proves the *conjunction* survives
    /// the trip rather than just the uid: this user's own agent, but a session
    /// no rule started.
    func testAnAgentSessionWithManualOriginIsRefusedOverARealConnection() {
        let uid = UInt32(getuid())
        let manual = session(owner: ClientRole.agent.clientID(forUserID: uid),
                             uid: uid, origin: .manual)
        XCTAssertEqual(decision(for: manual, askingAs: .app, among: [manual]).reply,
                       "forbidden")
    }
}
