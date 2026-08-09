import XCTest
@testable import KeepyUppy

/// `keepy-uppy reset`'s ordering rule and the two judgements either side of it,
/// which is as much of that path as a test can reach at all.
///
/// The failure this guards is not a wrong string: it is `reset` evicting the
/// daemon while `SleepDisabled` is still on. That setting is global, root-only,
/// and survives process death *and reboot*, so eviction at the wrong moment
/// leaves a Mac that never sleeps again with nothing running that could put it
/// back. The decision below is the only thing standing between the two — and
/// `sleepWasRestored` is what decides which side of it a given machine is on,
/// which is why it is here rather than inline in the daemon.
///
/// What is **not** covered, and cannot be from here: `DaemonRuntime`'s call
/// into that decision and the `Helper/main.swift` SIGTERM handler (`Helper/` is
/// not in this target's module graph), and the `reset` branch that assembles
/// these strings (`CLI/main.swift` is top-level executable code outside the
/// test target). All three are verified by reading. That is exactly why every
/// piece that could be extracted was extracted here — the same move
/// `SessionIsolation` and `SessionTable.desiredPowerPlan` already made, for the
/// same reason.
final class DaemonRemovalTests: XCTestCase {
    func testEvictionProceedsOnceTheMacCanSleepAgain() {
        XCTAssertEqual(DaemonRemoval.next(after: .sleepRestored(stopped: 0)), .unregister)
        XCTAssertEqual(DaemonRemoval.next(after: .sleepRestored(stopped: 3)), .unregister)
    }

    /// The whole point of the type. Unregistering here is the single action
    /// that turns a refusal the daemon retries every 5 seconds into one nothing
    /// will ever retry.
    func testEvictionIsRefusedWhileTheMacIsStillHeldAwake() {
        guard case .refuse = DaemonRemoval.next(after: .sleepStillDisabled(stopped: 0)) else {
            return XCTFail("unregistering with the sleep setting still on strands the Mac awake for good")
        }
    }

    /// Stated as the invariant rather than as separate cases, and iterated over
    /// `ConvergeOutcome.all` rather than a list written out here — which is what
    /// makes "a new outcome cannot be added without deciding which side of it it
    /// falls on" true of the compiler instead of true of somebody's memory. The
    /// hand-written version of this array let a fourth outcome be added and go
    /// unexercised.
    func testTheOnlyRefusedOutcomeIsTheOneWhereThisMacIsKnownToBeHeld() {
        for outcome in DaemonRemoval.ConvergeOutcome.all {
            let refused = DaemonRemoval.next(after: outcome) != .unregister
            XCTAssertEqual(refused, outcome.kind == .sleepStillDisabled,
                           "\(outcome) is on the wrong side of the rule")
        }
    }

    /// The chain the test above leans on: `all` is built from `Kind.allCases`,
    /// so it can only be missing an outcome if `Kind` is missing one — and
    /// `Kind` cannot be, because `ConvergeOutcome.kind` switches over every
    /// case and the compiler will not let that switch fall short.
    func testEveryKindOfOutcomeIsExercisedByTheInvariant() {
        XCTAssertEqual(Set(DaemonRemoval.ConvergeOutcome.all.map(\.kind)),
                       Set(DaemonRemoval.ConvergeOutcome.Kind.allCases))
    }

    /// A daemon that cannot answer is the half-installed state `reset` exists
    /// to recover, so refusing there would break the verb for its main use.
    /// Refusing gains nothing either: on a machine whose daemon is genuinely
    /// gone, nothing will clear the setting whether or not the job stays
    /// registered, and the CLI cannot clear it in the daemon's place — the
    /// write is root-only. What the caller gets instead of a refusal is the
    /// note below, which reports the setting rather than guessing at it.
    func testAnUnreachableDaemonDoesNotBlockTheRecoveryResetExistsFor() {
        XCTAssertEqual(DaemonRemoval.next(after: .unreachable), .unregister)
    }

    /// The refusal has to leave the user knowing two things they cannot see for
    /// themselves: that their install was left alone, and that waiting is the
    /// fix.
    func testTheRefusalSaysNothingWasChangedAndThatRetryingIsTheFix() {
        guard case .refuse(let reason) = DaemonRemoval.next(after: .sleepStillDisabled(stopped: 0)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("Nothing was unregistered"), reason)
        XCTAssertTrue(reason.lowercased().contains("again"), reason)
    }

