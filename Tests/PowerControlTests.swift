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
    /// The three documented, public, header-declared types — and their exact
    /// wire strings, because these are what a user reads in
    /// `pmset -g assertions` and what the manual checklist greps for.
    ///
    /// `PreventDiskIdle` earns its place on the same evidence the other two
    /// have: a current header entry with no deprecation marker, `caffeinate -m`
    /// as the OS's own use of it, and a measured 0 → 1 → 0 on `powerd`'s
    /// aggregate. The count is asserted so that a fourth type cannot arrive
    /// without somebody producing the same evidence for it.
    func testTheOnlyTypesAreTheThreeDocumentedPublicOnes() {
        XCTAssertEqual(PowerAssertionType.allCases.count, 3)
        XCTAssertEqual(PowerAssertionType.preventIdleSystemSleep.ioKitType,
                       "PreventUserIdleSystemSleep")
        XCTAssertEqual(PowerAssertionType.preventIdleDisplaySleep.ioKitType,
                       "PreventUserIdleDisplaySleep")
        XCTAssertEqual(PowerAssertionType.preventDiskIdle.ioKitType, "PreventDiskIdle")
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

/// A `PowerRequest` with **both** axes named, for the call sites below.
///
/// It takes no defaults, exactly as `PowerRequest` itself takes none: a helper
/// that let an axis be omitted would reintroduce at the test layer the hazard
/// the type was shaped to remove at the product layer. Every reduction below
/// therefore states what it wants of the disks, including — especially — when
/// the answer is "nothing".
private func asks(_ wakeMode: WakeMode, disks: Bool) -> PowerRequest {
    PowerRequest(wakeMode: wakeMode, keepsDisksAwake: disks)
}

/// The reduction: "what every live session asks of the machine" → "which
/// assertions to hold, and whether `SleepDisabled` is on".
final class PowerPlanReductionTests: XCTestCase {
    // MARK: The four the plan asks for

    /// Also the plan's `testNoSessionsMeansNothingHeldAtAll`, which is this
    /// test with a third axis: `assertions.isEmpty` is strictly stronger than
    /// naming the types absent one by one, and a second test making a weaker
    /// version of the same claim would be a test that can never fail on its own.
    func testNoSessionsMeansNothingHeldAndSleepEnabled() {
        let plan = PowerPlan.reduce([PowerRequest]())
        XCTAssertEqual(plan, .sleepAllowed)
        XCTAssertTrue(plan.assertions.isEmpty, "including the disk assertion")
        XCTAssertFalse(plan.sleepDisabled, "no sessions left, so sleep must come back")
    }

    func testAnyClamshellSessionTurnsOnTheGlobalSetting() {
        XCTAssertTrue(PowerPlan.reduce([asks(.clamshell, disks: false)]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([asks(.system, disks: false), asks(.clamshell, disks: false)]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([asks(.systemAndDisplay, disks: false), asks(.clamshell, disks: false)]).sleepDisabled)
        // …and only clamshell does. Assertions do not survive a lid close, so
        // the global setting is the only thing that can, and turning it on
        // when nobody asked would strand the Mac awake across a reboot.
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false)]).sleepDisabled)
        XCTAssertFalse(PowerPlan.reduce([asks(.systemAndDisplay, disks: false)]).sleepDisabled)
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false), asks(.systemAndDisplay, disks: false)]).sleepDisabled)
    }

    func testDisplayAssertionHeldOnlyWhileSomeSessionWantsIt() {
        let display = PowerAssertionType.preventIdleDisplaySleep
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false)]).assertions.contains(display))
        XCTAssertTrue(PowerPlan.reduce([asks(.systemAndDisplay, disks: false)]).assertions.contains(display))
        // One session wanting it is enough while it lives…
        XCTAssertTrue(PowerPlan.reduce([asks(.system, disks: false), asks(.systemAndDisplay, disks: false)]).assertions.contains(display))
        // …and when that one ends, the remaining sessions let it go.
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false), asks(.clamshell, disks: false)]).assertions.contains(display))
    }

    func testClamshellAloneDoesNotHoldTheDisplayAssertion() {
        // The lid is shut: there is no display to hold awake, and asking for
        // one would be a contradiction rather than a harmless no-op.
        let plan = PowerPlan.reduce([asks(.clamshell, disks: false)])
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
                PowerPlan.reduce([asks(mode, disks: false)]).assertions.contains(.preventIdleSystemSleep),
                "\(mode.rawValue) is a live session and must prevent idle system sleep")
        }
    }

    /// `.systemAndDisplay` holds both, even though the display assertion's own
    /// header says it already implies system idle-sleep prevention. Holding it
    /// explicitly makes the system assertion's lifetime exactly "some session
    /// is live", so shrinking to `.system` can never pass through a moment
    /// with nothing held.
    func testTheDisplayModeAlsoHoldsTheSystemAssertion() {
        XCTAssertEqual(PowerPlan.reduce([asks(.systemAndDisplay, disks: false)]),
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: false))
    }

    func testTheSystemModeAloneHoldsOnlyTheSystemAssertion() {
        XCTAssertEqual(PowerPlan.reduce([asks(.system, disks: false)]),
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: false))
    }

    /// The reduction is a union, so no session can weaken another's request
    /// and the answer cannot depend on table iteration order — which for
    /// `SessionTable`'s dictionary storage is not stable between runs.
    func testTheReductionIsAUnionAndOrderIndependent() {
        let forwards = PowerPlan.reduce([asks(.system, disks: false), asks(.systemAndDisplay, disks: false), asks(.clamshell, disks: false)])
        let backwards = PowerPlan.reduce([asks(.clamshell, disks: false), asks(.systemAndDisplay, disks: false), asks(.system, disks: false)])
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, PowerPlan(
            assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
            sleepDisabled: true))
    }

    /// Ten sessions of one mode reduce exactly like one — the whole reason to
    /// hold at most one assertion per type rather than one per session.
    func testManySessionsOfOneModeReduceLikeOne() {
        XCTAssertEqual(PowerPlan.reduce(Array(repeating: asks(.clamshell, disks: false), count: 10)),
                       PowerPlan.reduce([asks(.clamshell, disks: false)]))
    }

    /// The fourth cell of the 2×2 grid — display held awake *and* the lid may
    /// be shut — is a contradiction for one session and so has no `WakeMode`.
    /// It is still perfectly reachable as the union of two sessions wanting
    /// different things, which is exactly why the axis distinction has to live
    /// in the reduction rather than in the enum.
    func testTwoSessionsReachTheCellNoSingleModeCanExpress() {
        XCTAssertEqual(PowerPlan.reduce([asks(.systemAndDisplay, disks: false), asks(.clamshell, disks: false)]),
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: true))
        XCTAssertFalse(WakeMode.allCases.contains {
            $0.holdsDisplayAwake && $0.requiresSleepDisabled
        })
    }

    // MARK: The third axis

    /// The same shape as `testDisplayAssertionHeldOnlyWhileSomeSessionWantsIt`,
    /// on the axis added by this plan: one session asking is enough while it
    /// lives, and the assertion goes when the last asker does.
    func testTheDiskAssertionIsHeldOnlyWhileSomeSessionWantsIt() {
        let disk = PowerAssertionType.preventDiskIdle
        XCTAssertFalse(PowerPlan.reduce([asks(.clamshell, disks: false)]).assertions.contains(disk))
        XCTAssertTrue(PowerPlan.reduce([asks(.clamshell, disks: true)]).assertions.contains(disk))
        // One session wanting it is enough while it lives…
        XCTAssertTrue(PowerPlan.reduce([asks(.system, disks: false),
                                        asks(.systemAndDisplay, disks: true)])
            .assertions.contains(disk))
        // …and when that one ends, the remaining sessions let it go.
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false),
                                         asks(.clamshell, disks: false)])
            .assertions.contains(disk))
    }

    /// A **third axis, not a fourth `WakeMode`**: every combination is legal and
    /// the disk answer changes nothing else about the plan. Over `allCases`, so
    /// a fourth mode inherits the guarantee instead of being spot-checked —
    /// and so that a reduction that quietly coupled the two (holding disks only
    /// for `.systemAndDisplay`, say, on the theory that a "screen-on" session is
    /// the media one) fails here rather than surprising somebody at 3am.
    func testTheDiskAssertionIsIndependentOfEveryWakeMode() {
        for mode in WakeMode.allCases {
            let without = PowerPlan.reduce([asks(mode, disks: false)])
            let with = PowerPlan.reduce([asks(mode, disks: true)])

            XCTAssertFalse(without.assertions.contains(.preventDiskIdle),
                           "\(mode.rawValue) did not ask for the disk assertion")
            XCTAssertTrue(with.assertions.contains(.preventDiskIdle),
                          "\(mode.rawValue) asked for the disk assertion and must get it")
            XCTAssertEqual(with,
                           PowerPlan(assertions: without.assertions.union([.preventDiskIdle]),
                                     sleepDisabled: without.sleepDisabled),
                           "\(mode.rawValue): the disk axis must move the disk assertion and "
                           + "nothing else — not the lid, not the display")
        }
    }

    /// The global setting has no refcount of its own, so the thing that must
    /// be true is that it survives losing a *non*-clamshell session and clears
    /// on losing the last clamshell one.
    func testTheGlobalSettingClearsOnlyWhenTheLastClamshellSessionEnds() {
        XCTAssertTrue(PowerPlan.reduce([asks(.clamshell, disks: false), asks(.clamshell, disks: false), asks(.system, disks: false)]).sleepDisabled)
        XCTAssertTrue(PowerPlan.reduce([asks(.clamshell, disks: false), asks(.system, disks: false)]).sleepDisabled,
                      "one clamshell session left, so the lid may still be shut")
        XCTAssertFalse(PowerPlan.reduce([asks(.system, disks: false)]).sleepDisabled,
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
        let plan = PowerPlan.reduce([asks(.clamshell, disks: false)])
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
        XCTAssertFalse(holder.apply(PowerPlan.reduce([asks(.clamshell, disks: false)])))
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
        let plan = PowerPlan.reduce([asks(.clamshell, disks: false), asks(.systemAndDisplay, disks: false)])

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

    /// The same conjunction, in the one plan shape where it is genuinely
    /// contested — and the only shape a session produces today.
    ///
    /// A **pure clamshell** plan is the hard case because `SleepDisabled` alone
    /// already prevents every sleep path, idle included, so the system
    /// assertion the plan also asks for looks redundant. Carving that out —
    /// "the setting landed, so call it success" — passes every other test in
    /// this file, which is exactly why this one exists.
    ///
    /// The carve-out is refused deliberately. `PowerPlan.reduce` holds the
    /// system assertion for a clamshell session as *defence in depth*: the
    /// clamshell mechanism is undeclared, root-only SPI that can fail, and when
    /// it does, the assertion is both the remaining protection against idle
    /// sleep and the only thing that shows a user in `pmset -g assertions` why
    /// their Mac is awake. A clamshell session's promise is about the whole
    /// machine, so the daemon does not accept credit from one mechanism for the
    /// other's failure: if the plan asked for it and it is not held, the start
    /// is denied and the caller retries in five seconds.
    func testAClamshellPlanFailsWhenOnlyItsRedundantLookingSystemAssertionFails() {
        backend.failing = [.preventIdleSystemSleep]

        XCTAssertFalse(holder.apply(PowerPlan.reduce([asks(.clamshell, disks: false)])),
                       "the plan asked for the system assertion and did not get it")
        XCTAssertEqual(sleepSetting.lastWrite, true,
                       "…and the mechanism that survives a lid close did land, which is not success")
        XCTAssertTrue(holder.heldTypes.isEmpty, "the refused create leaves nothing held")

        backend.failing = []
        XCTAssertTrue(holder.apply(PowerPlan.reduce([asks(.clamshell, disks: false)])),
                      "both axes established on the retry")
    }

    /// The other direction of the same write, which is **not** an apply
    /// failure.
    ///
    /// A refused write of `false` leaves the global setting on, so the Mac
    /// stays awake for longer than asked — never less. That is the same
    /// over-application a failed release is already forgiven for, and the same
    /// direction that cannot lose a user's work. Failing the apply over it
    /// would let one machine whose undeclared SPI refuses writes deny *every*
    /// session, including `.system` and `.systemAndDisplay` plans, which ask
    /// nothing of that axis — `sleepDisabled: false` is precisely what they
    /// want.
    ///
    /// This is also what makes `DaemonRuntime.applyLocked`'s claim true: a
    /// `false` from the holder can only ever mean under-application, which is
    /// why `startSession` may destroy a session over one.
    func testARefusedClearOfTheGlobalSettingIsNotAnApplyFailure() {
        sleepSetting.shouldFail = true

        XCTAssertTrue(holder.apply(PowerPlan.reduce([asks(.system, disks: false)])),
                      "a plan wanting sleepDisabled: false is not failed by a refused write")
        XCTAssertTrue(holder.apply(.sleepAllowed),
                      "…and neither is converging all the way back to nothing")
        XCTAssertEqual(sleepSetting.writes, [false, false],
                       "the write is still attempted every time, refused or not")

        // The same backend refusing the same call is a failure when the plan
        // wants the setting *on*: that direction under-applies.
        XCTAssertFalse(holder.apply(PowerPlan.reduce([asks(.clamshell, disks: false)])),
                       "a refused write of true leaves a clamshell promise unkept")
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
        holder.apply(PowerPlan.reduce([asks(.system, disks: false), asks(.systemAndDisplay, disks: false)]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(sleepSetting.lastWrite, false, "nobody asked for a shut lid yet")

        holder.apply(PowerPlan.reduce([asks(.system, disks: false), asks(.clamshell, disks: false)]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.lastWrite, true)

        holder.apply(PowerPlan.reduce([asks(.system, disks: false)]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
        XCTAssertEqual(sleepSetting.lastWrite, false, "the last clamshell session ended")

        holder.apply(PowerPlan.reduce([PowerRequest]()))
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(backend.createdIDs.sorted(), backend.releasedIDs.sorted())
        XCTAssertEqual(sleepSetting.lastWrite, false)
    }

    /// The last session wanting disks awake ending must **release** the
    /// assertion, not merely stop asking for it. This is the over-application
    /// half of the mutator rule, and the half that flattens a battery: an
    /// assertion nobody asked for any more holds every attached disk out of
    /// idle for the daemon's whole lifetime, silently, and `pmset` is the only
    /// place it shows.
    ///
    /// `PowerPlanHolder.releaseAssertions(notIn:)` loops
    /// `PowerAssertionType.allCases`, so a new case gets this behaviour for
    /// free — which is exactly why it needs a test. "For free" is how a
    /// guarantee stops being checked.
    func testTheDiskAssertionIsReleasedWhenTheLastSessionWantingItEnds() {
        holder.apply(PowerPlan.reduce([asks(.system, disks: true),
                                       asks(.clamshell, disks: false)]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventDiskIdle])
        let diskID = backend.id(of: .preventDiskIdle)
        XCTAssertNotNil(diskID)

        // The disk-wanting session ends; the other one is still live, so this
        // is the transition that matters — not "everything stopped".
        holder.apply(PowerPlan.reduce([asks(.clamshell, disks: false)]))

        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep],
                       "nobody wants the disks held any more")
        XCTAssertEqual(backend.releasedIDs, [diskID],
                       "and it was really released, not merely dropped from the plan")
    }
}

/// The one test in this suite that touches the real machine, and the only one
/// that can answer the question every other test here takes on faith: **did our
/// create actually reach `powerd`?**
///
/// This is the test `PreventSystemSleep` never had. That type returned
/// `kIOReturnSuccess`, appeared in `pmset`'s per-process listing, and moved no
/// system-wide entry at all — it failed silently, and nothing caught it because
/// every test used a fake backend, which can only ever confirm that we asked.
///
/// What this proves is exactly that our create reached `powerd` and our release
/// was honoured. It is **not** a test of `PowerPlanHolder`'s bookkeeping, which
/// the fake covers thoroughly and correctly, and it is **not** proof that the
/// type is a live one: on AC power the deprecated `PreventSystemSleep` moves its
/// own aggregate entry in exactly this way (measured — see
/// `.superpowers/sdd/power-assertion-research.md`). The evidence that
/// `PreventDiskIdle` is a real, undeprecated, `caffeinate -m`-shipped assertion
/// is in `plan6-drive-alive-research.md`, not here. Do not re-inflate the claim,
/// and do not "simplify" this onto the fake backend.
final class SystemWideAssertionLevelTests: XCTestCase {
    /// `powerd`'s own aggregate for one assertion type, or `-1` if
    /// `IOPMCopyAssertionsStatus` would not answer at all.
    ///
    /// **`Level`, not `Count`, and the name is load-bearing.** The header:
    /// *"The system-wide level is the maximum of all individual assertions'
    /// levels."* A name saying "count" is what produces an `== 1` assertion,
    /// which is the false pass this whole test exists to avoid.
    ///
    /// `IOPMCopyAssertionsStatus` is an **out-parameter** function returning
    /// `IOReturn` — not a returning call, however many documents have written it
    /// as one — and the dictionary it fills in must be released by the caller,
    /// hence `takeRetainedValue`.
    private func systemWideAssertionLevel(_ type: String) -> Int {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let levels = status?.takeRetainedValue() as? [String: Int] else { return -1 }
        // An absent key is a real zero: `powerd` lists every type it tracks,
        // and `PreventDiskIdle` was observed present at level 0 on this machine
        // with nothing holding one.
        return levels[type] ?? 0
    }

    /// One test, both directions, one `defer` — deliberately not two.
    ///
    /// A separate release test would have to re-establish the same baseline and
    /// create a second assertion, and a second create is a second chance to leak
    /// one. Holding the whole 0 → 1 → 0 transition here is both stricter and
    /// safer: the `defer` runs even if an assertion between the two fails, so
    /// nothing can leave this machine's disks spinning after the run.
    ///
    /// **It asserts a delta from a verified-zero baseline, never an absolute
    /// value.** The aggregate is a level, so `XCTAssertEqual(level, 1)` after a
    /// create passes on any machine where anything else already holds one —
    /// Music or another audio/video app, Time Machine, a stray `caffeinate -m` —
    /// and would have passed even if our create had done nothing at all. The
    /// release half fails spuriously under the same condition. Skipping is the
    /// honest response: the test cannot answer its own question while somebody
    /// else is holding the level up.
    func testHoldingTheDiskAssertionMovesTheSystemWideLevel() throws {
        let key = PowerAssertionType.preventDiskIdle.ioKitType

        let baseline = systemWideAssertionLevel(key)
        guard baseline >= 0 else {
            return XCTFail("IOPMCopyAssertionsStatus would not report levels at all, "
                           + "so this Mac cannot be asked whether the assertion landed")
        }
        try XCTSkipUnless(baseline == 0, """
            Something else on this Mac already holds a PreventDiskIdle assertion \
            (level \(baseline)), so a 0 -> 1 -> 0 transition cannot be observed. \
            Likely holders: Music or another audio/video app, Time Machine, a \
            `caffeinate -m` left running. Check with `pmset -g assertions`, which \
            prints the PreventDiskIdle row whenever it is non-zero, and the owning \
            process underneath it.
            """)

        let backend = IOKitPowerAssertionBackend()
        guard let id = backend.create(type: .preventDiskIdle,
                                      name: PowerAssertionType.preventDiskIdle.assertionName) else {
            return XCTFail("PreventDiskIdle could not be created at all")
        }
        var released = false
        defer { if !released { _ = backend.release(id) } }

        XCTAssertEqual(systemWideAssertionLevel(key), 1,
                       "powerd's aggregate did not move: this is the PreventSystemSleep failure")

        _ = backend.release(id)
        released = true
        XCTAssertEqual(systemWideAssertionLevel(key), 0,
                       "released and the level stayed up: over-application, "
                       + "the mutator rule's dangerous half")
    }
}
