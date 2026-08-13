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

    /// Ticks the engine the way the daemon's timer does — an opening reading
    /// that starts the clock, then one `elapsed` later — because the backstop
    /// measures time the engine has *observed* on battery, and a single
    /// evaluate has observed none of it.
    @discardableResult
    private func tick(_ engine: inout SafetyEngine, elapsed: TimeInterval,
                      onBattery: Bool, lidClosed: Bool = false,
                      oldestAge: TimeInterval = 60,
                      from: Date? = nil) -> SafetyOutcome {
        let begin = from ?? t0
        _ = engine.evaluate(inputs(onBattery: onBattery, lidClosed: lidClosed,
                                   oldestAge: oldestAge, now: begin))
        return engine.evaluate(inputs(onBattery: onBattery, lidClosed: lidClosed,
                                      oldestAge: oldestAge + elapsed,
                                      now: begin.addingTimeInterval(elapsed)))
    }

    func testMaxDurationBackstopStopsIndefiniteSessionsOnBattery() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(tick(&engine, elapsed: 9 * 3600, onBattery: true, lidClosed: true),
                       .stopAll(reason: .maxDuration))
    }

    /// Review fix: the only existing max-duration test used `lidClosed: true`,
    /// which already forces an immediate stop via the lid path — so it could
    /// not tell a working `|| reason == .maxDuration` skip apart from a
    /// deleted one. This pins the backstop with the lid OPEN, where the lid
    /// path does not apply and only the max-duration skip does.
    func testMaxDurationBackstopStopsImmediatelyEvenWithLidOpen() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(tick(&engine, elapsed: 9 * 3600, onBattery: true, lidClosed: false),
                       .stopAll(reason: .maxDuration))
    }

    // MARK: - The backstop counts battery time, not wall clock

    /// The headline of this change: a mains-powered Mac running an indefinite
    /// session is the case `keepy-uppy on` exists for, and the backstop used to
    /// end it at eight hours regardless. "Until you say otherwise" now means it
    /// while the charger is in.
    func testMaxDurationBackstopNeverFiresOnACPower() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(tick(&engine, elapsed: 100 * 3600, onBattery: false), .none)
    }

    /// The cliff this change exists to avoid. Measuring session age but gating
    /// the *firing* on battery would stop everything the instant the charger
    /// came out of a machine that had been plugged in all day, because
    /// `age >= maximum` was already true. The clock has to start when the power
    /// does.
    func testUnpluggingAfterALongACSessionDoesNotStopItInstantly() {
        var engine = SafetyEngine(config: .default)
        tick(&engine, elapsed: 20 * 3600, onBattery: false)
        let justUnplugged = engine.evaluate(inputs(onBattery: true, oldestAge: 20 * 3600,
                                                   now: t0.addingTimeInterval(20 * 3600)))
        XCTAssertEqual(justUnplugged, .none)
    }

    /// …and having survived the unplug, it still gets stopped once it has
    /// genuinely run its budget on battery.
    func testTheBackstopStillFiresOnceTheBudgetIsSpentOnBattery() {
        var engine = SafetyEngine(config: .default)
        tick(&engine, elapsed: 20 * 3600, onBattery: false)
        let outcome = tick(&engine, elapsed: 9 * 3600, onBattery: true,
                           oldestAge: 20 * 3600, from: t0.addingTimeInterval(20 * 3600))
        XCTAssertEqual(outcome, .stopAll(reason: .maxDuration))
    }

    /// Plugging in pauses the budget rather than refunding it. Otherwise a
    /// laptop that touches a charger once an hour never reaches the backstop at
    /// all, which is the guard quietly not existing.
    func testACTimePausesTheBudgetRatherThanResettingIt() {
        var engine = SafetyEngine(config: .default)
        // 5h on battery, then a long spell on mains, then 4h more on battery:
        // 9h of battery time in total, either side of the interruption.
        tick(&engine, elapsed: 5 * 3600, onBattery: true)
        tick(&engine, elapsed: 50 * 3600, onBattery: false,
             oldestAge: 5 * 3600, from: t0.addingTimeInterval(5 * 3600))
        let outcome = tick(&engine, elapsed: 4 * 3600, onBattery: true,
                           oldestAge: 55 * 3600, from: t0.addingTimeInterval(55 * 3600))
        XCTAssertEqual(outcome, .stopAll(reason: .maxDuration))
    }

    /// The budget belongs to the run of sessions being timed, not to the
    /// engine. Without this, the first session after a long one would inherit a
    /// spent budget and be stopped on its first tick.
    func testTheBudgetResetsOnceNoSessionsRemain() {
        var engine = SafetyEngine(config: .default)
        tick(&engine, elapsed: 7 * 3600, onBattery: true)
        // Everything ends: no oldest session for the engine to time.
        _ = engine.evaluate(inputs(onBattery: true, oldestAge: nil,
                                   now: t0.addingTimeInterval(7 * 3600)))
        let fresh = tick(&engine, elapsed: 2 * 3600, onBattery: true,
                         from: t0.addingTimeInterval(8 * 3600))
        XCTAssertEqual(fresh, .none)
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

// MARK: - Plan 8 Task 6: the record, and the log behind it

/// `SafetyStopRecord` is the only thing in this project that carries a
/// `SafetyReason` outside the daemon, so its encoding is a wire format.
final class SafetyStopRecordTests: XCTestCase {
    /// Whole-struct, every field non-default, compared as
    /// `SafetyStopRecord == SafetyStopRecord` rather than field by field —
    /// which is the point: a field-wise round trip stops covering a field the
    /// moment somebody adds one, and this type exists precisely because a
    /// silently-dropped field is this project's signature defect.
    func testTheWholeRecordRoundTripsThroughItsEncoding() throws {
        let original = SafetyStopRecord(
            sessionID: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
            ownerUID: 9_501,
            reason: .lowBattery,
            endedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let decoded = try JSONDecoder().decode(
            SafetyStopRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// Every reason, not one — a raw-value enum can lose a case to a decoder
    /// that only ever sees the case the test author picked.
    func testEveryReasonRoundTripsAsItself() throws {
        for reason in SafetyReason.allCases {
            let original = SafetyStopRecord(sessionID: UUID(), ownerUID: 501, reason: reason,
                                            endedAt: Date(timeIntervalSinceReferenceDate: 1))
            let decoded = try JSONDecoder().decode(
                SafetyStopRecord.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.reason, reason, "\(reason) did not survive its own encoding")
        }
    }

    /// The conformance Plan 7 declined and Task 6 sanctioned. Asserted rather
    /// than assumed, because everything written over `allCases` — the wire
    /// proof, and Task 7's bijection — is only as complete as this list.
    func testEveryReasonTheEngineCanProduceIsInAllCases() {
        XCTAssertEqual(Set(SafetyReason.allCases), [.thermal, .lowBattery, .maxDuration])
    }
}

/// The daemon's bounded memory. Pure and in `Shared/` for
/// `SessionTable.desiredPowerPlan`'s reason: `Helper/` is not reachable from
/// this target, so the part that can be pure is.
final class SafetyStopLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(_ id: UUID = UUID(), uid: UInt32 = 501,
                        reason: SafetyReason = .thermal, at: Date) -> SafetyStopRecord {
        SafetyStopRecord(sessionID: id, ownerUID: uid, reason: reason, endedAt: at)
    }

    func testAnEmptyLogReportsNothing() {
        XCTAssertEqual(SafetyStopLog().records(asOf: t0), [])
    }

    /// Oldest first, and the order records were written in — which is also the
    /// eviction order, so the two cannot disagree.
    func testRecordsComeBackOldestFirstInTheOrderTheyWereWritten() {
        var log = SafetyStopLog()
        let first = record(at: t0)
        let second = record(at: t0.addingTimeInterval(1))
        log.record([first, second], now: t0.addingTimeInterval(1))
        XCTAssertEqual(log.records(asOf: t0.addingTimeInterval(1)), [first, second])

        let third = record(at: t0.addingTimeInterval(2))
        log.record([third], now: t0.addingTimeInterval(2))
        XCTAssertEqual(log.records(asOf: t0.addingTimeInterval(2)), [first, second, third])
    }

    /// **The count bound is real, and the oldest is what goes** — proved by
    /// pushing past it rather than by reading the constant back.
    func testPastTheCountBoundTheOldestRecordsAreEvicted() {
        var log = SafetyStopLog()
        let overflow = 5
        let all = (0..<(SafetyStopLog.maxRecords + overflow)).map {
            record(at: t0.addingTimeInterval(Double($0)))
        }
        log.record(all, now: t0)

        let kept = log.records(asOf: t0)
        XCTAssertEqual(kept.count, SafetyStopLog.maxRecords)
        XCTAssertEqual(log.storedCount, SafetyStopLog.maxRecords,
                       "the bound has to bound the memory, not only the reply")
        XCTAssertEqual(kept, Array(all.suffix(SafetyStopLog.maxRecords)),
                       "the survivors are the newest, in order")
        for evicted in all.prefix(overflow) {
            XCTAssertFalse(kept.contains(evicted), "an evicted record came back")
        }
    }

    /// One maximal episode fits exactly, which is the whole argument for the
    /// number: a `.stopAll` can end `SessionAdmission.maxSessionsGlobal`
    /// sessions at once, and an episode that evicted its own oldest records
    /// would drop whichever uid the table happened to enumerate first.
    func testOneMaximalEpisodeSurvivesIntact() {
        var log = SafetyStopLog()
        let episode = (0..<SessionAdmission.maxSessionsGlobal).map { _ in record(at: t0) }
        log.record(episode, now: t0)
        XCTAssertEqual(log.records(asOf: t0), episode)
    }

    /// The age bound, read through `records(asOf:)` — a record one second past
    /// it is gone, one second inside it is not.
    func testARecordOlderThanTheAgeBoundIsNotReported() {
        var log = SafetyStopLog()
        let old = record(at: t0)
        log.record([old], now: t0)

        XCTAssertEqual(log.records(asOf: t0.addingTimeInterval(SafetyStopLog.maxAge)), [old],
                       "exactly at the bound is still inside it")
        XCTAssertEqual(log.records(asOf: t0.addingTimeInterval(SafetyStopLog.maxAge + 1)), [],
                       "a record past the age bound is a reason for the wrong ending")
    }

    /// Ageing out must free the memory too, not merely stop reporting it —
    /// otherwise a long-lived daemon accumulates records it will never report.
    func testWritingLaterEvictsWhatHasAgedOut() {
        var log = SafetyStopLog()
        log.record([record(at: t0)], now: t0)
        XCTAssertEqual(log.storedCount, 1)

        let fresh = record(at: t0.addingTimeInterval(SafetyStopLog.maxAge + 10))
        log.record([fresh], now: t0.addingTimeInterval(SafetyStopLog.maxAge + 10))
        XCTAssertEqual(log.storedCount, 1, "the aged-out record is still being held")
        XCTAssertEqual(log.records(asOf: t0.addingTimeInterval(SafetyStopLog.maxAge + 10)), [fresh])
    }

    /// A read does not mutate: reporting the age bound must not apply it, so
    /// two reads at different clocks are both answerable.
    func testReadingIsNotAWrite() {
        var log = SafetyStopLog()
        let one = record(at: t0)
        log.record([one], now: t0)
        _ = log.records(asOf: t0.addingTimeInterval(SafetyStopLog.maxAge + 1))
        XCTAssertEqual(log.records(asOf: t0), [one],
                       "a read at a later clock consumed a record")
    }

    /// Records keep their own uid, which is what lets a client filter to its
    /// own — a `.stopAll` ends every account's sessions, so an unfiltered
    /// reply is the only one that can serve them all.
    func testRecordsFromSeveralAccountsAreAllKept() {
        var log = SafetyStopLog()
        let mine = record(uid: 501, at: t0)
        let theirs = record(uid: 502, at: t0)
        log.record([mine, theirs], now: t0)
        XCTAssertEqual(log.records(asOf: t0), [mine, theirs])
        XCTAssertEqual(log.records(asOf: t0).filter { $0.ownerUID == 501 }, [mine])
    }
}
