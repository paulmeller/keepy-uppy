import XCTest
@testable import KeepyUppy

/// **What a client actually observes when it sends a verb the daemon does not
/// implement — measured, not assumed (Plan 8 Task 1, Step 2).**
///
/// Three later tasks each want to add a verb to `HelperProtocol`, and the daemon
/// on any given Mac may predate all of them: the daemon is a root LaunchDaemon
/// that keeps running across app updates, so "old daemon, new client" is the
/// normal state after an in-place upgrade, not an exotic one.
///
/// The measured answer, over a fully isolated `NSXPCListener.anonymous()` (never
/// the real Mach service), is that this is **not a recoverable per-call error**:
///
/// * the client's error handler fires with `NSCocoaErrorDomain`
///   `NSXPCConnectionInterrupted` (4097), "Couldn't communicate with a helper
///   application";
/// * the client's `interruptionHandler` runs; its `invalidationHandler` does
///   *not*;
/// * **the server side of the connection is invalidated** — the far end's
///   `invalidationHandler` runs. In the real daemon that handler is
///   `HelperListenerDelegate`'s `tearDownOnce`, which calls
///   `DaemonRuntime.clientDisconnected(id)` — and that ends the caller's
///   `clientBound` sessions once its refcount reaches zero (and, on the agent
///   service, `agentConnectionClosed(userID:)` ends that user's
///   agent-evaluated sessions);
/// * the client's *next* message silently establishes a **new** connection and
///   succeeds, so nothing about the failure is sticky on the client side.
///
/// Put together: one unimplemented-verb call costs the caller its live
/// sessions, and leaves the client looking healthy afterwards — so a client
/// that retries, or polls, does it again, and again.
///
/// This test is kept rather than deleted because that is a requirement three
/// tasks have to obey, and because if a future macOS makes this benign, this
/// test failing is precisely the signal that the requirement can be relaxed.
///
/// The "new" protocol: every method today's `HelperProtocol` declares, plus one
/// the far side will not implement. Spelled out in full rather than declared as
/// `: HelperProtocol`, so that a known-verb call cannot fail for the unrelated
/// reason that `NSXPCInterface` handled protocol inheritance differently than
/// expected — that would confound the measurement.
///
/// **At file scope, not nested in the test case, and that is not cosmetic.**
/// Swift permits a nested `@objc protocol` and `NSXPCInterface(with:)` accepts
/// one — but the first `remoteObjectProxyWithErrorHandler(…) as?` cast against
/// it segfaults inside `swift_dynamicCast` (measured: EXC_BAD_ACCESS, null
/// dereference, on the *known*-verb call, before the interesting message was
/// ever sent).
@objc protocol ProbeNewProtocol {
    func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void)
    func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)
    func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void)
    func prepareForRemoval(reply: @escaping (Int, Bool) -> Void)
    func listSessions(reply: @escaping (Data?, String?) -> Void)
    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void)
    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)
    func registerAsAgent(reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)

    /// The verb the "old" far side has never heard of.
    func safetyGuardReason(reply: @escaping (String?, String?) -> Void)
}

