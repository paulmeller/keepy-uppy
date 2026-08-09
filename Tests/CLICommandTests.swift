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

    func testOnWhileExternalDisplay() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-display"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileExternalDisplay)
    }

    func testOnWhileOnACPower() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-ac-power"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileOnACPower)
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

    /// The three flags added last join the same exclusive group, including the
    /// two that take no value — a valueless flag is still an end condition, and
    /// a session has exactly one.
    func testOnRejectsTheValuelessEndConditionsCombinedWithAnother() {
        for args in [["--for", "2h", "--while-display"],
                     ["--while-ac-power", "--while-cpu-busy", "30"],
                     ["--while-display", "--while-ac-power"],
                     ["--while-display", "--while-display"]] {
            guard case .failure = parseCLIArguments(["on"] + args) else {
                return XCTFail("'on \(args.joined(separator: " "))' must be refused — one end condition")
            }
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

/// `on`'s *first* axis — when the session ends — held the same hole the wake
/// mode axis did, one level up and three cases wide: `.whileExternalDisplay`,
/// `.whileOnACPower` and `.whileCPUBusy` were kinds the daemon evaluated and no
/// client could ask for. Nothing linked `CLICommand`'s flag list to
/// `SessionKind`, so each of them compiled, shipped and did nothing.
final class CLISessionKindReachabilityTests: XCTestCase {
    /// The `WakeMode` reachability test, one level up. A kind the daemon can hold
    /// and no client can ask for is dead code that looks like a feature — three of
    /// them accumulated unnoticed. `Family` is `CaseIterable`, so this fails the day
    /// a tenth kind is added with no way to select it.
    func testEverySessionKindIsReachableFromTheCommandLine() {
        let invocations: [[String]] = [
            [], ["--for", "2h"], ["--until", "17:00"],
            ["--while-app", "com.apple.dt.Xcode"], ["--while-process", "claude"],
            ["--while-display"], ["--while-ac-power"], ["--while-cpu-busy", "30"],
        ]
        let reachable = Set(invocations.compactMap { flags -> SessionKind.Family? in
            guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on"] + flags) else { return nil }
            return kind.family
        })
        // `.lease` is the one deliberate exclusion: it is created by the XPC
        // lease/renew path, not by `on`, and there is no flag that should make one.
        XCTAssertEqual(reachable, Set(SessionKind.Family.allCases).subtracting([.lease]))
    }

    func testCPUBusyThresholdIsParsedAsAPercentage() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-cpu-busy", "30"]) else {
            return XCTFail("expected a session kind")
        }
        XCTAssertEqual(kind, .whileCPUBusy(threshold: 0.30))
    }

    /// `"0.3"` is in this list on purpose: the flag takes a **percentage**
    /// (`30`), not a fraction, so `0.3` means 0.3% — a threshold the CPU can
    /// never fall below, i.e. a session that never ends. `0` and `100` are the
    /// two ends of the same argument: `CPUBusyWindow` ends a session once load
    /// stays *below* the threshold, so `0` can never end and `100` ends after
    /// two minutes of anything short of a pegged CPU.
    func testCPUBusyRejectsAThresholdOutsideItsRange() {
        for bad in ["0", "100", "-5", "banana", "0.3"] {
            guard case .failure = parseCLIArguments(["on", "--while-cpu-busy", bad]) else {
                return XCTFail("'--while-cpu-busy \(bad)' must be refused")
            }
        }
    }

    /// The two ends that must still be accepted, so the rejection above is a
    /// bound rather than a moat.
    func testCPUBusyAcceptsBothEndsOfItsRange() {
        for (percentage, threshold) in [("1", 0.01), ("99", 0.99)] {
            guard case .success(.on(let kind, _, _)) =
                    parseCLIArguments(["on", "--while-cpu-busy", percentage]) else {
                return XCTFail("'--while-cpu-busy \(percentage)' must be accepted")
            }
            XCTAssertEqual(kind, .whileCPUBusy(threshold: threshold))
        }
    }

    /// A rejected threshold has to say what to type instead — "0.3" is the case
    /// where the user believes they gave a perfectly good number.
    func testARejectedThresholdNamesTheValueAndTheRange() {
        guard case .failure(let error) = parseCLIArguments(["on", "--while-cpu-busy", "0.3"]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("0.3"), "the message must quote what was typed: \(error.message)")
        XCTAssertTrue(error.message.contains("1 to 99"),
                      "the message must give the range that would work: \(error.message)")
    }
}

