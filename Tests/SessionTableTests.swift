import XCTest
@testable import KeepyUppy

final class SessionTableTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")
    private let bob = ClientID(rawValue: "bob")

    private func session(_ id: String, owner: ClientID,
                         persistence: SessionPersistence = .clientBound,
                         wakeMode: WakeMode = .clamshell,
                         keepsDisksAwake: Bool = false) -> Session {
        Session(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                kind: .indefinite, owner: owner, ownerUID: 0,
                persistence: persistence, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: wakeMode, keepsDisksAwake: keepsDisksAwake)
    }

    func testEmptyTableWantsSleepEnabled() {
        XCTAssertFalse(SessionTable().desiredKeepAwake)
    }

    func testAnySessionKeepsAwake() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemovingLastSessionRestoresSleep() {
        var table = SessionTable()
        let a = session("01", owner: alice)
        let b = session("02", owner: bob)
        table.insert(a); table.insert(b)
        table.remove(id: a.id)
        XCTAssertTrue(table.desiredKeepAwake, "bob's session still holds it")
        table.remove(id: b.id)
        XCTAssertFalse(table.desiredKeepAwake, "no sessions left, sleep must come back")
    }

    func testRemoveAllOwnedByEndsOnlyClientBoundSessions() {
        var table = SessionTable()
        table.insert(session("01", owner: alice, persistence: .clientBound))
        table.insert(session("02", owner: alice, persistence: .detached))
        let ended = table.removeAll(ownedBy: alice)
        XCTAssertEqual(ended.count, 1, "detached sessions survive their owner")
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemoveAllOwnedByLeavesOtherOwnersAlone() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.insert(session("02", owner: bob))
        _ = table.removeAll(ownedBy: alice)
        XCTAssertEqual(table.sessions.count, 1)
        XCTAssertEqual(table.sessions.first?.owner, bob)
    }

    func testRemovingUnknownSessionIsHarmless() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.remove(id: UUID())
        XCTAssertTrue(table.desiredKeepAwake)
        XCTAssertEqual(table.sessions.count, 1)
    }

    // MARK: - Fix 1: count/lookup accessors that don't materialise the whole table

    func testCountReflectsInsertsAndRemoves() {
        var table = SessionTable()
        XCTAssertEqual(table.count, 0)
        let a = session("01", owner: alice)
        table.insert(a)
        XCTAssertEqual(table.count, 1)
        table.remove(id: a.id)
        XCTAssertEqual(table.count, 0)
    }

    func testCountOwnedByCountsOnlyThatOwner() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.insert(session("02", owner: alice))
        table.insert(session("03", owner: bob))
        XCTAssertEqual(table.count(ownedBy: alice), 2)
        XCTAssertEqual(table.count(ownedBy: bob), 1)
    }

    func testSessionLookupByID() {
        var table = SessionTable()
        let a = session("01", owner: alice)
        table.insert(a)
        XCTAssertEqual(table.session(id: a.id), a)
        XCTAssertNil(table.session(id: UUID()))
    }

    // MARK: - Fix 1: removeExpired

    private func timedSession(_ id: String, deadline: Date, owner: ClientID) -> Session {
        Session(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                kind: .duration(until: deadline), owner: owner, ownerUID: 0,
                persistence: .clientBound, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
    }

    func testRemoveExpiredIsANoOpWhenNothingIsDue() {
        var table = SessionTable()
        table.insert(timedSession("01", deadline: t0.addingTimeInterval(3600), owner: alice))
        XCTAssertTrue(table.removeExpired(at: t0).isEmpty)
        XCTAssertEqual(table.count, 1)
    }

    func testRemoveExpiredRemovesOnlyDueSessions() {
        var table = SessionTable()
        let due = timedSession("01", deadline: t0.addingTimeInterval(60), owner: alice)
        let notDue = timedSession("02", deadline: t0.addingTimeInterval(3600), owner: bob)
        table.insert(due)
        table.insert(notDue)

        let expired = table.removeExpired(at: t0.addingTimeInterval(61))

        XCTAssertEqual(expired.map(\.id), [due.id])
        XCTAssertEqual(table.sessions.map(\.id), [notDue.id])
    }

    func testRemoveExpiredSelfHealsSoALaterDueSessionIsStillCaught() {
        var table = SessionTable()
        let soon = timedSession("01", deadline: t0.addingTimeInterval(60), owner: alice)
        let later = timedSession("02", deadline: t0.addingTimeInterval(120), owner: bob)
        table.insert(soon)
        table.insert(later)

        XCTAssertEqual(table.removeExpired(at: t0.addingTimeInterval(61)).map(\.id), [soon.id])
        // The cached earliest-deadline bound must have been tightened to
        // `later`'s deadline, not left stale, or this second call would
        // wrongly report nothing due.
        XCTAssertEqual(table.removeExpired(at: t0.addingTimeInterval(121)).map(\.id), [later.id])
        XCTAssertTrue(table.sessions.isEmpty)
    }

    func testIndefiniteSessionsAreNeverConsideredDue() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertTrue(table.removeExpired(at: .distantFuture).isEmpty)
        XCTAssertEqual(table.count, 1)
    }

    // MARK: - The reduction the daemon applies

    /// `DaemonRuntime.applyLocked` reads `desiredPowerPlan` on every event and
    /// every tick and hands it straight to `PowerPlanHolder.apply`. `Helper/`
    /// is not reachable from this target, so this property is the whole of the
    /// daemon's apply input that *can* be tested — which is why it was put
    /// here rather than written inline in the daemon.

    func testAnEmptyTableReducesToSleepAllowed() {
        XCTAssertEqual(SessionTable().desiredPowerPlan, .sleepAllowed)
    }

    /// Every session that exists today is a clamshell session (`Session`'s
    /// initializer default *and* its decode-time default), so wiring the
    /// reduction into the daemon must not have changed what such a table asks
    /// for: the global setting exactly as before, plus the system assertion
    /// the reduction now adds as defence in depth.
    func testTheDefaultClamshellSessionStillAsksForTheGlobalSetting() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true))
    }

    /// The regression the split exists to prevent, in the direction that
    /// matters most: sessions that never asked for a shut lid must not make
    /// the daemon write the root-only, reboot-surviving global setting.
    func testSessionsThatDidNotAskForAShutLidNeverSetTheGlobal() {
        var table = SessionTable()
        table.insert(session("01", owner: alice, wakeMode: .system))
        table.insert(session("02", owner: bob, wakeMode: .systemAndDisplay))
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: false))
    }

    /// Modes union across the table, and each axis is released by *its own*
    /// last asker — over the real storage, whose `Dictionary` order is not
    /// stable between runs.
    func testEachAxisSurvivesUntilItsLastAskerLeaves() {
        var table = SessionTable()
        let lid = session("01", owner: alice, wakeMode: .clamshell)
        let display = session("02", owner: bob, wakeMode: .systemAndDisplay)
        table.insert(lid)
        table.insert(display)
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventIdleDisplaySleep],
                                 sleepDisabled: true))

        table.remove(id: display.id)
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true),
                       "the lid session still needs the global setting")

        table.remove(id: lid.id)
        XCTAssertEqual(table.desiredPowerPlan, .sleepAllowed,
                       "the last session left, so both mechanisms go back")
    }

    /// `desiredKeepAwake` is now *defined* as "the reduction is non-empty",
    /// while every existing caller reads it as "is any session live". The two
    /// must agree for every request a session can make — including whichever
    /// axis is added next, which is why this loops `allCases` crossed with the
    /// disk axis instead of naming the combinations.
    func testKeepAwakeIsExactlyTheReductionBeingNonEmpty() {
        for mode in WakeMode.allCases {
            for disks in [false, true] {
                let request = "\(mode.rawValue), keepsDisksAwake=\(disks)"
                var table = SessionTable()
                XCTAssertFalse(table.desiredKeepAwake, "\(request): empty table")

                let only = session("01", owner: alice, wakeMode: mode, keepsDisksAwake: disks)
                table.insert(only)
                XCTAssertTrue(table.desiredKeepAwake,
                              "\(request) is a live session and must keep the Mac awake")
                XCTAssertNotEqual(table.desiredPowerPlan, .sleepAllowed, request)

                table.remove(id: only.id)
                XCTAssertFalse(table.desiredKeepAwake, "\(request): last session removed")
                XCTAssertEqual(table.desiredPowerPlan, .sleepAllowed, request)
            }
        }
    }

    /// The whole point of the field, at the layer the daemon reads: a session
    /// that asked for its disks to stay spun up produces a plan that holds the
    /// assertion, and one that did not produces a plan that does not — with the
    /// other two axes untouched either way.
    ///
    /// `desiredPowerPlan` maps `\.power`, so this is also the test that fails if
    /// it ever goes back to mapping one axis: a table full of disk-wanting
    /// sessions would reduce to a plan that holds nothing for them, silently.
    func testTheDiskAxisReachesTheDaemonsPlan() {
        var table = SessionTable()
        table.insert(session("01", owner: alice, wakeMode: .system, keepsDisksAwake: true))
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventDiskIdle],
                                 sleepDisabled: false))

        // A second session that wants nothing of the disks cannot take the
        // assertion away from the first — the reduction is a union.
        let indifferent = session("02", owner: bob, wakeMode: .clamshell, keepsDisksAwake: false)
        table.insert(indifferent)
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep, .preventDiskIdle],
                                 sleepDisabled: true))

        // …and when the asker leaves, it goes.
        table.remove(id: table.sessions.first(where: { $0.keepsDisksAwake })!.id)
        XCTAssertEqual(table.desiredPowerPlan,
                       PowerPlan(assertions: [.preventIdleSystemSleep], sleepDisabled: true))
    }
}

