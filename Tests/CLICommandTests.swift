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

/// `parseOn` reads its arguments in one left-to-right pass. Before it did,
/// every option ran its own `contains` scan, so nothing tracked which tokens
/// had already been spoken for and a single token could play two roles at
/// once.
final class CLIOnTokenisingTests: XCTestCase {
    private let valueTakingOptions = ["--for", "--until", "--while-app", "--while-process"]

    /// The bug in its original shape: `on --while-app --display-may-sleep`
    /// started a session watching a bundle id of "--display-may-sleep" *and*
    /// selected `.system`, from the same argument. Refused now — no value a
    /// human means to pass here starts with a hyphen.
    func testAFlagCannotDoubleAsAMissingOptionsValue() {
        for option in valueTakingOptions {
            for flag in WakeMode.selectingFlags {
                guard case .failure = parseCLIArguments(["on", option, flag]) else {
                    return XCTFail("'\(option) \(flag)' must be refused, not read as \(option)'s value")
                }
            }
        }
    }

    /// The same gap at the end of the line, where there is no next token at
    /// all: the option used to be silently ignored and an indefinite session
    /// started instead of the timed one that was asked for.
    func testAnOptionWithNoValueIsRefused() {
        for option in valueTakingOptions {
            guard case .failure = parseCLIArguments(["on", option]) else {
                return XCTFail("'\(option)' with no value must be refused")
            }
        }
    }

    /// A typo used to be accepted in silence, and silence here reads as "you
    /// got what you asked for" while the session runs in the stronger default
    /// mode the user was trying to move away from.
    func testAnUnknownOptionIsRefused() {
        guard case .failure = parseCLIArguments(["on", "--keep-dispaly-awake"]) else {
            return XCTFail("a misspelled flag must be refused rather than silently ignored")
        }
        guard case .failure = parseCLIArguments(["on", "--for", "2h", "--frobnicate"]) else {
            return XCTFail("an unknown option must be refused even alongside valid ones")
        }
    }

    /// The pass must not have made order significant: a wake-mode flag before
    /// an option is the same invocation as one after it.
    func testOptionsAndWakeModeFlagsCombineInEitherOrder() {
        for args in [["--keep-display-awake", "--while-app", "com.apple.dt.Xcode"],
                     ["--while-app", "com.apple.dt.Xcode", "--keep-display-awake"]] {
            guard case .success(.on(let kind, _, let wakeMode)) = parseCLIArguments(["on"] + args) else {
                return XCTFail("expected .on for \(args)")
            }
            XCTAssertEqual(kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
            XCTAssertEqual(wakeMode, .systemAndDisplay)
        }
    }
}

/// The wake-mode flag names, and the two strings the CLI prints about a mode.
/// Both strings are about the one fact the flag names leave out — that
/// choosing a display behaviour *gives up* the lid-closed guarantee — so both
/// are pinned against `requiresSleepDisabled`, which is that guarantee.
final class WakeModeCLISurfaceTests: XCTestCase {
    /// The flags are the user-facing surface: renaming one silently breaks
    /// every script and every documented invocation, so the literals are
    /// pinned here rather than left to be re-derived from the parser.
    func testTheFlagNamesArePinnedAndTheDefaultHasNone() {
        XCTAssertNil(WakeMode.clamshell.selectingFlag,
                     "the default mode is selected by absence — giving it a flag would make it optional")
        XCTAssertEqual(WakeMode.system.selectingFlag, "--display-may-sleep")
        XCTAssertEqual(WakeMode.systemAndDisplay.selectingFlag, "--keep-display-awake")
    }

    func testEveryFlagSelectsTheModeItNames() {
        for mode in WakeMode.allCases {
            guard let flag = mode.selectingFlag else { continue }
            XCTAssertEqual(WakeMode.selectedBy(flag: flag), mode)
            guard case .success(.on(_, _, let parsed)) = parseCLIArguments(["on", flag]) else {
                return XCTFail("'on \(flag)' should parse")
            }
            XCTAssertEqual(parsed, mode)
        }
    }

    /// The note `keepy-uppy on` prints to stderr. A mode that takes the
    /// lid-closed guarantee away must say so, naming the flag actually typed;
    /// the mode that keeps it has nothing to warn about and must stay quiet,
    /// or the note becomes noise on every single invocation.
    func testExactlyTheModesThatGiveUpTheLidGuaranteeCarryACaveat() {
        for mode in WakeMode.allCases {
            guard let caveat = mode.lidCloseCaveat else {
                XCTAssertTrue(mode.requiresSleepDisabled,
                              "\(mode.rawValue) gives up the lid-closed guarantee and says nothing about it")
                continue
            }
            XCTAssertFalse(mode.requiresSleepDisabled,
                           "\(mode.rawValue) keeps the lid-closed guarantee; warning about it would be false")
            XCTAssertTrue(caveat.contains(mode.selectingFlag ?? ""),
                          "the note must name the flag the user actually typed: \(caveat)")
            XCTAssertTrue(caveat.contains("lid closed"), "the note must say what is being given up: \(caveat)")
        }
    }

    /// The `keepy-uppy sessions` row. `status` answers a boolean that is true
    /// for every mode, so this listing is the only place the difference
    /// between a lid-safe session and one that is not can be seen.
    func testASessionRowSaysWhereItsModeStandsOnTheLid() {
        for mode in WakeMode.allCases {
            let text = mode.sessionListDescription
            XCTAssertTrue(text.hasPrefix(mode.rawValue),
                          "the row should lead with the mode's own name, as the README and spec call it: \(text)")
            XCTAssertEqual(text.contains("survives a lid close"), mode.requiresSleepDisabled,
                           "\(mode.rawValue)'s row disagrees with whether it actually survives a lid close")
            XCTAssertEqual(text.contains("no lid close"), !mode.requiresSleepDisabled,
                           "\(mode.rawValue)'s row disagrees with whether it actually survives a lid close")
        }
    }
}
