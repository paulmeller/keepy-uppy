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

    private func config(sensitivity: ThermalSensitivity) -> SafetyConfig {
        var config = SafetyConfig.default
        config.thermalSensitivity = sensitivity
        return config
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

    /// Review fix: the only existing max-duration test used `lidClosed: true`,
    /// which already forces an immediate stop via the lid path — so it could
    /// not tell a working `|| reason == .maxDuration` skip apart from a
    /// deleted one. This pins the backstop with the lid OPEN, where the lid
    /// path does not apply and only the max-duration skip does.
    func testMaxDurationBackstopStopsImmediatelyEvenWithLidOpen() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(lidClosed: false, oldestAge: 9 * 3600)),
                       .stopAll(reason: .maxDuration))
    }

    // MARK: - Thermal sensitivity (Change 1)

    /// Pins the entire sensitivity → limit table directly, so any edit to a
    /// row (including the `.balanced` default) fails loudly here rather than
    /// silently changing behaviour that happens not to be exercised elsewhere.
    func testThermalSensitivityTableIsPinned() {
        let table: [(ThermalSensitivity, ThermalLevel?, ThermalLevel?)] = [
            (.off, nil, nil),
            (.cautious, .fair, .serious),
            (.balanced, .serious, .critical),
            (.permissive, .critical, .critical),
        ]
        for (sensitivity, lidClosedLimit, lidOpenLimit) in table {
            XCTAssertEqual(sensitivity.limit(lidClosed: true), lidClosedLimit,
                           "\(sensitivity) lid closed")
            XCTAssertEqual(sensitivity.limit(lidClosed: false), lidOpenLimit,
                           "\(sensitivity) lid open")
        }
    }

    /// No test used `.fair` at all before this. `.cautious` is the only
    /// sensitivity whose lid-closed limit is `.fair`.
    func testCautiousSensitivityLidClosedTriggersAtFair() {
        var engine = SafetyEngine(config: config(sensitivity: .cautious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .fair, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    /// Engine-level pin of the `.balanced` lid-open row: `.serious` alone
    /// must not breach (that's the behaviour change from the old hardcoded
    /// `.serious` threshold), only `.critical` does.
    func testBalancedSensitivityLidOpenNeedsCriticalNotJustSerious() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, lidClosed: false)), .none)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, lidClosed: false)),
                       .warn(reason: .thermal, actAt: t0.addingTimeInterval(60)))
    }

    func testPermissiveSensitivityOnlyStopsAtCritical() {
        var engine = SafetyEngine(config: config(sensitivity: .permissive))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, lidClosed: true)), .none)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    /// Under the old hardcoded thresholds, lid-open `.serious` warned. Under
    /// the new `.balanced` default it no longer does (lid-open needs
    /// `.critical`), so this scenario now states the sensitivity it actually
    /// needs — `.cautious`, whose lid-open limit is `.serious` — rather than
    /// being silently weakened to keep passing.
    func testLidOpenGetsAGraceWarningFirst() {
        var engine = SafetyEngine(config: config(sensitivity: .cautious))
        let outcome = engine.evaluate(inputs(thermal: .serious, lidClosed: false))
        XCTAssertEqual(outcome, .warn(reason: .thermal, actAt: t0.addingTimeInterval(60)))
    }

    func testLidClosedSkipsTheWarningNobodyCouldSee() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    /// See `testLidOpenGetsAGraceWarningFirst`: `.cautious` is what makes a
    /// lid-open `.serious` reading a breach at all under the new default.
    func testWarningBecomesAStopWhenTheGracePeriodElapses() {
        var engine = SafetyEngine(config: config(sensitivity: .cautious))
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, now: t0.addingTimeInterval(61))),
                       .stopAll(reason: .thermal))
    }

    /// See `testLidOpenGetsAGraceWarningFirst`: `.cautious` is what makes a
    /// lid-open `.serious` reading a breach at all under the new default.
    func testRecoveryDuringGraceCancelsTheStop() {
        var engine = SafetyEngine(config: config(sensitivity: .cautious))
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(30))), .none)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(90))), .none)
    }

    // MARK: - Suppression / cooldown (Change 2)

    /// The regression test for the worst bug this product could ship: a
    /// safety stop that a still-true trigger condition immediately undoes.
    ///
    /// Timings are re-derived for recovery-anchored cooldown (Change 2): the
    /// clock starts at +150, the first nominal reading, not at +0, the
    /// episode start. Anchored to episode start, the 300s cooldown would
    /// already have elapsed by +350 (350 - 0 = 350 >= 300); anchored to
    /// recovery it has not (350 - 150 = 200 < 300), so +350 must still be
    /// suppressed. Release only arrives at +150 + 300 = +450.
    func testTriggersStaySuppressedUntilTheConditionClearsWithHysteresis() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .critical, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // Still hot: suppressed.
        _ = engine.evaluate(inputs(thermal: .serious, lidClosed: true, now: t0.addingTimeInterval(120)))
        XCTAssertTrue(engine.triggersSuppressed)

        // Cooled to nominal at +150: the recovery clock starts now.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(150)))
        XCTAssertTrue(engine.triggersSuppressed)

        // +350: past the old episode-start-anchored cooldown (+300), but
        // short of the recovery-anchored one (+450). Must still be suppressed.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(350)))
        XCTAssertTrue(engine.triggersSuppressed)

        // +460: past +450, the recovery-anchored release point. Released.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(460)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    /// Timings re-derived for recovery-anchored cooldown. 11% is still inside
    /// the lid-closed breach threshold (cutoff + 5 = 15) — a genuine ongoing
    /// breach, not merely "inside the hysteresis band" — so it stays
    /// suppressed for that reason alone. Recovery only begins at the 20%
    /// reading (+410), so the cooldown must elapse from there, not from
    /// episode start.
    func testBatterySuppressionNeedsHysteresisNotJustCrossingBack() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(battery: 9, onBattery: true, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // 11% is above the 10% cutoff but still <= the lid-closed effective
        // threshold of 15 — a real ongoing breach.
        _ = engine.evaluate(inputs(battery: 11, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(400)))
        XCTAssertTrue(engine.triggersSuppressed)

        // 20% clears the breach and the hysteresis band: recovery starts now.
        _ = engine.evaluate(inputs(battery: 20, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(410)))
        XCTAssertTrue(engine.triggersSuppressed)
        _ = engine.evaluate(inputs(battery: 20, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(410 + 300)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    func testDisabledGuardsDoNothing() {
        var config = SafetyConfig.default
        config.thermalSensitivity = .off
        config.batteryCutoff = nil
        config.maxSessionDuration = nil
        var engine = SafetyEngine(config: config)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, battery: 1,
                                              onBattery: true, oldestAge: 100 * 3600)), .none)
    }

    // MARK: - Review fixes (Change 3)

    /// With defaults (cutoff 10, batteryHysteresis 5) the lid-closed breach
    /// threshold (cutoff + 5 = 15) numerically coincides with the raw
    /// recovery threshold (cutoff + hysteresis = 15). Opening the lid removes
    /// the lid-closed offset from the breach check (open-lid threshold is
    /// just cutoff = 10) so at 15% there is no breach and recovery is judged
    /// on its own merits: 15% must NOT count as recovered, only strictly
    /// clearing 15 (16%+) does — otherwise the engine would consider itself
    /// recovered while a lid-closed reading at the same percentage would
    /// still be breaching.
    func testBatteryRecoveryRequiresStrictlyClearingTheBreachThreshold() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(battery: 9, onBattery: true, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // Lid opens; battery sits exactly at the coincidence point.
        _ = engine.evaluate(inputs(battery: 15, onBattery: true, lidClosed: false, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(engine.triggersSuppressed)
        _ = engine.evaluate(inputs(battery: 15, onBattery: true, lidClosed: false, now: t0.addingTimeInterval(310)))
        XCTAssertTrue(engine.triggersSuppressed) // still exactly at the boundary: never recovered

        // 16% strictly clears it: recovery starts here, cooldown from there.
        _ = engine.evaluate(inputs(battery: 16, onBattery: true, lidClosed: false, now: t0.addingTimeInterval(320)))
        XCTAssertTrue(engine.triggersSuppressed)
        _ = engine.evaluate(inputs(battery: 16, onBattery: true, lidClosed: false, now: t0.addingTimeInterval(320 + 300)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    /// If the user plugs in while suppressed for `.lowBattery`, the danger is
    /// gone even if the percentage hasn't moved — recovery must not wait for
    /// it to climb.
    func testPluggingIntoACRecoversFromLowBatterySuppressionRegardlessOfPercentage() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(battery: 5, onBattery: true, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // Plugged into AC now; percentage still low, but the danger is gone.
        _ = engine.evaluate(inputs(battery: 5, onBattery: false, lidClosed: true, now: t0.addingTimeInterval(100)))
        XCTAssertTrue(engine.triggersSuppressed) // recovery just started; cooldown hasn't elapsed

        _ = engine.evaluate(inputs(battery: 5, onBattery: false, lidClosed: true, now: t0.addingTimeInterval(100 + 300)))
        XCTAssertFalse(engine.triggersSuppressed)
    }
}
