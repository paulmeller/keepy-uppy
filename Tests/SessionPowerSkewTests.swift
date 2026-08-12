import XCTest
@testable import KeepyUppy

final class SessionPowerSkewTests: XCTestCase {
    private func request(_ mode: WakeMode, _ disks: Bool) -> PowerRequest {
        PowerRequest(wakeMode: mode, keepsDisksAwake: disks)
    }

    func testARequestThatSurvivedIntactReportsNothing() {
        for mode in WakeMode.allCases {
            for disks in [false, true] {
                let both = request(mode, disks)
                XCTAssertEqual(SessionPowerSkew.unmetAxes(requested: both, admitted: both), [])
                XCTAssertNil(SessionPowerSkew.note(requested: both, admitted: both),
                             "\(mode)/disks=\(disks) must say nothing at all")
            }
        }
    }

    /// Every axis has to be individually detectable, or a check that "passes"
    /// is only telling you about the axes it happens to look at.
    func testEachAxisIsDetectedOnItsOwn() {
        XCTAssertEqual(
            SessionPowerSkew.unmetAxes(requested: request(.systemAndDisplay, false),
                                       admitted: request(.clamshell, false)),
            [.wakeMode])
        XCTAssertEqual(
            SessionPowerSkew.unmetAxes(requested: request(.clamshell, true),
                                       admitted: request(.clamshell, false)),
            [.keepsDisksAwake])
    }

    /// The completeness check the `CaseIterable` conformance exists for: a case
    /// whose `differs` was never wired up would sit in `allCases` reporting
    /// "fine" forever.
    func testNoAxisIsStuckReportingAgreement() {
        for axis in SessionPowerSkew.Axis.allCases {
            let differing: (PowerRequest, PowerRequest) = {
                switch axis {
                case .wakeMode: return (request(.system, true), request(.clamshell, true))
                case .keepsDisksAwake: return (request(.system, true), request(.system, false))
                }
            }()
            XCTAssertTrue(axis.differs(differing.0, differing.1),
                          "\(axis) never reports a difference, so nothing it guards is checked")
            XCTAssertEqual(SessionPowerSkew.unmetAxes(requested: differing.0, admitted: differing.1),
                           [axis])
        }
    }

    /// The direction matters: `wakeMode` is lost *upwards* by an old daemon
    /// (absent decodes as `.clamshell`, the strongest) while `keepsDisksAwake`
    /// is lost *downwards*. A check written only for weakening would see one of
    /// them and miss the other.
    func testAnAxisLostUpwardsIsDetectedToo() {
        let unmet = SessionPowerSkew.unmetAxes(requested: request(.system, false),
                                               admitted: request(.clamshell, false))
        XCTAssertEqual(unmet, [.wakeMode],
                       "an old daemon over-applying the lid axis is still a dropped request")
    }

    func testTheNoteNamesOnlyTheAxesThatWereActuallyLost() throws {
        let diskOnly = try XCTUnwrap(SessionPowerSkew.note(requested: request(.clamshell, true),
                                                          admitted: request(.clamshell, false)))
        XCTAssertTrue(diskOnly.contains("keeping attached disks awake"), diskOnly)
        XCTAssertFalse(diskOnly.contains("how it keeps this Mac awake"), diskOnly)

        let modeOnly = try XCTUnwrap(SessionPowerSkew.note(requested: request(.systemAndDisplay, false),
                                                          admitted: request(.clamshell, false)))
        XCTAssertTrue(modeOnly.contains("how it keeps this Mac awake"), modeOnly)
        XCTAssertFalse(modeOnly.contains("keeping attached disks awake"), modeOnly)
    }

    func testTheNoteForBothAxesJoinsThemAndStillLeadsWithTheSessionRunning() throws {
        let note = try XCTUnwrap(SessionPowerSkew.note(requested: request(.systemAndDisplay, true),
                                                       admitted: request(.clamshell, false)))
        XCTAssertTrue(note.contains("how it keeps this Mac awake and keeping attached disks awake"), note)
        XCTAssertTrue(note.hasPrefix("This session is running,"),
                      "the session did start; opening with the fault reads as a failure to start: \(note)")
        XCTAssertTrue(note.contains("restarting this Mac"),
                      "a note with no remedy is an alarm: \(note)")
    }
}

/// The read-back, over a **real XPC round trip**, against a stub daemon that
/// drops a key exactly the way an older build does.
///
/// The in-process tests above check the predicate. This checks the thing the
/// predicate is useless without: that a request an old daemon silently drops
/// really does come back visibly changed through `startSession` +
/// `listSessions`, using the same `NSXPCInterface(with: HelperProtocol.self)`
/// both ends of the product use.
///
/// An anonymous listener, never the daemon's Mach service: no privileged
/// service, no code-signing requirement, nothing installed, and no live daemon
/// touched.
final class SessionPowerSkewOverXPCTests: XCTestCase {
    /// A daemon of an older vintage, simulated at the only place the vintage is
    /// observable: the keys its `Session` has.
    ///
    /// Stripping keys from the JSON before decoding is exactly what an older
    /// build's decoder does to a newer client's payload — it has no property
    /// for them, so `JSONDecoder` ignores them and `init(from:)` supplies the
    /// absent-key default. Stripping them again on the way out reproduces the
    /// other half: an old daemon's `encode(to:)` emits no such key either, so
    /// the *client's* decoder is the one that defaults, which is the path the
    /// read-back actually depends on.
    private final class OldVintageDaemon: NSObject, HelperProtocol {
        /// `Session` coding keys this vintage does not have.
        var missingKeys: Set<String> = []
        private var admitted: [Session] = []

