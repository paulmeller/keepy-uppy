import XCTest
@testable import KeepyUppy

final class CLICommandParsingTests: XCTestCase {
    func testBareOnIsIndefinite() {
        guard case .success(.on(let kind, let persistence, _)) = parseCLIArguments(["on"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .indefinite)
        XCTAssertEqual(persistence, .detached, "CLI sessions default to detached, spec §5")
    }

    func testOnForHours() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--for", "2h"]) else {
            return XCTFail("expected .on")
        }
        guard case .duration(let until) = kind else { return XCTFail("expected .duration") }
        // Can't assert an exact Date without injecting time into the
        // parser; assert the offset is right instead.
        XCTAssertEqual(until.timeIntervalSinceNow, 2 * 3600, accuracy: 2)
    }

    func testOnForMinutes() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--for", "30m"]) else {
            return XCTFail("expected .on")
        }
        guard case .duration(let until) = kind else { return XCTFail("expected .duration") }
        XCTAssertEqual(until.timeIntervalSinceNow, 30 * 60, accuracy: 2)
    }

    func testOnWhileApp() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-app", "com.apple.dt.Xcode"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
    }

    func testOnWhileProcess() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-process", "claude"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileProcessRunning(processName: "claude"))
    }

    func testOnRejectsMultipleEndConditions() {
        guard case .failure = parseCLIArguments(["on", "--for", "2h", "--while-app", "x"]) else {
            return XCTFail("expected failure — only one end condition allowed")
        }
    }

    func testOnRejectsWhileAppCombinedWithWhileProcess() {
        guard case .failure = parseCLIArguments(["on", "--while-app", "x", "--while-process", "claude"]) else {
            return XCTFail("expected failure — only one end condition allowed")
        }
    }

    func testOnRejectsMalformedDuration() {
        guard case .failure = parseCLIArguments(["on", "--for", "banana"]) else {
            return XCTFail("expected failure")
        }
    }

    func testOffAll() {
        guard case .success(.off(.all)) = parseCLIArguments(["off", "--all"]) else {
            return XCTFail("expected .off(.all)")
        }
    }

    func testOffSpecificSession() {
        guard case .success(.off(.session(let id))) = parseCLIArguments(["off", "--session", "abc-123"]) else {
            return XCTFail("expected .off(.session)")
        }
        XCTAssertEqual(id, "abc-123")
    }

    func testBareOffTargetsOwnSessions() {
        guard case .success(.off(.own)) = parseCLIArguments(["off"]) else {
            return XCTFail("expected .off(.own)")
        }
    }

    func testStatusJSON() {
        guard case .success(.status(let json)) = parseCLIArguments(["status", "--json"]) else {
            return XCTFail("expected .status(json: true)")
        }
        XCTAssertTrue(json)
    }

    func testSessions() {
        guard case .success(.sessions) = parseCLIArguments(["sessions"]) else {
            return XCTFail("expected .sessions")
        }
    }

    func testFinishedWithNoTool() {
        guard case .success(.finished(let tool)) = parseCLIArguments(["finished"]) else {
            return XCTFail("expected .finished")
        }
        XCTAssertNil(tool)
    }

    func testFinishedWithTool() {
        guard case .success(.finished(let tool)) = parseCLIArguments(["finished", "--tool", "claude-code"]) else {
            return XCTFail("expected .finished")
        }
        XCTAssertEqual(tool, "claude-code")
    }

    func testSetup() {
        guard case .success(.setup) = parseCLIArguments(["setup"]) else {
            return XCTFail("expected .setup")
        }
    }

    func testReset() {
        guard case .success(.reset) = parseCLIArguments(["reset"]) else {
            return XCTFail("expected .reset")
        }
    }

    func testUnknownCommandFails() {
        guard case .failure = parseCLIArguments(["frobnicate"]) else {
            return XCTFail("expected failure")
        }
    }

    func testEmptyArgumentsFails() {
        guard case .failure = parseCLIArguments([]) else {
            return XCTFail("expected failure")
        }
    }
}

