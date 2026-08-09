import XCTest
import IOKit.pwr_mgt
@testable import KeepyUppy

final class PowerControlBatteryTests: XCTestCase {
    func testParsesDischargingBattery() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 87,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .battery)
        XCTAssertEqual(state.percentage, 87)
    }

    func testParsesACPower() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "AC Power",
            "Current Capacity": 100,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 100)
    }

    func testScalesWhenMaxCapacityIsNotOneHundred() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 25,
            "Max Capacity": 50,
        ])
        XCTAssertEqual(state.percentage, 50)
    }

    func testMissingKeysYieldUnknown() {
        let state = PowerControl.parseBattery(from: [:])
        XCTAssertEqual(state.source, .unknown)
        XCTAssertNil(state.percentage)
    }
}

/// The daemon's `.whileOnACPower` handling had the same
/// `.unknown`-collapses-into-false defect the tri-state observer contract
/// removed everywhere else: `DaemonRuntime.tickLocked` tested
/// `battery.source != .acPower` and, on a match, applied
/// `.acPowerDisconnected`, which ends every `.whileOnACPower` session. A
/// failed IOKit read therefore ended sessions and let the Mac sleep while it
/// was still plugged in.
///
/// `DaemonRuntime` lives in the Helper target and is not reachable from this
/// test host, so the decision itself moved to `PowerSource`, where it is both
/// testable and shared with the agent — which had the mapping right already,
/// written out inline, and no longer keeps its own copy to drift.
final class ACPowerReadingTests: XCTestCase {
    func testACPowerIsAConfidentPresent() {
        XCTAssertEqual(PowerSource.acPower.acPowerReading, .present)
        XCTAssertTrue(PowerSource.acPower.acPowerReading.isConfidentlyPresent)
    }

    func testBatteryIsAConfidentAbsent() {
        XCTAssertEqual(PowerSource.battery.acPowerReading, .absent)
        XCTAssertTrue(PowerSource.battery.acPowerReading.isConfidentlyAbsent)
    }

    /// The regression itself: a failed read must not be able to end a
    /// session. `.isConfidentlyAbsent` is the exact predicate the daemon's
    /// tick now gates `.acPowerDisconnected` on.
    func testUnknownIsUndeterminedAndCannotEndASession() {
        XCTAssertEqual(PowerSource.unknown.acPowerReading, .undetermined)
        XCTAssertFalse(PowerSource.unknown.acPowerReading.isConfidentlyAbsent)
    }

    /// A failed read must not *start* one either — it is not evidence in
    /// either direction, which is what makes `.undetermined` safe.
    func testUnknownAlsoCannotStartASession() {
        XCTAssertFalse(PowerSource.unknown.acPowerReading.isConfidentlyPresent)
    }

    /// A total IOKit failure — the path where the power-source description
    /// yields nothing usable — parses to `.unknown`, so it reaches the
    /// daemon's tick as `.undetermined` end to end, not as "unplugged".
    func testAFailedPowerReadReachesTheDaemonAsUndetermined() {
        let state = PowerControl.parseBattery(from: [:])
        XCTAssertEqual(state.source.acPowerReading, .undetermined)
    }

    /// The one true statement about ending `.whileOnACPower` sessions:
    /// exactly one of the three sources may do it.
    func testOnlyBatteryEndsACBoundSessions() {
        let enders = [PowerSource.acPower, .battery, .unknown]
            .filter { $0.acPowerReading.isConfidentlyAbsent }
        XCTAssertEqual(enders, [.battery])
    }
}

// MARK: - Assertions
//
// `PowerPlan.reduce` is the piece that carries the safety semantics of the
// second power mechanism, so it lives in `Shared/` where this test host can
// reach it — `Helper/`, where the daemon wires it up, cannot be imported here.
//
// Nothing below touches the real machine. A test that failed between
// `IOPMAssertionCreateWithName` and `IOPMAssertionRelease` would leave this
// machine awake after the run, which is why `PowerPlanHolder` takes its IOKit
// calls behind `PowerAssertionBackend` and every test here passes a fake.
//
// The same now goes double for the clamshell axis: `apply` writes both axes in
// one call, so every holder test would otherwise reach
// `IOPMSetSystemPowerSetting` — a global, root-only setting that survives
// reboot. `SleepSettingBackend` is the seam that keeps it out of the suite, and
// every holder here is constructed with a `RecordingSleepSetting`.

