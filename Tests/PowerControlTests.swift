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
// Nothing below creates a real system assertion. A test that failed between
// `IOPMAssertionCreateWithName` and `IOPMAssertionRelease` would leave this
// machine awake after the run, which is why `PowerAssertions` takes its IOKit
// calls behind `PowerAssertionBackend` and every test here passes a fake.

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
    var namesSeen: [PowerAssertionType: String] = [:]

    var createdIDs: [IOPMAssertionID] {
        events.compactMap { if case .created(_, let id) = $0 { return id } else { return nil } }
    }
    var releasedIDs: [IOPMAssertionID] {
        events.compactMap { if case .released(let id) = $0 { return id } else { return nil } }
    }

    func create(type: PowerAssertionType, name: String) -> IOPMAssertionID? {
        namesSeen[type] = name
        guard !failing.contains(type) else { return nil }
        let id = nextID
        nextID += 1
        events.append(.created(type, id))
        return id
    }

    func release(_ id: IOPMAssertionID) -> Bool {
        events.append(.released(id))
        return true
    }
}

/// The create/release bookkeeping — the part that leaks `IOPMAssertionID`s
/// when it is wrong.
final class PowerAssertionsHolderTests: XCTestCase {
    private var backend = RecordingBackend()
    private var holder: PowerAssertions!

    override func setUp() {
        super.setUp()
        backend = RecordingBackend()
        holder = PowerAssertions(backend: backend)
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
    }

    func testApplyCreatesEachWantedTypeExactlyOnce() {
        XCTAssertTrue(holder.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(backend.createdIDs.count, 2)
        XCTAssertEqual(Set(backend.createdIDs).count, 2, "distinct ids")
        XCTAssertTrue(backend.releasedIDs.isEmpty)
    }

    /// The refcount hazard, directly: however many sessions want a type, the
    /// daemon holds one assertion. Re-applying the same set must be a no-op.
    func testReapplyingTheSameSetCreatesNothingNew() {
        holder.apply([.preventIdleSystemSleep])
        for _ in 0..<10 { holder.apply([.preventIdleSystemSleep]) }
        XCTAssertEqual(backend.createdIDs.count, 1)
        XCTAssertTrue(backend.releasedIDs.isEmpty)
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
    }

    func testShrinkingReleasesOnlyTheDroppedType() {
        holder.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep])
        let displayID = backend.events.compactMap { event -> IOPMAssertionID? in
            if case .created(.preventIdleDisplaySleep, let id) = event { return id }
            return nil
        }.first
        backend.events = []

        holder.apply([.preventIdleSystemSleep])
        XCTAssertEqual(backend.releasedIDs, [displayID!])
        XCTAssertTrue(backend.createdIDs.isEmpty, "the surviving assertion is not recreated")
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])
    }

    func testReleaseAllReleasesEverythingAndEmptiesTheHolder() {
        holder.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep])
        let created = backend.createdIDs
        holder.releaseAll()
        XCTAssertEqual(Set(backend.releasedIDs), Set(created))
        XCTAssertTrue(holder.heldTypes.isEmpty)
    }

    /// The no-leak property stated as one assertion: after converging back to
    /// nothing, every id ever created has been released exactly once.
    func testEveryCreatedAssertionIsReleasedExactlyOnceAcrossAChurnOfApplies() {
        let sets: [Set<PowerAssertionType>] = [
            [.preventIdleSystemSleep],
            [.preventIdleSystemSleep, .preventIdleDisplaySleep],
            [.preventIdleDisplaySleep],
            [],
            [.preventIdleSystemSleep, .preventIdleDisplaySleep],
            [.preventIdleSystemSleep],
            [],
        ]
        for wanted in sets { holder.apply(wanted) }
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(backend.createdIDs.sorted(), backend.releasedIDs.sorted())
        XCTAssertEqual(Set(backend.releasedIDs).count, backend.releasedIDs.count,
                       "no id released twice")
    }

    /// A stale id must never be handed back to IOKit: whether `powerd`
    /// recycles `IOPMAssertionID`s was never established, so releasing one
    /// twice could in principle release a *different* assertion later.
    func testAnIDIsNeverReleasedTwiceEvenWhenReleaseAllIsRepeated() {
        holder.apply([.preventIdleSystemSleep])
        holder.releaseAll()
        holder.releaseAll()
        holder.releaseAll()
        XCTAssertEqual(backend.releasedIDs.count, 1)
    }

    /// A failed create is reported, leaves that type unheld, and does not
    /// poison the other one — and the next apply retries it.
    func testAFailedCreateIsReportedAndRetriedOnTheNextApply() {
        backend.failing = [.preventIdleDisplaySleep]
        XCTAssertFalse(holder.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep],
                       "the one that worked is still held")

        backend.failing = []
        XCTAssertTrue(holder.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep]))
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(backend.createdIDs.count, 2, "the survivor was not recreated")
    }

    /// Creates run before releases, so a transition never passes through a
    /// moment holding less than either the old set or the new one.
    func testCreatesRunBeforeReleasesWithinOneApply() {
        holder.apply([.preventIdleDisplaySleep])
        backend.events = []
        holder.apply([.preventIdleSystemSleep])

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

    func testTheHolderPassesTheHumanReadableNameThrough() {
        holder.apply([.preventIdleSystemSleep])
        XCTAssertEqual(backend.namesSeen[.preventIdleSystemSleep],
                       PowerAssertionType.preventIdleSystemSleep.assertionName)
    }

    /// Auto-release on process death is a safety net, not the plan: a holder
    /// that goes away while the process lives on still releases.
    func testDeallocatingTheHolderReleasesWhatItHeld() {
        let local = RecordingBackend()
        var temporary: PowerAssertions? = PowerAssertions(backend: local)
        temporary?.apply([.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertTrue(local.releasedIDs.isEmpty)

        temporary = nil
        XCTAssertEqual(Set(local.releasedIDs), Set(local.createdIDs))
        XCTAssertEqual(local.releasedIDs.count, 2)
    }

    /// End to end at the level the daemon will use: a session table's worth of
    /// modes goes in, the right assertions come out, and the last session
    /// leaving puts everything back.
    func testTheReductionDrivesTheHolder() {
        holder.apply(PowerPlan.reduce([.system, .systemAndDisplay]).assertions)
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep, .preventIdleDisplaySleep])

        holder.apply(PowerPlan.reduce([.system]).assertions)
        XCTAssertEqual(holder.heldTypes, [.preventIdleSystemSleep])

        holder.apply(PowerPlan.reduce([WakeMode]()).assertions)
        XCTAssertTrue(holder.heldTypes.isEmpty)
        XCTAssertEqual(backend.createdIDs.sorted(), backend.releasedIDs.sorted())
    }
}