    /// …and one thing it used to leave out. `prepareForRemoval` ends every
    /// session *before* it attempts the clear, so a refusal is never the no-op
    /// "nothing was unregistered" implies on its own: the eight-hour job this
    /// user was protecting has already stopped, and retrying will not bring it
    /// back.
    func testTheRefusalSaysTheSessionsHaveAlreadyEnded() {
        guard case .refuse(let ended) = DaemonRemoval.next(after: .sleepStillDisabled(stopped: 3)),
              case .refuse(let none) = DaemonRemoval.next(after: .sleepStillDisabled(stopped: 0)) else {
            return XCTFail("expected refusals")
        }
        XCTAssertTrue(ended.contains("3 session(s) were ended"), ended)
        XCTAssertTrue(none.contains("no sessions were running"), none)
    }

    /// The bug this method exists for: `IOPMSetSystemPowerSetting` is
    /// undeclared SPI and a machine can refuse those writes outright — a case
    /// `PowerPlanHolder.apply` already contemplates. Reporting the write's
    /// return value made every `reset` on such a machine refuse, forever, while
    /// telling the user to try again in five seconds; and the same refusal
    /// protected a Mac that was never held, because the write to `1` had been
    /// refused too.
    func testAMacThatRefusesEveryWriteIsNotMistakenForAMacThatIsHeld() {
        XCTAssertTrue(DaemonRemoval.sleepWasRestored(writeSucceeded: false, settingStillOn: false),
                      "a refused write plus a setting that reads off is a Mac that can sleep; "
                      + "calling it held locks the recovery verb out permanently")
    }

    /// The rest of the truth table, in one place because the three answers only
    /// make sense next to each other: only a Mac whose setting is *still on*
    /// after a clear that *did not land* is known to be held. A setting still
    /// on after a clear that did land is some other root process's doing, which
    /// no amount of retrying this daemon will fix — so it is not a refusal
    /// either.
    func testOnlyARefusedClearThatLeftTheSettingOnCountsAsStillHeld() {
        XCTAssertFalse(DaemonRemoval.sleepWasRestored(writeSucceeded: false, settingStillOn: true))
        XCTAssertTrue(DaemonRemoval.sleepWasRestored(writeSucceeded: true, settingStillOn: false))
        XCTAssertTrue(DaemonRemoval.sleepWasRestored(writeSucceeded: true, settingStillOn: true))
    }

    /// The note used to name a check ("run `pmset -g | grep -i sleepdisabled`")
    /// on the grounds that the CLI could neither read nor repair the setting.
    /// The repair is root-only; the read is not, and `PowerControl` is compiled
    /// into the CLI target — so the note states what this Mac's setting says,
    /// and hands over the one command that fixes it. A user who ran the old
    /// check and saw `1` was told nothing further.
    func testTheUnreachableNoteReportsTheSettingAndNamesTheFixItCannotPerform() {
        let held = DaemonRemoval.unreachableNote(sleepStillDisabled: true)
        XCTAssertTrue(held.lowercased().contains("sleepdisabled"), held)
        XCTAssertTrue(held.contains(DaemonRemoval.manualSleepRepair), held)

        let free = DaemonRemoval.unreachableNote(sleepStillDisabled: false)
        XCTAssertFalse(free.contains(DaemonRemoval.manualSleepRepair),
                       "a Mac that is not being held must not be handed a root command it does not need: "
                       + free)
    }

    /// A daemon that accepts the request and never replies leaves `reset`
    /// exiting on its shared 10s timeout, which unregisters nothing — the safe
    /// direction, said to nobody. This is the same three facts the refusal
    /// gives: the install was left alone, what this Mac's setting reads, and
    /// what to do next.
    func testTheTimeoutNoteSaysNothingWasUnregisteredAndWhatToDoNext() {
        for stillOn in [true, false] {
            let note = DaemonRemoval.timedOutNote(sleepStillDisabled: stillOn)
            XCTAssertTrue(note.contains("nothing was unregistered"), note)
            XCTAssertTrue(note.contains("keepy-uppy reset"), note)
        }
        XCTAssertTrue(DaemonRemoval.timedOutNote(sleepStillDisabled: true)
                        .contains(DaemonRemoval.manualSleepRepair),
                      "a Mac still held awake by a daemon that stopped answering needs the repair, "
                      + "not just a retry")
    }
}