/// The type list is a safety constraint, not an implementation detail, so it
/// gets pinned rather than trusted.
final class PowerAssertionTypeTests: XCTestCase {
    /// The two documented, public, header-declared types — and their exact
    /// wire strings, because these are what a user reads in
    /// `pmset -g assertions` and what the manual checklist greps for.
    func testTheOnlyTypesAreTheTwoDocumentedPublicOnes() {
        XCTAssertEqual(PowerAssertionType.allCases.count, 2)
        XCTAssertEqual(PowerAssertionType.preventIdleSystemSleep.ioKitType,
                       "PreventUserIdleSystemSleep")
        XCTAssertEqual(PowerAssertionType.preventIdleDisplaySleep.ioKitType,
                       "PreventUserIdleDisplaySleep")
    }

    /// `kIOPMAssertionTypePreventSystemSleep` is the trap: its own header says
    /// "not supported in any OS X releases", and it was observed returning
    /// success, showing up in `pmset`'s per-process list, and moving no
    /// system-wide counter. A silent no-op is the worst possible failure for a
    /// keep-awake utility, so its absence is asserted rather than assumed.
    func testTheDeprecatedPreventSystemSleepTypeIsUnreachable() {
        let types = Set(PowerAssertionType.allCases.map(\.ioKitType))
        XCTAssertFalse(types.contains("PreventSystemSleep"))
    }

    /// `IOPMAssertionCreateWithName`'s header caps `AssertionName` at 128
    /// characters, and the name is the only thing tying a live assertion back
    /// to this app in `pmset` output.
    ///
    /// The ASCII check is not pedantry: the first version of these strings
    /// used an em dash, and `pmset -g assertions` rendered it as a replacement
    /// character, which is the one place the name is ever read.
    func testAssertionNamesIdentifyTheAppAndSurvivePmsetOutput() {
        for type in PowerAssertionType.allCases {
            XCTAssertTrue(type.assertionName.contains("Keepy Uppy"), type.rawValue)
            XCTAssertLessThanOrEqual(type.assertionName.count, 128, type.rawValue)
            XCTAssertTrue(type.assertionName.allSatisfy(\.isASCII),
                          "\(type.rawValue): pmset does not render non-ASCII in assertion names")
        }
    }
}

/// The reduction: "the set of `WakeMode`s wanted across all live sessions" →
/// "which assertions to hold, and whether `SleepDisabled` is on".
final class PowerPlanReductionTests: XCTestCase {
    // MARK: The four the plan asks for

    func testNoSessionsMeansNothingHeldAndSleepEnabled() {
        let plan = PowerPlan.reduce([WakeMode]())
        XCTAssertEqual(plan, .sleepAllowed)
        XCTAssertTrue(plan.assertions.isEmpty)
        XCTAssertFalse(plan.sleepDisabled, "no sessions left, so sleep must come back")
    }

