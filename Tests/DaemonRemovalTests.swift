import XCTest
@testable import KeepyUppy

/// `keepy-uppy reset`'s ordering rule, which is the only part of that path a
/// test can reach at all.
///
/// The failure this guards is not a wrong string: it is `reset` evicting the
/// daemon while `SleepDisabled` is still on. That setting is global, root-only,
/// and survives process death *and reboot*, so eviction at the wrong moment
/// leaves a Mac that never sleeps again with nothing running that could put it
/// back. The decision below is the only thing standing between the two.
///
/// What is **not** covered, and cannot be from here: the daemon's
/// `prepareForRemoval` (`Helper/` is not in this target's module graph) and the
/// `reset` branch that calls it (`CLI/main.swift` is top-level executable code
/// outside the test target). Both are verified by reading. That is exactly why
/// the decision was extracted here rather than written inline in either of
/// them — the same move `SessionIsolation` and `SessionTable.desiredPowerPlan`
/// already made, for the same reason.
final class DaemonRemovalTests: XCTestCase {
    func testEvictionProceedsOnceTheMacCanSleepAgain() {
        XCTAssertEqual(DaemonRemoval.next(after: .sleepRestored(stopped: 0)), .unregister)
        XCTAssertEqual(DaemonRemoval.next(after: .sleepRestored(stopped: 3)), .unregister)
    }

    /// The whole point of the type. Unregistering here is the single action
    /// that turns a refusal the daemon retries every 5 seconds into one nothing
    /// will ever retry.
    func testEvictionIsRefusedWhileTheMacIsStillHeldAwake() {
        guard case .refuse = DaemonRemoval.next(after: .sleepStillDisabled) else {
            return XCTFail("unregistering with the sleep setting still on strands the Mac awake for good")
        }
    }

    /// Stated as the invariant rather than as three separate cases, so a fourth
    /// outcome cannot be added without deciding which side of it that outcome
    /// falls on.
    func testTheOnlyRefusedOutcomeIsTheOneWhereThisMacIsKnownToBeHeld() {
        let outcomes: [DaemonRemoval.ConvergeOutcome] =
            [.sleepRestored(stopped: 0), .sleepRestored(stopped: 7), .sleepStillDisabled, .unreachable]
        for outcome in outcomes {
            let refused = DaemonRemoval.next(after: outcome) != .unregister
            XCTAssertEqual(refused, outcome == .sleepStillDisabled,
                           "\(outcome) is on the wrong side of the rule")
        }
    }

    /// A daemon that cannot answer is the half-installed state `reset` exists
    /// to recover, so refusing there would break the verb for its main use.
    /// Nothing is gained by refusing either: an unreachable daemon will not
    /// clear the setting whether or not it stays registered, and the CLI is
    /// unprivileged so it cannot clear it in the daemon's place.
    func testAnUnreachableDaemonDoesNotBlockTheRecoveryResetExistsFor() {
        XCTAssertEqual(DaemonRemoval.next(after: .unreachable), .unregister)
    }

    /// The refusal has to leave the user knowing two things they cannot see for
    /// themselves: that their install was left alone, and that waiting is the
    /// fix.
    func testTheRefusalSaysNothingWasChangedAndThatRetryingIsTheFix() {
        guard case .refuse(let reason) = DaemonRemoval.next(after: .sleepStillDisabled) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("Nothing was unregistered"), reason)
        XCTAssertTrue(reason.lowercased().contains("again"), reason)
    }

    /// The note for an unreachable daemon must name the check rather than
    /// perform it — the CLI has no privilege to read or repair the setting —
    /// and must not read as a failure, since on a machine that was never set up
    /// this is the ordinary case.
    func testTheUnreachableNoteNamesTheCheckItCannotPerform() {
        XCTAssertTrue(DaemonRemoval.unreachableNote.contains("sleepdisabled"),
                      DaemonRemoval.unreachableNote)
    }
}