final class UnimplementedVerbProbeTests: XCTestCase {
    /// Conforms to today's `HelperProtocol` only — the "old daemon".
    private final class OldHelper: NSObject, HelperProtocol {
        func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void) { reply(nil, "unused") }
        func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void) { reply(0, "unused") }
        func prepareForRemoval(reply: @escaping (Int, Bool) -> Void) { reply(0, true) }
        func listSessions(reply: @escaping (Data?, String?) -> Void) { reply(nil, "unused") }
        func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func registerAsAgent(reply: @escaping (Bool, String?) -> Void) { reply(false, "unused") }
        func currentState(reply: @escaping (Bool) -> Void) { reply(true) }
        func version(reply: @escaping (String) -> Void) { reply("old-daemon") }
    }

    /// Stands in for `HelperListenerDelegate`, including the part that matters
    /// most: that delegate hangs `runtime.clientDisconnected(id)` off *both*
    /// teardown handlers of every accepted connection. So "did the server side
    /// tear down?" is the same question as "would a real daemon have ended the
    /// caller's `clientBound` sessions?", and this records the answer.
    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        let exported = OldHelper()
        let serverEvents = EventRecorder()
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
            let events = serverEvents
            events.record("accept")
            // The OLD interface, deliberately: this is what an old daemon's
            // listener publishes.
            new.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            new.exportedObject = exported
            new.invalidationHandler = { events.record("server-invalidation") }
            new.interruptionHandler = { events.record("server-interruption") }
            new.resume()
            return true
        }
    }

    func testAnUnimplementedVerbDestroysTheConnectionOnBothSides() {
        let listener = NSXPCListener.anonymous()
        // `NSXPCListener.delegate` is weak; an inline delegate would be gone
        // before the first connection arrives and every connection refused.
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        // The NEW interface, on the client only.
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeNewProtocol.self)

        // A recorder rather than inverted expectations: the `defer` below
        // invalidates the connection at the end of the test, which would fulfil
        // an expectation after its wait had already returned.
        let clientEvents = EventRecorder()
        connection.invalidationHandler = { clientEvents.record("invalidation") }
        connection.interruptionHandler = { clientEvents.record("interruption") }
        connection.resume()
        defer { connection.invalidate() }

        // A known verb first, so a later failure cannot be blamed on a
        // connection that never worked.
        XCTAssertEqual(sendVersion(over: connection), "old-daemon",
                       "the harness itself is broken if a known verb does not answer")

        let answered = expectation(description: "safetyGuardReason resolved")
        answered.assertForOverFulfill = false
        var observedError: NSError?
        var repliedNormally = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            observedError = error as NSError
            answered.fulfill()
        } as? ProbeNewProtocol
        XCTAssertNotNil(proxy, "the proxy itself was refused")
        proxy?.safetyGuardReason { _, _ in
            repliedNormally = true
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)

        XCTAssertFalse(repliedNormally, "an unimplemented verb must not appear to succeed")
        XCTAssertEqual(observedError?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(observedError?.code, CocoaError.Code.xpcConnectionInterrupted.rawValue,
                       "the failure is reported as the connection being INTERRUPTED (4097), "
                       + "not as a per-message error — which is the whole finding")

        // The client is fine: the next message just makes a new connection.
        // That is what turns one bad call into an unbounded loop when the
        // caller retries or polls.
        XCTAssertEqual(sendVersion(over: connection), "old-daemon",
                       "the client recovers silently, so nothing stops it doing this again")

        // Let any remaining teardown callbacks land.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(clientEvents.fired, ["interruption"],
                       "the client sees an interruption, not an invalidation — so a client that "
                       + "only watches invalidationHandler learns nothing")
        // `accept` twice: the first connection was destroyed and the recovery
        // call above established a second one.
        XCTAssertEqual(delegate.serverEvents.fired, ["accept", "server-invalidation", "accept"],
                       "the SERVER side is invalidated — in the real daemon that runs "
                       + "HelperListenerDelegate's tearDownOnce, ending the caller's clientBound sessions")
    }

    /// One known-verb round trip, or `nil` if the call failed.
    private func sendVersion(over connection: NSXPCConnection) -> String? {
        let replied = expectation(description: "version reply")
        replied.assertForOverFulfill = false
        var value: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("version() errored: \(error.localizedDescription)")
            replied.fulfill()
        } as? ProbeNewProtocol
        proxy?.version { value = $0; replied.fulfill() }
        wait(for: [replied], timeout: 10)
        return value
    }

    /// Thread-safe ordered record of connection lifecycle callbacks.
    fileprivate final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ name: String) {
            lock.lock(); seen.append(name); lock.unlock()
        }
        var fired: [String] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
    }
}