/// `isDaemonEvaluable` decides whether a session survives the agent going
/// away (spec §5). A wrong answer here is a safety bug that the type checker
/// cannot catch, so every case is pinned explicitly.
final class SessionKindEvaluationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDaemonEvaluableKinds() {
        XCTAssertTrue(SessionKind.indefinite.isDaemonEvaluable)
        XCTAssertTrue(SessionKind.duration(until: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.untilTime(t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.lease(expires: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.whileOnACPower.isDaemonEvaluable)
    }

    func testAgentEvaluatedKinds() {
        XCTAssertFalse(SessionKind.whileAppRunning(bundleID: "com.apple.dt.Xcode").isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileExternalDisplay.isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileCPUBusy(threshold: 0.5).isDaemonEvaluable)
        // Added with the kind itself, but not with this test: only the agent
        // can see the process table, so a `.whileProcessRunning` session that
        // outlived the agent would be a session nothing could ever end.
        XCTAssertFalse(SessionKind.whileProcessRunning(processName: "claude").isDaemonEvaluable)
        // Same reasoning again: only the agent enumerates mounted volumes, so
        // a `.whileVolumeMounted` session outliving the agent would be one
        // nothing could ever end.
        XCTAssertFalse(SessionKind.whileVolumeMounted(name: "Backup").isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileOnSubnet(cidr: "192.168.1.0/24").isDaemonEvaluable)
        // And again: only the agent reads the network-service configuration, so
        // a `.whileVPNActive` session outliving the agent would be one nothing
        // could ever end.
        XCTAssertFalse(SessionKind.whileVPNActive.isDaemonEvaluable)
        // And again: only the agent enumerates the USB tree.
        XCTAssertFalse(SessionKind.whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f).isDaemonEvaluable)
    }

    /// `.whileProcessRunning` was added to `SessionKind` and to
    /// `isDaemonEvaluable` without being added to the two tests above, and
    /// nothing complained — which is precisely the hole the comment on this
    /// class describes. The `switch` below closes it: it is exhaustive, so
    /// the next `SessionKind` case stops this file compiling until somebody
    /// writes down, here, which half of the world it belongs to.
    func testEveryKindHasAPinnedAnswer() {
        let allKinds: [SessionKind] = [
            .indefinite, .duration(until: t0), .untilTime(t0), .lease(expires: t0), .whileOnACPower,
            .whileAppRunning(bundleID: "com.apple.dt.Xcode"), .whileExternalDisplay,
            .whileCPUBusy(threshold: 0.5), .whileProcessRunning(processName: "claude"),
            .whileVolumeMounted(name: "Backup"), .whileOnSubnet(cidr: "192.168.1.0/24"),
            .whileVPNActive, .whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f),
            .whileOnSchedule(TriggerSchedule(dayMask: TriggerSchedule.weekdays,
                                             startMinute: 9 * 60, endMinute: 18 * 60)),
        ]
        for kind in allKinds {
            let daemonCanEvaluateItAlone: Bool
            switch kind {
            case .indefinite, .duration, .untilTime, .lease:
                daemonCanEvaluateItAlone = true   // pure clock arithmetic
            case .whileOnACPower:
                daemonCanEvaluateItAlone = true   // the daemon reads IOKit power itself
            case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy, .whileProcessRunning,
                 .whileVolumeMounted, .whileOnSubnet, .whileVPNActive, .whileUSBDevicePresent:
                daemonCanEvaluateItAlone = false  // needs the agent's observers
            case .whileOnSchedule:
                // The one kind here the daemon *could* answer alone — a clock is
                // not a device, and needs no login session. It is still `false`
                // because the code that ends one lives in the agent's evidence
                // loop, and `deadline` is nil for it, so a daemon told it owned
                // this would end it never. The honest answer is the one that
                // matches who actually does the work.
                daemonCanEvaluateItAlone = false
            }
            XCTAssertEqual(kind.isDaemonEvaluable, daemonCanEvaluateItAlone, "\(kind)")
        }
        XCTAssertEqual(allKinds.count, 14, "a case was added to SessionKind but not to allKinds")
    }
}
