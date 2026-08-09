import XCTest
@testable import KeepyUppy

final class SessionCompletionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Same reasoning as TriggerRuleTests.setUp(): naming the suite
        // directly here used to clear the shipping app's preference domain,
        // because this test host *is* the shipping app.
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(id: UUID = UUID(), kind: SessionKind = .indefinite,
                         ownerUID: UInt32 = 501) -> Session {
        Session(id: id, kind: kind, owner: ClientID(rawValue: "x"), ownerUID: ownerUID,
               persistence: .detached, origin: .manual, startedAt: t0)
    }

    // MARK: - sessionsEndedSince

    func testNoChangeReportsNothingEnded() {
        let a = session()
        XCTAssertTrue(sessionsEndedSince(previous: [a], current: [a]).isEmpty)
    }

    func testDisappearedSessionIsReportedEnded() {
        let a = session()
        let b = session()
        let ended = sessionsEndedSince(previous: [a, b], current: [b])
        XCTAssertEqual(ended.map(\.id), [a.id])
    }

    func testMultipleDisappearedSessionsAreAllReported() {
        let a = session()
        let b = session()
        let ended = sessionsEndedSince(previous: [a, b], current: [])
        XCTAssertEqual(Set(ended.map(\.id)), Set([a.id, b.id]))
    }

    func testStillPresentSessionIsNeverReported() {
        let a = session()
        XCTAssertTrue(sessionsEndedSince(previous: [a], current: [a, session()]).isEmpty)
    }

    func testNewlyAppearedSessionIsNeverReportedAsEnded() {
        let ended = sessionsEndedSince(previous: [], current: [session()])
        XCTAssertTrue(ended.isEmpty)
    }

    // MARK: - SessionCompletionTracker: own-uid scoping
    //
    // `HelperService.listSessions` returns the whole table unfiltered by uid
    // on purpose (the menu bar has to be able to say why the Mac is awake,
    // whoever's session is holding it). There is one agent per logged-in
    // user, each reading its own UserDefaults, so without a filter user A's
    // agent ran A's script and POSTed to A's webhook when B's session ended
    // — carrying B's `kind`, i.e. B's app bundle ID or process name.

    private let me: UInt32 = 501
    private let otherUser: UInt32 = 502

    func testAnotherUsersEndingSessionNeverFires() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let theirs = session(ownerUID: otherUser)
        _ = tracker.recordAndReportEnded(current: [theirs])
        XCTAssertTrue(tracker.recordAndReportEnded(current: []).isEmpty)
    }

    func testOwnEndingSessionFires() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let mine = session(ownerUID: me)
        _ = tracker.recordAndReportEnded(current: [mine])
        XCTAssertEqual(tracker.recordAndReportEnded(current: []).map(\.id), [mine.id])
    }

    func testOnlyOwnSessionsAreReportedWhenBothUsersEndTogether() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let mine = session(ownerUID: me)
        let theirs = session(ownerUID: otherUser)
        _ = tracker.recordAndReportEnded(current: [mine, theirs])
        let ended = tracker.recordAndReportEnded(current: [])
        XCTAssertEqual(ended.map(\.id), [mine.id])
    }

    /// The leak this closes is not only "runs a script": the `kind` of
    /// another user's session names the app or process they were running.
    func testAnotherUsersSessionKindNeverReachesTheEvent() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let theirs = session(kind: .whileAppRunning(bundleID: "com.company.InternalSecretApp"),
                             ownerUID: otherUser)
        _ = tracker.recordAndReportEnded(current: [theirs])
        let kinds = tracker.recordAndReportEnded(current: []).map(\.kind.wireDescription)
        XCTAssertFalse(kinds.contains { $0.contains("InternalSecretApp") })
    }

    // MARK: - SessionCompletionTracker: snapshot ordering
    //
    // The re-entrancy defect was a stale write-back: a tick that outlived its
    // own 5s period wrote its old snapshot over a newer one, and the next
    // tick re-diffed an already-reported session as newly ended, running the
    // user's script twice for one session. `EvidenceLoopRunner` now refuses
    // to overlap ticks at all; these pin the half of the fix that is
    // expressible against pure logic — that a session is reported at most
    // once, because recording and diffing cannot be prised apart.

    func testFirstSnapshotReportsNothing() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        XCTAssertFalse(tracker.hasSnapshot)
        XCTAssertTrue(tracker.recordAndReportEnded(current: [session()]).isEmpty)
        XCTAssertTrue(tracker.hasSnapshot)
    }

    func testAnEndedSessionIsReportedOnceAndNotAgain() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let mine = session(ownerUID: me)
        _ = tracker.recordAndReportEnded(current: [mine])
        XCTAssertEqual(tracker.recordAndReportEnded(current: []).map(\.id), [mine.id])
        XCTAssertTrue(tracker.recordAndReportEnded(current: []).isEmpty)
    }

    /// Recording is not optional or deferrable: even a snapshot that reports
    /// nothing becomes the new baseline, so there is no way to leave a stale
    /// one in place and re-diff it later.
    func testEverySnapshotBecomesTheNewBaseline() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let a = session(ownerUID: me)
        let b = session(ownerUID: me)
        _ = tracker.recordAndReportEnded(current: [a])
        XCTAssertEqual(tracker.recordAndReportEnded(current: [b]).map(\.id), [a.id])
        XCTAssertTrue(tracker.recordAndReportEnded(current: [b]).isEmpty)
    }

    // MARK: - SessionCompletionTracker: forgetting on disconnect

    func testForgettingTheSnapshotSuppressesTheNextDiff() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        _ = tracker.recordAndReportEnded(current: [session(ownerUID: me), session(ownerUID: me)])
        tracker.forgetSnapshot()
        XCTAssertFalse(tracker.hasSnapshot)
        // A daemon restart presents an empty table. Without forgetting, this
        // is N script spawns and N webhook POSTs in a single tick.
        XCTAssertTrue(tracker.recordAndReportEnded(current: []).isEmpty)
    }

    func testForgettingThenRePrimingResumesNormalReporting() {
        var tracker = SessionCompletionTracker(ownerUID: me)
        let stale = session(ownerUID: me)
        _ = tracker.recordAndReportEnded(current: [stale])
        tracker.forgetSnapshot()

        // Reconnected: a fresh baseline, then a genuine end after it.
        let fresh = session(ownerUID: me)
        XCTAssertTrue(tracker.recordAndReportEnded(current: [fresh]).isEmpty)
        XCTAssertEqual(tracker.recordAndReportEnded(current: []).map(\.id), [fresh.id])
    }

    // MARK: - SessionKind.wireDescription
    //
    // These pin the exact bytes that leave the machine, in the webhook JSON
    // and in KEEPY_UPPY_KIND. They exist to fail loudly if a case or an
    // associated-value label is ever renamed: the previous
    // `String(describing:)` would have followed such a rename silently, out
    // through the network, into whatever the user built on top of it.

    func testWireDescriptionsAreExactlyThese() {
        XCTAssertEqual(SessionKind.indefinite.wireDescription, "indefinite")
        XCTAssertEqual(SessionKind.duration(until: t0).wireDescription, "duration")
        XCTAssertEqual(SessionKind.untilTime(t0).wireDescription, "until-time")
        XCTAssertEqual(SessionKind.lease(expires: t0).wireDescription, "lease")
        XCTAssertEqual(SessionKind.whileAppRunning(bundleID: "com.apple.dt.Xcode").wireDescription,
                       "while-app-running:com.apple.dt.Xcode")
        XCTAssertEqual(SessionKind.whileExternalDisplay.wireDescription, "while-external-display")
        XCTAssertEqual(SessionKind.whileOnACPower.wireDescription, "while-on-ac-power")
        XCTAssertEqual(SessionKind.whileCPUBusy(threshold: 0.25).wireDescription, "while-cpu-busy")
        XCTAssertEqual(SessionKind.whileProcessRunning(processName: "claude").wireDescription,
                       "while-process-running:claude")
    }

    /// Every kind must have a name, and no two may share one — otherwise a
    /// consumer cannot tell them apart. Written over an exhaustive list so
    /// that adding a case without a name fails here.
    func testEveryKindHasADistinctNonEmptyWireDescription() {
        let all: [SessionKind] = [
            .indefinite, .duration(until: t0), .untilTime(t0), .lease(expires: t0),
            .whileAppRunning(bundleID: "a"), .whileExternalDisplay, .whileOnACPower,
            .whileCPUBusy(threshold: 0.5), .whileProcessRunning(processName: "b"),
        ]
        let names = all.map(\.wireDescription)
        XCTAssertEqual(Set(names).count, all.count)
        XCTAssertFalse(names.contains { $0.isEmpty })
    }

    /// The whole point: no Swift debug syntax on the wire. The old output was
    /// `whileAppRunning(bundleID: "com.company.InternalSecretApp")`.
    func testWireDescriptionCarriesNoSwiftDebugSyntax() {
        let kinds: [SessionKind] = [
            .whileAppRunning(bundleID: "com.example.App"),
            .whileProcessRunning(processName: "claude"),
            .whileCPUBusy(threshold: 0.5),
            .duration(until: t0),
        ]
        for kind in kinds {
            let wire = kind.wireDescription
            XCTAssertFalse(wire.contains("("), "\(wire) leaks Swift enum syntax")
            XCTAssertFalse(wire.contains("\""), "\(wire) leaks Swift quoting")
            XCTAssertNotEqual(wire, String(describing: kind))
        }
    }

    /// A value, when present, is everything after the first colon — so a
    /// consumer splitting on the first separator is always correct.
    func testWireDescriptionValueIsEverythingAfterTheFirstColon() {
        let wire = SessionKind.whileProcessRunning(processName: "weird:name").wireDescription
        XCTAssertEqual(wire, "while-process-running:weird:name")
        let name = wire.split(separator: ":", maxSplits: 1).last.map(String.init)
        XCTAssertEqual(name, "weird:name")
    }

    // MARK: - SessionCompletionStore

    func testDefaultConfigHasNothingConfigured() {
        let config = SessionCompletionStore.load()
        XCTAssertNil(config.scriptPath)
        XCTAssertNil(config.webhookURL)
    }

    func testStoreSaveThenLoadRoundTrips() {
        let config = SessionCompletionConfig(scriptPath: "/usr/local/bin/notify.sh",
                                             webhookURL: "https://example.com/hook")
        SessionCompletionStore.save(config)
        XCTAssertEqual(SessionCompletionStore.load(), config)
    }

    func testStoreRoundTripsWithOnlyOneFieldSet() {
        let config = SessionCompletionConfig(scriptPath: nil, webhookURL: "https://example.com/hook")
        SessionCompletionStore.save(config)
        XCTAssertEqual(SessionCompletionStore.load(), config)
    }
}