    func testAnyClamshellSessionTurnsOnTheGlobalSetting() {
        XCTAssertTrue(PowerPlan.reduce([.clamshell]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([.system, .clamshell]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([.systemAndDisplay, .clamshell]).sleepDisabled)
        // …and only clamshell does. Assertions do not survive a lid close, so
        // the global setting is the only thing that can, and turning it on
        // when nobody asked would strand the Mac awake across a reboot.
        XCTAssertFalse(PowerPlan.reduce([.system]).sleepDisabled)
        XCTAssertFalse(PowerPlan.reduce([.systemAndDisplay]).sleepDisabled)
        XCTAssertFalse(PowerPlan.reduce([.system, .systemAndDisplay]).sleepDisabled)
    }

    func testDisplayAssertionHeldOnlyWhileSomeSessionWantsIt() {
        let display = PowerAssertionType.preventIdleDisplaySleep
        XCTAssertFalse(PowerPlan.reduce([.system]).assertions.contains(display))
        XCTAssertTrue(PowerPlan.reduce([.systemAndDisplay]).assertions.contains(display))
        // One session wanting it is enough while it lives…
        XCTAssertTrue(PowerPlan.reduce([.system, .systemAndDisplay]).assertions.contains(display))
        // …and when that one ends, the remaining sessions let it go.
        XCTAssertFalse(PowerPlan.reduce([.system, .clamshell]).assertions.contains(display))
    }

    func testClamshellAloneDoesNotHoldTheDisplayAssertion() {
        // The lid is shut: there is no display to hold awake, and asking for
        // one would be a contradiction rather than a harmless no-op.
        let plan = PowerPlan.reduce([.clamshell])
        XCTAssertFalse(plan.assertions.contains(.preventIdleDisplaySleep))
        XCTAssertEqual(plan, PowerPlan(assertions: [.preventIdleSystemSleep],
                                       sleepDisabled: true))
    }

    // MARK: The rest of the mapping

    /// Every mode that exists means "some session is live", and every live
    /// session wants the system not to idle-sleep. Written over `allCases` so
    /// that adding a fourth `WakeMode` fails here until someone decides
    /// deliberately what it does on this axis.
    func testEveryLiveModeHoldsTheSystemAssertion() {
        for mode in WakeMode.allCases {
            XCTAssertTrue(
                PowerPlan.reduce([mode]).assertions.contains(.preventIdleSystemSleep),
                "\(mode.rawValue) is a live session and must prevent idle system sleep")
        }
    }

    /// `.systemAndDisplay` holds both, even though the display assertion's own
    /// header says it already implies system idle-sleep prevention. Holding it
    /// explicitly makes the system assertion's lifetime exactly "some session
    /// is live", so shrinking to `.system` can never pass through a moment
    /// with nothing held.
    func testTheDisplayModeAlsoHoldsTheSystemAssertion() {
        XCTAssertEqual(PowerPlan.reduce([.systemAndDisplay]),
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: false))
    }

    func testTheSystemModeAloneHoldsOnlyTheSystemAssertion() {
        XCTAssertEqual(PowerPlan.reduce([.system]),
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: false))
    }

    /// The reduction is a union, so no session can weaken another's request
    /// and the answer cannot depend on table iteration order — which for
    /// `SessionTable`'s dictionary storage is not stable between runs.
    func testTheReductionIsAUnionAndOrderIndependent() {
        let forwards = PowerPlan.reduce([.system, .systemAndDisplay, .clamshell])
        let backwards = PowerPlan.reduce([.clamshell, .systemAndDisplay, .system])
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, PowerPlan(
            assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
            sleepDisabled: true))
    }

    /// Ten sessions of one mode reduce exactly like one — the whole reason to
    /// hold at most one assertion per type rather than one per session.
    func testManySessionsOfOneModeReduceLikeOne() {
        XCTAssertEqual(PowerPlan.reduce(Array(repeating: WakeMode.clamshell, count: 10)),
                       PowerPlan.reduce([.clamshell]))
    }

    /// The fourth cell of the 2×2 grid — display held awake *and* the lid may
    /// be shut — is a contradiction for one session and so has no `WakeMode`.
    /// It is still perfectly reachable as the union of two sessions wanting
    /// different things, which is exactly why the axis distinction has to live
    /// in the reduction rather than in the enum.
    func testTwoSessionsReachTheCellNoSingleModeCanExpress() {
        XCTAssertEqual(PowerPlan.reduce([.systemAndDisplay, .clamshell]),
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: true))
        XCTAssertFalse(WakeMode.allCases.contains {
            $0.holdsDisplayAwake && $0.requiresSleepDisabled
        })
    }

    /// The global setting has no refcount of its own, so the thing that must
    /// be true is that it survives losing a *non*-clamshell session and clears
    /// on losing the last clamshell one.
    func testTheGlobalSettingClearsOnlyWhenTheLastClamshellSessionEnds() {
        XCTAssertTrue(PowerPlan.reduce([.clamshell, .clamshell, .system]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([.clamshell, .system]).sleepDisabled,
                      "one clamshell session left, so the lid may still be shut")
        XCTAssertFalse(PowerPlan.reduce([.system]).sleepDisabled,
                       "the last clamshell session ended")
    }
}

