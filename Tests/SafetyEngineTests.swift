import XCTest
@testable import KeepyUppy

final class SafetyEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(thermal: ThermalLevel = .nominal,
                        battery: Int? = 80,
                        onBattery: Bool = false,
                        lidClosed: Bool = false,
                        oldestAge: TimeInterval? = 60,
                        now: Date? = nil) -> SafetyInputs {
        SafetyInputs(thermal: thermal, batteryPercentage: battery, onBattery: onBattery,
                     lidClosed: lidClosed, oldestSessionAge: oldestAge, now: now ?? t0)
    }

    func testNominalConditionsDoNothing() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs()), .none)
    }

    func testCriticalThermalStopsEverythingImmediately() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    func testLowBatteryOnBatteryPowerStops() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(battery: 5, onBattery: true, lidClosed: true)),
                       .stopAll(reason: .lowBattery))
    }

    func testLowBatteryOnACPowerDoesNotStop() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(battery: 5, onBattery: false)), .none)
    }

    func testMaxDurationBackstopStopsIndefiniteSessions() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(lidClosed: true, oldestAge: 9 * 3600)),
                       .stopAll(reason: .maxDuration))
    }

    func testLidOpenGetsAGraceWarningFirst() {
        var engine = SafetyEngine(config: .default)
        let outcome = engine.evaluate(inputs(thermal: .serious, lidClosed: false))
        XCTAssertEqual(outcome, .warn(reason: .thermal, actAt: t0.addingTimeInterval(60)))
    }

    func testLidClosedSkipsTheWarningNobodyCouldSee() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    func testWarningBecomesAStopWhenTheGracePeriodElapses() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, now: t0.addingTimeInterval(61))),
                       .stopAll(reason: .thermal))
    }

    func testRecoveryDuringGraceCancelsTheStop() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(30))), .none)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(90))), .none)
    }

    /// The regression test for the worst bug this product could ship: a
    /// safety stop that a still-true trigger condition immediately undoes.
    func testTriggersStaySuppressedUntilTheConditionClearsWithHysteresis() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .critical, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // Still hot: suppressed.
        _ = engine.evaluate(inputs(thermal: .serious, lidClosed: true, now: t0.addingTimeInterval(120)))
        XCTAssertTrue(engine.triggersSuppressed)

        // Cooled to nominal but inside the cooldown: still suppressed.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(150)))
        XCTAssertTrue(engine.triggersSuppressed)

        // Nominal and past the cooldown: released.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(400)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    func testBatterySuppressionNeedsHysteresisNotJustCrossingBack() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(battery: 9, onBattery: true, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)
        // 11% is above the 10% cutoff but inside the hysteresis band.
        _ = engine.evaluate(inputs(battery: 11, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(400)))
        XCTAssertTrue(engine.triggersSuppressed)
        _ = engine.evaluate(inputs(battery: 20, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(500)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    func testDisabledGuardsDoNothing() {
        var config = SafetyConfig.default
        config.thermalGuardEnabled = false
        config.batteryCutoff = nil
        config.maxSessionDuration = nil
        var engine = SafetyEngine(config: config)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, battery: 1,
                                              onBattery: true, oldestAge: 100 * 3600)), .none)
    }
}