        private func stripping(_ data: Data) -> Data? {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            for key in missingKeys { object.removeValue(forKey: key) }
            return try? JSONSerialization.data(withJSONObject: object)
        }

        func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) {
            guard let reduced = stripping(sessionJSON),
                  let request = try? JSONDecoder().decode(Session.self, from: reduced) else {
                return reply(nil, "invalid session payload")
            }
            // The same server-side overwrite the real daemon performs, so the
            // reply id is one the client can look the session back up by.
            let session = request.authorized(id: UUID(), owner: ClientID(rawValue: "app"),
                                             ownerUID: 501, startedAt: Date())
            admitted.append(session)
            reply(session.id.uuidString, nil)
        }

        func listSessions(reply: @escaping (Data?, String?) -> Void) {
            guard let encoded = try? JSONEncoder().encode(admitted),
                  let array = (try? JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]] else {
                return reply(nil, "encode failed")
            }
            let reduced = array.map { element -> [String: Any] in
                var copy = element
                for key in missingKeys { copy.removeValue(forKey: key) }
                return copy
            }
            reply(try? JSONSerialization.data(withJSONObject: reduced), nil)
        }

        func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void) { reply(0, "unused") }
        func prepareForRemoval(reply: @escaping (Int, Bool) -> Void) { reply(0, true) }
        func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func registerAsAgent(reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func currentState(reply: @escaping (Bool) -> Void) { reply(false) }
        func version(reply: @escaping (String) -> Void) { reply("0.1.0") }
        /// A daemon of this vintage has no such verb at all — but conformance
        /// is complete or nothing compiles, so it replies the way an encoding
        /// failure would. Nothing in this file sends it; the bare `"0.1.0"`
        /// above is what a client of this vintage is gated on.
        func recentSafetyStops(reply: @escaping (Data?, String?) -> Void) { reply(nil, "unused") }
    }

    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        let exported = OldVintageDaemon()
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
            new.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            new.exportedObject = exported
            new.resume()
            return true
        }
    }

    /// Returns the axes the round trip lost, for a daemon missing `missingKeys`.
    private func unmetAxesAfterARoundTrip(
        requesting power: PowerRequest, againstADaemonMissing missingKeys: Set<String>
    ) throws -> [SessionPowerSkew.Axis] {
        let listener = NSXPCListener.anonymous()
        // `NSXPCListener.delegate` is weak; an inline delegate would be
        // deallocated before the first connection arrives.
        let delegate = ListenerDelegate()
        delegate.exported.missingKeys = missingKeys
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        // Built the same way the app builds it, so the bytes on the wire are
        // the ones production sends.
        let request = DaemonConnection.requestedSession(
            kind: .indefinite, power: power, persistence: .clientBound, origin: .manual)
        let payload = try JSONEncoder().encode(request)

        let started = expectation(description: "startSession reply")
        started.assertForOverFulfill = false
        var admittedID: String?
        let startProxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("startSession XPC error: \(error.localizedDescription)")
            started.fulfill()
        } as? HelperProtocol
        startProxy?.startSession(payload) { id, _ in
            admittedID = id
            started.fulfill()
        }
        wait(for: [started], timeout: 10)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(admittedID)))

        let listed = expectation(description: "listSessions reply")
        listed.assertForOverFulfill = false
        var sessions: [Session] = []
        let listProxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("listSessions XPC error: \(error.localizedDescription)")
            listed.fulfill()
        } as? HelperProtocol
        listProxy?.listSessions { data, _ in
            if let data, let decoded = try? JSONDecoder().decode([Session].self, from: data) {
                sessions = decoded
            }
            listed.fulfill()
        }
        wait(for: [listed], timeout: 10)

        let admitted = try XCTUnwrap(sessions.first(where: { $0.id == id }),
                                     "the admitted session did not come back at all")
        return SessionPowerSkew.unmetAxes(requested: power, admitted: admitted.power)
    }

    /// The control. Against a daemon of this vintage the strongest request
    /// there is survives untouched, so a note here would be a false alarm on
    /// every healthy install.
    func testAMatchingDaemonLosesNothing() throws {
        let unmet = try unmetAxesAfterARoundTrip(
            requesting: PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: true),
            againstADaemonMissing: [])
        XCTAssertEqual(unmet, [])
    }

    func testADaemonWithoutTheDiskKeyIsCaught() throws {
        let unmet = try unmetAxesAfterARoundTrip(
            requesting: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: true),
            againstADaemonMissing: ["keepsDisksAwake"])
        XCTAssertEqual(unmet, [.keepsDisksAwake])
    }

    func testADaemonWithoutTheWakeModeKeyIsCaught() throws {
        let unmet = try unmetAxesAfterARoundTrip(
            requesting: PowerRequest(wakeMode: .system, keepsDisksAwake: false),
            againstADaemonMissing: ["wakeMode"])
        XCTAssertEqual(unmet, [.wakeMode])
    }

    /// The vintage actually running on the machine this was written on: a
    /// daemon built before either axis existed.
    func testADaemonPredatingBothAxesLosesBoth() throws {
        let unmet = try unmetAxesAfterARoundTrip(
            requesting: PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: true),
            againstADaemonMissing: ["wakeMode", "keepsDisksAwake"])
        XCTAssertEqual(unmet, [.wakeMode, .keepsDisksAwake])
    }
}