/// A `PowerAssertionBackend` that records instead of calling IOKit.
private final class RecordingBackend: PowerAssertionBackend {
    enum Event: Equatable {
        case created(PowerAssertionType, IOPMAssertionID)
        case released(IOPMAssertionID)
    }

    var events: [Event] = []
    var nextID: IOPMAssertionID = 100
    /// Types whose `create` should fail, standing in for a `kIOReturn…` other
    /// than success.
    var failing: Set<PowerAssertionType> = []
    /// Types whose `release` should fail. The real
    /// `IOPMAssertionRelease` can return `kIOReturnNotFound` (and did, for a
    /// stale id) — before this existed, `release` always returned `true`, so
    /// the documented "the id is cleared whether or not the release succeeds"
    /// decision was never once executed by a test.
    var failingReleases: Set<PowerAssertionType> = []
    var namesSeen: [PowerAssertionType: String] = [:]
    /// Which type each live id belongs to, so `failingReleases` can be
    /// expressed per type even though `release` only ever sees an id.
    private var typeByID: [IOPMAssertionID: PowerAssertionType] = [:]

    var createdIDs: [IOPMAssertionID] {
        events.compactMap { if case .created(_, let id) = $0 { return id } else { return nil } }
    }
    /// Every id `PowerPlanHolder` handed to `release`, successful or not — so
    /// a test can assert an id was never offered back a second time.
    var releasedIDs: [IOPMAssertionID] {
        events.compactMap { if case .released(let id) = $0 { return id } else { return nil } }
    }

    func id(of type: PowerAssertionType) -> IOPMAssertionID? {
        events.compactMap {
            if case .created(type, let id) = $0 { return id } else { return nil }
        }.first
    }

    func create(type: PowerAssertionType, name: String) -> IOPMAssertionID? {
        namesSeen[type] = name
        guard !failing.contains(type) else { return nil }
        let id = nextID
        nextID += 1
        typeByID[id] = type
        events.append(.created(type, id))
        return id
    }

    func release(_ id: IOPMAssertionID) -> Bool {
        events.append(.released(id))
        guard let type = typeByID[id] else { return true }
        return !failingReleases.contains(type)
    }
}

/// A `SleepSettingBackend` that records instead of writing the real,
/// root-only, reboot-surviving `SleepDisabled`. Every holder test passes one:
/// now that both axes travel together, *any* `apply` would otherwise reach
/// `IOPMSetSystemPowerSetting` on the machine running the suite.
private final class RecordingSleepSetting: SleepSettingBackend {
    var writes: [Bool] = []
    var shouldFail = false

    var lastWrite: Bool? { writes.last }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        writes.append(disabled)
        return !shouldFail
    }
}

/// A plan that exercises the assertion axis alone. The clamshell axis is
/// spelled out rather than defaulted, because "the axis you did not mention"
/// is the exact mistake `PowerPlanHolder.apply` was reshaped to prevent.
private func assertionsOnly(_ types: Set<PowerAssertionType>) -> PowerPlan {
    PowerPlan(assertions: types, sleepDisabled: false)
}

/// The create/release bookkeeping — the part that leaks `IOPMAssertionID`s
/// when it is wrong — and the two-axis apply that carries it.
final class PowerPlanHolderTests: XCTestCase {
    private var backend = RecordingBackend()
    private var sleepSetting = RecordingSleepSetting()
    private var holder: PowerPlanHolder!

    override func setUp() {
        super.setUp()
        backend = RecordingBackend()
        sleepSetting = RecordingSleepSetting()
        holder = PowerPlanHolder(assertions: backend, sleepSetting: sleepSetting)
    }