/// `parseOn` reads its arguments in one left-to-right pass. Before it did,
/// every option ran its own `contains` scan, so nothing tracked which tokens
/// had already been spoken for and a single token could play two roles at
/// once.
final class CLIOnTokenisingTests: XCTestCase {
    private let valueTakingOptions = ["--for", "--until", "--while-app", "--while-process",
                                      "--while-cpu-busy"]

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

/// The same three rules, on the verbs that did not get them when `on` did:
/// a token is read once, a value that is missing or flag-shaped is refused,
/// and an unrecognised token is an error.
///
/// Strictness on `on` alone was the worse of the two inconsistent states,
/// because the verb left permissive is the one where a typo *widens* what
/// happens rather than narrowing it.
final class CLIStrictnessAcrossVerbsTests: XCTestCase {
    private func assertRefused(_ args: [String], _ why: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure = parseCLIArguments(args) else {
            return XCTFail("'keepy-uppy \(args.joined(separator: " "))' must be refused — \(why)",
                           file: file, line: line)
        }
    }

    /// The finding in its worst shape. One mistyped character used to turn
    /// "stop the session I named" into "stop every session I own", silently
    /// and with a zero exit status, because an unrecognised `--sesion` left no
    /// target and no target means `.own`.
    func testAMistypedSessionFlagDoesNotSilentlyWidenOffToEverySessionYouOwn() {
        guard case .failure = parseCLIArguments(["off", "--sesion", "abc-123"]) else {
            return XCTFail("'off --sesion abc-123' must be refused, not read as 'stop all of mine'")
        }
        // What it used to become, still reachable when it is what was meant.
        guard case .success(.off(.own)) = parseCLIArguments(["off"]) else {
            return XCTFail("bare 'off' must still target the caller's own sessions")
        }
    }

    func testOffRejectsUnrecognisedArguments() {
        assertRefused(["off", "--alll"], "a misspelled --all is not --all")
        assertRefused(["off", "--json"], "--json is another verb's option")
        assertRefused(["off", "abc-123"], "a bare session id is not a target; --session names one")
    }

    func testOffRefusesASessionIdThatIsMissingOrLooksLikeAFlag() {
        assertRefused(["off", "--session"], "no id follows")
        assertRefused(["off", "--session", "--all"], "--all is a flag, not the id of a session to stop")
    }

    /// A stop has exactly one target, so two of them is a contradiction —
    /// `--all` used to win silently over an explicitly named session.
    func testOffRejectsTwoTargets() {
        assertRefused(["off", "--all", "--session", "abc-123"], "stop everything, or stop that one?")
        assertRefused(["off", "--session", "abc-123", "--all"], "order must not decide which target wins")
        assertRefused(["off", "--all", "--all"], "an option given twice is a mistake, not emphasis")
        assertRefused(["off", "--session", "abc-123", "--session", "def-456"], "two named sessions")
    }

    /// `status --jsno` printed prose to a script that asked for JSON, which
    /// then parsed it.
    func testStatusRejectsUnrecognisedAndRepeatedOptions() {
        assertRefused(["status", "--jsno"], "a misspelled --json must not silently print prose")
        assertRefused(["status", "--json", "--json"], "an option given twice is a mistake")
        assertRefused(["status", "--all"], "--all is another verb's option")
    }

    /// The tool name rides along into the user's script env / webhook JSON, so
    /// dropping it silently produces a completion event from nowhere in
    /// particular.
    func testFinishedRejectsUnrecognisedMissingAndRepeatedTools() {
        assertRefused(["finished", "--tol", "claude-code"], "a misspelled --tool must not drop the name")
        assertRefused(["finished", "--tool"], "no name follows")
        assertRefused(["finished", "--tool", "--json"], "a flag is not a tool name")
        assertRefused(["finished", "--tool", "a", "--tool", "b"], "which tool finished?")
    }

    /// These three take no options at all, so every argument is an unknown
    /// one. They cannot lose work the way `off` can; they are here so that
    /// "does this verb notice a typo?" has one answer across the whole CLI
    /// rather than a per-verb one.
    func testTheVerbsWithNoOptionsRejectArguments() {
        for verb in ["sessions", "setup", "reset"] {
            assertRefused([verb, "--json"], "\(verb) has no options")
        }
    }

    /// The other half of the change: strictness must only cost typos. Every
    /// well-formed invocation of these verbs still parses to exactly what it
    /// did before. (`on`'s well-formed invocations are covered above.)
    func testEveryWellFormedInvocationStillParsesUnchanged() {
        let expected: [([String], CLICommand)] = [
            (["off"], .off(.own)),
            (["off", "--all"], .off(.all)),
            (["off", "--session", "abc-123"], .off(.session("abc-123"))),
            (["status"], .status(json: false)),
            (["status", "--json"], .status(json: true)),
            (["sessions"], .sessions),
            (["finished"], .finished(tool: nil)),
            (["finished", "--tool", "claude-code"], .finished(tool: "claude-code")),
            (["setup"], .setup),
            (["reset"], .reset),
        ]
        for (args, command) in expected {
            guard case .success(let parsed) = parseCLIArguments(args) else {
                return XCTFail("'keepy-uppy \(args.joined(separator: " "))' must still parse")
            }
            XCTAssertEqual(parsed, command)
        }
    }
}

/// A rejection is only useful if it says what to type instead. These pin the
/// two messages that described something other than what the user did.
final class CLIRejectionMessageTests: XCTestCase {
    private func rejection(_ args: [String],
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .failure(let error) = parseCLIArguments(args) else {
            XCTFail("expected '\(args.joined(separator: " "))' to be refused", file: file, line: line)
            return ""
        }
        return error.message
    }

