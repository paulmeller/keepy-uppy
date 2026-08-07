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

    private func rule(_ condition: TriggerCondition, kind: SessionKind = .indefinite, enabled: Bool = true) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, sessionKind: kind, enabled: enabled)
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
        let already = Session(id: UUID(), kind: r.sessionKind, owner: ClientID(rawValue: "agent"),
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

    func testStoreSaveThenLoadRoundTrips() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"),
                     kind: .duration(until: Date().addingTimeInterval(3600)), enabled: false)
        TriggerStore.save([r])

        let loaded = TriggerStore.load()
        XCTAssertEqual(loaded, [r])
    }
}
