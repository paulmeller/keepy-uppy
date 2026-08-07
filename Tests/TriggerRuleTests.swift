import XCTest
@testable import KeepyUppy

final class TriggerRuleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `UserDefaults(suiteName:)` returns nil when `suiteName` equals the
        // *calling process's own* bundle identifier — which is exactly the
        // case here, since this test host is the "Keepy Uppy" app itself
        // (PRODUCT_BUNDLE_IDENTIFIER `au.com.workwireless.keepy-uppy`,
        // identical to the suite name string). `TriggerStore` works around
        // this by falling back to `.standard`, which for this exact
        // degenerate case resolves to the identical underlying preferences
        // file — so clearing `.standard`'s domain here really does reset
        // it (mirrors `SafetyConfigStoreTests.setUp()`, which needed the
        // same fix to avoid the prior run's saved rules leaking through).
        UserDefaults.standard.removePersistentDomain(forName: "au.com.workwireless.keepy-uppy")
    }

    struct FakeAppRunning: AppRunningObserving {
        let running: Set<String>
        func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    }
    struct FakeDisplay: DisplayObserving {
        let external: Bool
        func hasExternalDisplay() -> Bool { external }
    }

    private func rule(_ condition: TriggerCondition, kind: DefaultSessionKind = .indefinite, enabled: Bool = true) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, defaultKind: kind, enabled: enabled)
    }

    func testDisabledRuleNeverFires() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), enabled: false)
        let fired = triggersToFire([r], activeSessions: [],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }

    func testAppLaunchedFiresWhenRunning() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let fired = triggersToFire([r], activeSessions: [],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    func testExternalDisplayConnectedFires() {
        let r = rule(.externalDisplayConnected)
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: true), onACPower: false)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    func testACPowerConnectedFires() {
        let r = rule(.acPowerConnected)
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: false), onACPower: true)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    /// The most important test in this file: a trigger already represented
    /// by a live session must not fire again every tick.
    func testAlreadyActiveTriggerDoesNotFireAgain() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let already = Session(id: UUID(), kind: r.defaultKind.sessionKind(now: Date()),
                              owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id)
        let fired = triggersToFire([r], activeSessions: [already],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }

    func testConditionFalseDoesNotFire() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }

    /// Final whole-branch review, Finding 2. A rule created today and fired
    /// next week must keep the Mac awake for an hour *from when it fired*.
    /// Before the fix the rule stored an absolute `SessionKind` frozen at
    /// creation time, so the deadline here landed seven days in the past —
    /// the daemon's `removeExpired` sweep then deleted the session in the
    /// same call that admitted it, and the agent refired the rule forever.
    func testRuleFiredLongAfterCreationGetsADeadlineInTheFuture() {
        let creation = Date(timeIntervalSince1970: 1_000_000)
        let fire = creation.addingTimeInterval(7 * 24 * 3600)
        // Exactly what TriggersSettingsTab.addRule() does, at `creation`.
        let r = rule(.acPowerConnected, kind: .oneHour)
        // Exactly what EvidenceLoopRunner does when the rule fires, at `fire`.
        let session = Session(id: UUID(), kind: r.defaultKind.sessionKind(now: fire),
                              owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: fire, triggerID: r.id)
        XCTAssertGreaterThan(session.kind.deadline ?? .distantPast, fire,
                             "a rule fired at `fire` must produce a session that outlives `fire`")
        XCTAssertEqual(session.kind, .duration(until: fire.addingTimeInterval(3600)))
    }

    /// The structural half of the same guarantee: one stored rule, two
    /// materializations far apart, two deadlines that differ by exactly the
    /// gap between them. A rule holding a frozen `Date` could not do this —
    /// both materializations would return the identical value.
    func testTheSameRuleMaterializesADifferentDeadlineAtEachFireTime() {
        let r = rule(.externalDisplayConnected, kind: .oneHour)
        let first = Date(timeIntervalSince1970: 1_000_000)
        let gap: TimeInterval = 30 * 24 * 3600
        let second = first.addingTimeInterval(gap)

        guard case .duration(let firstDeadline) = r.defaultKind.sessionKind(now: first),
              case .duration(let secondDeadline) = r.defaultKind.sessionKind(now: second)
        else { return XCTFail("expected .duration from a .oneHour rule") }

        XCTAssertEqual(secondDeadline.timeIntervalSince(firstDeadline), gap, accuracy: 1,
                       "the deadline must track the fire time, not be frozen at construction")
        XCTAssertEqual(firstDeadline.timeIntervalSince(first), 3600, accuracy: 1)
        XCTAssertEqual(secondDeadline.timeIntervalSince(second), 3600, accuracy: 1)
    }

    func testStoreSaveThenLoadRoundTrips() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), kind: .oneHour, enabled: false)
        TriggerStore.save([r])

        let loaded = TriggerStore.load()
        XCTAssertEqual(loaded, [r])
    }

    /// The round-trip above is only meaningful if what got persisted was the
    /// relative intent. A rule that survives a save/load cycle and *then*
    /// fires must still produce a deadline relative to the firing, which is
    /// only possible if no absolute date was ever written to disk.
    func testAPersistedRuleStillMaterializesRelativeToFireTime() {
        TriggerStore.save([rule(.acPowerConnected, kind: .fourHours)])
        guard let loaded = TriggerStore.load().first else { return XCTFail("nothing round-tripped") }

        let fire = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(loaded.defaultKind.sessionKind(now: fire),
                       .duration(until: fire.addingTimeInterval(4 * 3600)))
    }
}