/// The wake-mode axis of `on` (spec §1, plan 4): *when* a session ends and
/// *how* it keeps the Mac awake are orthogonal, and the CLI is where a user
/// first gets to choose the second one.
final class CLIWakeModeParsingTests: XCTestCase {
    /// The load-bearing default. `.clamshell` is the only mode that survives
    /// a lid close, and it is what every `keepy-uppy on` invocation written
    /// before these flags existed already got — every script, every README
    /// line, every `ssh mac-mini 'keepy-uppy on --for 8h'`. Absence meaning
    /// anything else would silently weaken all of them.
    func testBareOnIsClamshell() {
        guard case .success(.on(_, _, let wakeMode)) = parseCLIArguments(["on"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(wakeMode, .clamshell)
    }

    func testDisplayMaySleepSelectsSystemMode() {
        guard case .success(.on(_, _, let wakeMode)) = parseCLIArguments(["on", "--display-may-sleep"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(wakeMode, .system)
    }

    func testKeepDisplayAwakeSelectsSystemAndDisplayMode() {
        guard case .success(.on(_, _, let wakeMode)) = parseCLIArguments(["on", "--keep-display-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(wakeMode, .systemAndDisplay)
    }

    /// `WakeMode` is a flat three-case enum: one session holds exactly one
    /// mode, so asking for two is a contradiction to reject rather than a
    /// precedence rule to invent — the same call the end-condition flags
    /// already make.
    func testTheTwoDisplayFlagsAreMutuallyExclusive() {
        guard case .failure = parseCLIArguments(["on", "--display-may-sleep", "--keep-display-awake"]) else {
            return XCTFail("expected failure — a session has exactly one wake mode")
        }
    }

    /// The flags select a wake mode, not an end condition. Passing one must
    /// not consume the single end-condition slot, and must not stop `--for`
    /// from also being given.
    func testAWakeModeFlagIsNotAnEndCondition() {
        guard case .success(.on(let kind, _, let wakeMode)) =
                parseCLIArguments(["on", "--for", "2h", "--display-may-sleep"]) else {
            return XCTFail("expected .on — a wake-mode flag is not an end condition")
        }
        guard case .duration = kind else { return XCTFail("expected .duration") }
        XCTAssertEqual(wakeMode, .system)
    }

    func testAWakeModeFlagCombinesWithAConditionEndCondition() {
        guard case .success(.on(let kind, _, let wakeMode)) =
                parseCLIArguments(["on", "--while-process", "claude", "--keep-display-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileProcessRunning(processName: "claude"))
        XCTAssertEqual(wakeMode, .systemAndDisplay)
    }

    /// A wake-mode flag must not weaken the end-condition rejection either:
    /// two end conditions are still two end conditions.
    func testTwoEndConditionsAreStillRejectedAlongsideAWakeModeFlag() {
        guard case .failure = parseCLIArguments(["on", "--for", "2h", "--until", "17:00", "--display-may-sleep"]) else {
            return XCTFail("expected failure — only one end condition allowed")
        }
    }

    /// The surface must be able to express every mode the daemon can hold —
    /// otherwise a mode exists that no user can ever ask for. `CaseIterable`
    /// makes this fail the day a fourth case is added with no way to select
    /// it, rather than the day someone notices.
    func testEveryWakeModeIsReachableFromTheCommandLine() {
        let invocations = [[], ["--display-may-sleep"], ["--keep-display-awake"]]
        let reachable = Set(invocations.compactMap { flags -> WakeMode? in
            guard case .success(.on(_, _, let wakeMode)) = parseCLIArguments(["on"] + flags) else { return nil }
            return wakeMode
        })
        XCTAssertEqual(reachable, Set(WakeMode.allCases))
    }

    /// …and no more than that. The complement of the test above: three
    /// distinct invocations must not collapse onto two modes.
    func testEachInvocationSelectsADistinctMode() {
        let modes = [[], ["--display-may-sleep"], ["--keep-display-awake"]].compactMap { flags -> WakeMode? in
            guard case .success(.on(_, _, let wakeMode)) = parseCLIArguments(["on"] + flags) else { return nil }
            return wakeMode
        }
        XCTAssertEqual(Set(modes).count, modes.count, "two invocations selected the same mode")
    }
}