    /// "--while-process needs a value" flatly contradicts a command line with
    /// a value on it. The value is there; it is the *shape* that was refused.
    func testAFlagShapedValueIsReportedAsWhatItIs() {
        let message = rejection(["on", "--while-process", "-bash"])
        XCTAssertTrue(message.contains("-bash"), "the message must name the token refused: \(message)")
        XCTAssertTrue(message.contains("looks like a flag"),
                      "the message must say why it was refused, not just 'needs a value': \(message)")
    }

    /// Naming the whole group for a repeat sends the user hunting for a
    /// conflict with options they never typed.
    func testTheSameOptionTwiceIsReportedAsARepeat() {
        let message = rejection(["on", "--for", "2h", "--for", "3h"])
        XCTAssertTrue(message.contains("--for"), "the message must name the option repeated: \(message)")
        for untyped in ["--until", "--while-app", "--while-process"] {
            XCTAssertFalse(message.contains(untyped),
                           "the message names \(untyped), which does not appear in the command: \(message)")
        }

        let modeMessage = rejection(["on", "--display-may-sleep", "--display-may-sleep"])
        XCTAssertTrue(modeMessage.contains("--display-may-sleep"))
        XCTAssertFalse(modeMessage.contains("--keep-display-awake"),
                       "the message names a flag the user never typed: \(modeMessage)")
    }

    /// The complement: two *different* options from one group is exactly when
    /// naming the group is the right thing to do.
    func testTwoDifferentOptionsFromOneGroupStillNameTheGroup() {
        let message = rejection(["on", "--for", "2h", "--until", "17:00"])
        XCTAssertTrue(message.contains("--for") && message.contains("--until"),
                      "a genuine conflict should name the conflicting options: \(message)")
    }

    /// A flag that works but is not in the usage line is only half-added. That
    /// line is the only list of `on`'s options the CLI ever prints, so a flag
    /// missing from it is one nobody finds — a milder version of the kind
    /// nobody could ask for.
    func testTheUsageLineAdvertisesEveryOptionOnAccepts() {
        let message = rejection(["on", "--frobnicate"])
        for flag in ["--for", "--until", "--while-app", "--while-process",
                     "--while-display", "--while-ac-power", "--while-cpu-busy"]
                    + WakeMode.selectingFlags {
            XCTAssertTrue(message.contains(flag), "'on''s usage line does not mention \(flag): \(message)")
        }
    }

    /// An unknown option is only actionable if the user can see which
    /// command's option list it was looked up in.
    func testAnUnknownOptionNamesTheVerbAndItsUsage() {
        let message = rejection(["off", "--alll"])
        XCTAssertTrue(message.contains("--alll"), "the message must quote the token: \(message)")
        XCTAssertTrue(message.contains("'off'"), "the message must name the verb: \(message)")
        XCTAssertTrue(message.contains("usage: keepy-uppy off"),
                      "the message must carry the verb's usage line: \(message)")
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

    /// The note is about the session being started, not about the Mac.
    ///
    /// The daemon unions the wake modes of every live session, so a concurrent
    /// `.clamshell` session — another client's, or this user's own earlier one
    /// — does keep the machine awake with the lid shut. "This flag does not
    /// keep this Mac awake with the lid closed" was therefore false exactly
    /// when someone was running two sessions at once. Scoped to the session,
    /// the same sentence is true unconditionally.
    func testTheCaveatIsScopedToTheSessionAndNotToTheWholeMac() {
        for mode in WakeMode.allCases {
            guard let caveat = mode.lidCloseCaveat else { continue }
            XCTAssertTrue(caveat.contains("this session"),
                          "a concurrent clamshell session does keep this Mac awake lid-shut, so the note "
                          + "has to be about the session being started: \(caveat)")
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
            XCTAssertEqual(text.contains("does not survive a lid close"), !mode.requiresSleepDisabled,
                           "\(mode.rawValue)'s row disagrees with whether it actually survives a lid close")
        }
    }

    /// Every row is a statement about the session it describes, never about the
    /// Mac — the same rule `lidCloseCaveat` follows, and for the same reason.
    /// The daemon unions the modes of every live session, so "no lid close" as
    /// a bare fact about the machine was false the moment a `.clamshell`
    /// session was live alongside — which is exactly when someone runs
    /// `keepy-uppy sessions`.
    func testEachRowIsScopedToItsOwnSessionAndNotToTheWholeMac() {
        for mode in WakeMode.allCases {
            XCTAssertTrue(mode.sessionListDescription.contains("this session"),
                          "a concurrent clamshell session changes what is true of the Mac but not of "
                          + "this one, so the row has to say which it means: \(mode.sessionListDescription)")
        }
    }
}