    override func tearDown() {
        // Drop the holder *after* every assertion has run, so its `deinit`
        // release can never be mistaken for one the test asked for.
        holder = nil
        super.tearDown()
    }

    func testANewHolderHoldsNothing() {
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertTrue(sleepSetting.writes.isEmpty, "constructing a holder writes nothing")
    }

    func testApplyCreatesEachWantedTypeExactlyOnce() {
        XCTAssertTrue(holder.apply(
            assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep])))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(backend.createdIDs.count, 2)
        XCTAssertEqual(Set(backend.createdIDs).count, 2, "distinct ids")
        XCTAssertTrue(backend.releasedIDs.isEmpty)
    }

    /// The refcount hazard, directly: however many sessions want a type, the
    /// daemon holds one assertion. Re-applying the same plan must create
    /// nothing new.
    ///
    /// The clamshell axis is deliberately *not* idempotent in the same way: it
    /// is a global anyone with root can change behind our back, so it is
    /// rewritten on every apply, and that is what repairs external tampering
    /// on the next tick.
    func testReapplyingTheSamePlanCreatesNothingNewButRewritesTheSetting() {
        let plan = PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true)
        holder.apply(plan)
        for _ in 0..<10 { holder.apply(plan) }
        XCTAssertEqual(backend.createdIDs.count, 1)
        XCTAssertTrue(backend.releasedIDs.isEmpty)
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.writes, Array(repeating: true, count: 11))
    }

    func testShrinkingReleasesOnlyTheDroppedType() {
        holder.apply(assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        let displayID = backend.id(of: .preventIdleDisplaySleep)
        backend.events = []

        holder.apply(assertionsOnly([.preventIdleSystemSleep]))
        XCTAssertEqual(backend.releasedIDs, [displayID!])
        XCTAssertTrue(backend.createdIDs.isEmpty, "the surviving assertion is not recreated")
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
    }

    func testApplyingTheEmptyPlanReleasesEverythingAndEmptiesTheHolder() {
        holder.apply(PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                               sleepDisabled: true))
        let created = backend.createdIDs
        holder.apply(.sleepAllowed)
        XCTAssertEqual(Set(backend.releasedIDs), Set(created))
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(sleepSetting.lastWrite, false, "the last session leaving restores sleep")
    }

    /// The no-leak property stated as one assertion: after converging back to
    /// nothing, every id ever created has been released exactly once.
    func testEveryCreatedAssertionIsReleasedExactlyOnceAcrossAChurnOfApplies() {
        let plans: [PowerPlan] = [
            assertionsOnly([.preventIdleSystemSleep]),
            PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                      sleepDisabled: true),
            assertionsOnly([.preventIdleDisplaySleep]),
            .sleepAllowed,
            assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep]),
            PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true),
            .sleepAllowed,
        ]
        for plan in plans { holder.apply(plan) }
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(backend.createdIDs.sorted(), backend.releasedIDs.sorted())
        XCTAssertEqual(Set(backend.releasedIDs).count, backend.releasedIDs.count,
                       "no id released twice")
        XCTAssertEqual(sleepSetting.lastWrite, false,
                       "the clamshell axis came back down with the assertions")
    }

    /// A stale id must never be handed back to IOKit: whether `powerd`
    /// recycles `IOPMAssertionID`s was never established, so releasing one
    /// twice could in principle release a *different* assertion later.
    func testAnIDIsNeverReleasedTwiceEvenWhenTheEmptyPlanIsRepeated() {
        holder.apply(assertionsOnly([.preventIdleSystemSleep]))
        holder.apply(.sleepAllowed)
        holder.apply(.sleepAllowed)
        holder.apply(.sleepAllowed)
        XCTAssertEqual(backend.releasedIDs.count, 1)
    }

    /// A failed create is reported, leaves that type unheld, and does not
    /// poison the other one — and the next apply retries it.
    func testAFailedCreateIsReportedAndRetriedOnTheNextApply() {
        backend.failing = [.preventIdleDisplaySleep]
        XCTAssertFalse(holder.apply(
            assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep])))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep],
                       "the one that worked is still held")

        backend.failing = []
        XCTAssertTrue(holder.apply(
            assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep])))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(backend.createdIDs.count, 2, "the survivor was not recreated")
    }

    /// The documented decision, executed at last: *"The stored id is cleared
    /// whether or not the release succeeds."*
    ///
    /// Until `RecordingBackend.failingReleases` existed, `release` always
    /// returned `true`, so this branch never ran and inverting it — keeping the
    /// id when the release fails — passed the whole suite. The decision is not
    /// arbitrary: an `IOPMAssertionID` is an opaque handle, and whether
    /// `powerd` recycles them was never established, so a failed release makes
    /// the id *unsafe to reuse*, not merely useless. Retrying it could in
    /// principle release somebody else's assertion later.
    ///
    /// The cost is accepted and bounded: a genuinely leaked assertion stays
    /// held until the daemon exits, which keeps the Mac awake for longer than
    /// asked — the wrong direction that cannot lose a user's work.
    func testAFailedReleaseStillDropsTheIDForGood() {
        backend.failingReleases = [.preventIdleDisplaySleep]
        holder.apply(assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        let displayID = backend.id(of: .preventIdleDisplaySleep)
        XCTAssertNotNil(displayID)

        XCTAssertTrue(holder.apply(assertionsOnly([.preventIdleSystemSleep])),
                      "apply's Bool reports create failures, not release failures")
        XCTAssertFalse(holder.heldTypes.contains(.preventIdleDisplaySleep),
                       "the id is dropped even though IOKit refused the release")
        XCTAssertEqual(backend.releasedIDs, [displayID!], "released once")

        // …and never offered back to IOKit, however many times we converge.
        holder.apply(.sleepAllowed)
        holder.apply(assertionsOnly([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        holder.apply(.sleepAllowed)
        XCTAssertEqual(backend.releasedIDs.filter { $0 == displayID! }.count, 1,
                       "a stale id must never be handed back to IOKit")
    }

    /// Creates run before releases, so a transition never passes through a
    /// moment holding less than either the old set or the new one.
    func testCreatesRunBeforeReleasesWithinOneApply() {
        holder.apply(assertionsOnly([.preventIdleDisplaySleep]))
        backend.events = []
        holder.apply(assertionsOnly([.preventIdleSystemSleep]))

        guard backend.events.count == 2 else {
            return XCTFail("expected one create and one release, got \(backend.events)")
        }
        if case .created = backend.events[0] {} else {
            XCTFail("create must come first, got \(backend.events)")
        }
        if case .released = backend.events[1] {} else {
            XCTFail("release must come second, got \(backend.events)")
        }
    }

    /// Every type's name, not just the first one: the name is the only thing
    /// tying a live assertion back to this app in `pmset -g assertions`, and a
    /// type added later must not be able to reach IOKit unnamed.
    func testTheHolderPassesTheHumanReadableNameThrough() {
        holder.apply(assertionsOnly(Set(PowerAssertionType.allCases)))
        for type in PowerAssertionType.allCases {
            XCTAssertEqual(backend.namesSeen[type], type.assertionName, type.rawValue)
        }
    }

    // MARK: Both axes, one call

    /// The seam itself. `apply` takes a whole `PowerPlan`, so the clamshell
    /// axis cannot be left behind by a caller who reached for "the
    /// assertions" — the shape that used to compile,
    /// `holder.apply(plan.assertions)`, no longer type-checks.
    func testApplyingAClamshellPlanWritesTheGlobalSettingToo() {
        let plan = PowerPlan.reduce([.clamshell])
        XCTAssertTrue(holder.apply(plan))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.writes, [true],
                       "a clamshell session must reach the only mechanism that survives a lid close")
    }

    /// Both halves are reported through one `Bool`, so a daemon that already
    /// treats a failed apply as a failure keeps doing so when it is the
    /// root-only write that failed — the half that fails on *every*
    /// unprivileged run.
    func testAFailedSleepSettingWriteFailsTheApplyEvenThoughAssertionsWorked() {
        sleepSetting.shouldFail = true
        XCTAssertFalse(holder.apply(PowerPlan.reduce([.clamshell])))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep],
                       "defence in depth: idle sleep is still prevented")
    }

    /// Auto-release on process death is a safety net, not the plan: a holder
    /// that goes away while the process lives on still releases.
    ///
    /// `deinit` touches the assertion axis only. It runs on whichever thread
    /// drops the last reference, and `SleepDisabled` is a global, root-only,
    /// reboot-surviving setting whose reconciliation is `DaemonRuntime.start`'s
    /// converge-to-safe at launch — not an arbitrary thread at an arbitrary
    /// moment.
    func testDeallocatingTheHolderReleasesItsAssertionsAndOnlyThose() {
        let local = RecordingBackend()
        let localSetting = RecordingSleepSetting()
        var temporary: PowerPlanHolder? = PowerPlanHolder(assertions: local,
                                                          sleepSetting: localSetting)
        temporary?.apply(PowerPlan(assertions: [.preventIdleSystemSleep,
                                                .preventIdleDisplaySleep],
                                   sleepDisabled: true))
        XCTAssertTrue(local.releasedIDs.isEmpty)
        XCTAssertEqual(localSetting.writes, [true])

        temporary = nil
        XCTAssertEqual(Set(local.releasedIDs), Set(local.createdIDs))
        XCTAssertEqual(local.releasedIDs.count, 2)
        XCTAssertEqual(localSetting.writes, [true],
                       "deinit does not write the global setting from an unknown thread")
    }

    /// The exact predicate `DaemonRuntime.startSession` rolls a session back
    /// on. Applying the plan a live table reduced to, with *either* mechanism
    /// refusing, must report failure — "the important half worked" is not a
    /// conclusion the daemon may reach. Neither axis substitutes for the
    /// other: assertions do not survive a lid close, and `SleepDisabled` does
    /// nothing about idle sleep, so whichever half failed is a sleep path left
    /// wide open under a session the daemon believes is live.
    func testEitherMechanismFailingFailsTheWholeApply() {
        let plan = PowerPlan.reduce([.clamshell, .systemAndDisplay])

        backend.failing = [.preventIdleDisplaySleep]
        XCTAssertFalse(holder.apply(plan), "an assertion the plan wanted was refused")
        XCTAssertEqual(sleepSetting.lastWrite, true,
                       "…and the other axis still went through, which is not success")

        backend.failing = []
        sleepSetting.shouldFail = true
        XCTAssertFalse(holder.apply(plan), "the clamshell write was refused")
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                       "…and both assertions are held, which is also not success")

        sleepSetting.shouldFail = false
        XCTAssertTrue(holder.apply(plan), "both axes established: the only shape of success")
    }

    /// End to end at the level the daemon will use: a session table's worth of
    /// modes goes in, the right assertions *and* the right clamshell setting
    /// come out, and the last session leaving puts both back.
    ///
    /// The clamshell session is the point of the test. Written against
    /// `plan.assertions` — which is how this read before `apply` took the whole
    /// plan — every assertion below still passed while the one mechanism that
    /// survives a lid close was never touched.
    func testTheReductionDrivesTheHolder() {
        holder.apply(PowerPlan.reduce([.system, .systemAndDisplay]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(sleepSetting.lastWrite, false, "nobody asked for a shut lid yet")

        holder.apply(PowerPlan.reduce([.system, .clamshell]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.lastWrite, true)

        holder.apply(PowerPlan.reduce([.system]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.lastWrite, false, "the last clamshell session ended")

        holder.apply(PowerPlan.reduce([WakeMode]()))
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(backend.createdIDs.sorted(), backend.releasedIDs.sorted())
        XCTAssertEqual(sleepSetting.lastWrite, false)
    }
}
