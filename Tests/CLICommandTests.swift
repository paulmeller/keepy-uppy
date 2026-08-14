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

    /// `--while-vpn` takes no value, for the reason `--while-display` does not:
    /// the condition is "any VPN", so there is nothing to name.
    func testOnWhileVPN() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-vpn"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileVPNActive)
    }

    /// …and because it takes none, the token after it stays available to be
    /// read as whatever it is. `on --while-vpn --keep-display-awake` is a VPN
    /// session in the screen-on mode, not a VPN session watching a flag.
    func testWhileVPNDoesNotSwallowTheNextToken() {
        guard case .success(.on(let kind, _, let power)) =
                parseCLIArguments(["on", "--while-vpn", "--keep-display-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileVPNActive)
        XCTAssertEqual(power.wakeMode, .systemAndDisplay)
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
                     ["--while-display", "--while-display"],
                     ["--while-vpn", "--while-subnet", "192.168.1.0/24"],
                     ["--while-vpn", "--while-vpn"]] {
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

/// `keepy-uppy mode` — the verb that changes what a session **already running**
/// asks of this Mac (Plan 8 Task 9).
///
/// The name reads against the verbs beside it (`on` / `off` / `mode` / `status`
/// / `sessions` / `finished` / `setup` / `reset`): a bare noun for the thing
/// being set, in a list where every other verb is one word, and the one word
/// people already use for this ("what mode is that session in?").
final class CLIModeParsingTests: XCTestCase {
    /// The whole verb, minimally: a named session and the default request.
    func testModeNamesASessionAndCarriesAWholeRequest() {
        guard case .success(.mode(let session, let power)) =
                parseCLIArguments(["mode", "--session", "abc-123"]) else {
            return XCTFail("expected .mode")
        }
        XCTAssertEqual(session, "abc-123")
        XCTAssertEqual(power, PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false),
                       "absent flags mean what they mean for `on`, because this verb sets the "
                       + "session's whole request rather than editing one axis of it")
    }

    /// **The reachability guard, one verb over from
    /// `testEveryWakeModeIsReachableFromTheCommandLine`.**
    ///
    /// Written over `WakeMode.allCases` × `keepsDisksAwake`, so a request the
    /// daemon can hold and this verb cannot express fails a test rather than
    /// lurking — the exact hole Plan 4 closed for `WakeMode` and Plan 5 for
    /// `TriggerConditionKind`, and the reason `SessionKind.Family` exists. A
    /// fourth axis on `PowerRequest` makes the expected set bigger than anything
    /// these invocations can produce, and this goes red.
    func testEveryPowerRequestIsReachableFromTheNewVerb() {
        let invocations = WakeMode.allCases.flatMap { mode -> [[String]] in
            let modeFlags = mode.selectingFlag.map { [$0] } ?? []
            return [modeFlags, modeFlags + [keepDisksAwakeFlag]]
        }
        let reachable = invocations.compactMap { flags -> PowerRequest? in
            guard case .success(.mode(_, let power)) =
                    parseCLIArguments(["mode", "--session", "abc-123"] + flags) else { return nil }
            return power
        }
        XCTAssertEqual(reachable.count, invocations.count, "an invocation was refused outright")

        for mode in WakeMode.allCases {
            for held in [false, true] {
                let wanted = PowerRequest(wakeMode: mode, keepsDisksAwake: held)
                XCTAssertTrue(reachable.contains(wanted),
                              "\(mode.rawValue)/disks=\(held) can be held by the daemon and asked "
                              + "for by nobody")
            }
        }
        // …and no more than that: distinct invocations must not collapse onto
        // the same request, the converse `testEachInvocationSelectsADistinctMode`
        // makes for `on`.
        for (index, request) in reachable.enumerated() {
            for other in reachable.dropFirst(index + 1) {
                XCTAssertNotEqual(request, other, "two invocations selected the same request")
            }
        }
    }

    /// **The flags are `on`'s flags, parsed by `on`'s code**, which is the whole
    /// of Step 1: a second list is how three `SessionKind`s became unreachable.
    /// Asked as an equivalence over every combination rather than by inspecting
    /// the parser, so a copied-and-diverged list fails here.
    func testTheseAreTheSameFlagsOnParses() {
        for mode in WakeMode.allCases {
            for held in [false, true] {
                let flags = (mode.selectingFlag.map { [$0] } ?? [])
                    + (held ? [keepDisksAwakeFlag] : [])
                guard case .success(.on(_, _, let fromOn)) = parseCLIArguments(["on"] + flags),
                      case .success(.mode(_, let fromMode)) =
                        parseCLIArguments(["mode", "--session", "abc-123"] + flags) else {
                    return XCTFail("'\(flags.joined(separator: " "))' is not accepted by both verbs")
                }
                XCTAssertEqual(fromMode, fromOn,
                               "\(flags.joined(separator: " ")) means something different to "
                               + "`mode` than it does to `on`")
            }
        }
    }

    /// **Absence is not a target here, unlike `off`.** There is no session this
    /// could default to, and a default of "all of mine" would turn a forgotten
    /// flag into a change to sessions nobody named.
    func testModeWithNoSessionIsRefusedRatherThanAppliedToAnything() {
        guard case .failure(let error) = parseCLIArguments(["mode"]) else {
            return XCTFail("expected failure — mode has no default target")
        }
        XCTAssertTrue(error.message.contains("--session"), error.message)

        guard case .failure = parseCLIArguments(["mode", "--display-may-sleep"]) else {
            return XCTFail("flags without a session must be refused too")
        }
    }

    /// A session's kind is fixed for its whole life, so an end-condition flag is
    /// not a request this verb could honour. Refused, rather than ignored — the
    /// rule every verb here follows since `off --sesion` stopped everything.
    func testAnEndConditionFlagIsRefusedRatherThanIgnored() {
        for flags in [["--for", "2h"], ["--while-display"], ["--until", "17:00"]] {
            guard case .failure = parseCLIArguments(["mode", "--session", "abc-123"] + flags) else {
                return XCTFail("'mode \(flags.joined(separator: " "))' must be refused: a "
                               + "session's kind cannot be changed")
            }
        }
    }

    func testModeRejectsTwoWakeModeFlagsAndARepeatedDiskFlag() {
        for flags in [["--display-may-sleep", "--keep-display-awake"],
                      [keepDisksAwakeFlag, keepDisksAwakeFlag],
                      ["--session", "a", "--session", "b"]] {
            guard case .failure = parseCLIArguments(["mode"] + flags) else {
                return XCTFail("'mode \(flags.joined(separator: " "))' must be refused")
            }
        }
    }

    /// `--session` with no value must not swallow the next flag — the failure
    /// `ArgumentScanner` exists for, checked on the verb whose value is a session
    /// id somebody pasted.
    func testASessionValueThatLooksLikeAFlagIsRefused() {
        guard case .failure(let error) =
                parseCLIArguments(["mode", "--session", "--display-may-sleep"]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("--display-may-sleep"),
                      "the message must name the token that was not taken: \(error.message)")
    }

    /// `mode`'s copy of `testTheUsageLineNamesTheDiskFlag`, and it carries the
    /// same weight: the usage line is the only list of this verb's options a user
    /// ever sees, and `--keep-disks-awake` is in neither exhaustive list it is
    /// built from.
    ///
    /// It also pins the sentence Step 1 asked for — the absent-flag rule stated
    /// where the user meets it — because the intuition it defeats ("leave the
    /// axis I didn't mention alone") is stronger on a verb that acts on something
    /// already running.
    func testTheUsageLineNamesEveryFlagThisVerbAcceptsAndTheAbsentFlagRule() {
        guard case .failure(let error) =
                parseCLIArguments(["mode", "--session", "abc-123", "--frobnicate"]) else {
            return XCTFail("expected an unknown option to be refused")
        }
        for flag in WakeMode.selectingFlags + [keepDisksAwakeFlag, "--session"] {
            XCTAssertTrue(error.message.contains(flag),
                          "`mode`'s usage line does not mention \(flag): \(error.message)")
        }
        XCTAssertTrue(error.message.contains("whole request"),
                      "the usage line must say that an absent flag is not \"leave that alone\": "
                      + error.message)
    }

    /// The verb list a user is shown when they mistype the verb itself. A verb
    /// missing from it is a verb nobody finds.
    func testTheCommandListNamesTheNewVerb() {
        guard case .failure(let error) = parseCLIArguments(["frobnicate"]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("mode"), error.message)
    }

    /// The sentence printed when this Mac's daemon is too old to be asked. It is
    /// in `Shared/` precisely so it can be read here — `CLI/main.swift` is not
    /// reachable from this target — and what matters is that it names both ways
    /// out, because they cost differently.
    func testTheOldDaemonNoteNamesBothWaysOut() {
        XCTAssertTrue(cliOldDaemonCannotChangeASessionNote.lowercased().contains("restart"),
                      cliOldDaemonCannotChangeASessionNote)
        XCTAssertTrue(cliOldDaemonCannotChangeASessionNote.lowercased().contains("stop the session"),
                      cliOldDaemonCannotChangeASessionNote)
        XCTAssertFalse(cliOldDaemonCannotChangeASessionNote.contains("this app"),
                       "a command-line tool is not \"this app\": "
                       + cliOldDaemonCannotChangeASessionNote)
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
        guard case .success(.on(_, _, let power)) = parseCLIArguments(["on"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(power.wakeMode, .clamshell)
    }

    func testDisplayMaySleepSelectsSystemMode() {
        guard case .success(.on(_, _, let power)) = parseCLIArguments(["on", "--display-may-sleep"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(power.wakeMode, .system)
    }

    func testKeepDisplayAwakeSelectsSystemAndDisplayMode() {
        guard case .success(.on(_, _, let power)) = parseCLIArguments(["on", "--keep-display-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(power.wakeMode, .systemAndDisplay)
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
        guard case .success(.on(let kind, _, let power)) =
                parseCLIArguments(["on", "--for", "2h", "--display-may-sleep"]) else {
            return XCTFail("expected .on — a wake-mode flag is not an end condition")
        }
        guard case .duration = kind else { return XCTFail("expected .duration") }
        XCTAssertEqual(power.wakeMode, .system)
    }

    func testAWakeModeFlagCombinesWithAConditionEndCondition() {
        guard case .success(.on(let kind, _, let power)) =
                parseCLIArguments(["on", "--while-process", "claude", "--keep-display-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileProcessRunning(processName: "claude"))
        XCTAssertEqual(power.wakeMode, .systemAndDisplay)
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
            guard case .success(.on(_, _, let power)) = parseCLIArguments(["on"] + flags) else { return nil }
            return power.wakeMode
        })
        XCTAssertEqual(reachable, Set(WakeMode.allCases))
    }

    /// …and no more than that. The complement of the test above: three
    /// distinct invocations must not collapse onto two modes.
    func testEachInvocationSelectsADistinctMode() {
        let modes = [[], ["--display-may-sleep"], ["--keep-display-awake"]].compactMap { flags -> WakeMode? in
            guard case .success(.on(_, _, let power)) = parseCLIArguments(["on"] + flags) else { return nil }
            return power.wakeMode
        }
        XCTAssertEqual(Set(modes).count, modes.count, "two invocations selected the same mode")
    }
}

/// `on`'s third axis: whether the session also holds attached disks out of
/// idle. An axis the daemon can hold and no client can ask for is dead code
/// that looks like a feature — three `SessionKind`s accumulated exactly that
/// way — and this is what stops the fourth.
final class CLIDiskAxisParsingTests: XCTestCase {
    /// Absence means `false`, matching the decode-time direction `Session`
    /// chose and for the same reason: nobody asked for it. Note this is the
    /// *opposite* direction from the wake-mode default, which is absence →
    /// strongest, because there absence would silently weaken every invocation
    /// written before the flags existed. Here there is nothing to weaken.
    func testKeepDisksAwakeIsSelectableAndAbsenceMeansFalse() {
        guard case .success(.on(_, _, let power)) = parseCLIArguments(["on"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertFalse(power.keepsDisksAwake, "nobody asked for the disks to be held")

        guard case .success(.on(_, _, let asked)) =
                parseCLIArguments(["on", "--keep-disks-awake"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertTrue(asked.keepsDisksAwake)
    }

    /// It is a **third axis, not a wake mode**, so it must not join the
    /// wake-mode `ExclusiveChoice`. `--display-may-sleep --keep-disks-awake` is
    /// a coherent request — "let the screen sleep, keep the backup drive spun
    /// up" — where `--display-may-sleep --keep-display-awake` is a contradiction
    /// and stays refused. Over `allCases`, so a fourth mode inherits it.
    func testTheDiskFlagCombinesWithEveryWakeModeFlag() {
        for mode in WakeMode.allCases {
            let flags = (mode.selectingFlag.map { [$0] } ?? []) + ["--keep-disks-awake"]
            guard case .success(.on(let kind, _, let power)) =
                    parseCLIArguments(["on"] + flags) else {
                return XCTFail("'on \(flags.joined(separator: " "))' must be accepted")
            }
            XCTAssertEqual(power.wakeMode, mode, flags.joined(separator: " "))
            XCTAssertTrue(power.keepsDisksAwake, flags.joined(separator: " "))
            XCTAssertEqual(kind, .indefinite,
                           "the disk flag must not consume the end-condition slot")
        }
    }

    /// A single-flag `ExclusiveChoice`, in the shape `--json` uses: only the
    /// duplicate branch is reachable, which is correct, because repeating a
    /// flag is the one way to give two of a group of one.
    func testTheDiskFlagStillCannotBeGivenTwice() {
        guard case .failure(let error) =
                parseCLIArguments(["on", "--keep-disks-awake", "--keep-disks-awake"]) else {
            return XCTFail("expected failure — the flag may only be given once")
        }
        XCTAssertTrue(error.message.contains("--keep-disks-awake"),
                      "the message must name the flag repeated: \(error.message)")
        for untyped in WakeMode.selectingFlags {
            XCTAssertFalse(error.message.contains(untyped),
                           "the message names \(untyped), which the user never typed: \(error.message)")
        }
    }

    /// **This test carries more weight than the usage-line test above it.**
    ///
    /// `onUsage` is otherwise built entirely from two exhaustive lists
    /// (`OnOption.allCases` and `WakeMode.selectingFlags`), and
    /// `OnOption.usageFragment`'s doc comment states what that buys: "a flag
    /// cannot be added and left out of it". `--keep-disks-awake` belongs to
    /// neither list — it is not an end condition and not a wake mode — so it is
    /// the first hand-concatenated fragment, and for this one flag the
    /// guarantee drops from structural to "a test covers it". This is that
    /// test. It is not a nice-to-have: a flag missing from the only list of
    /// `on`'s options a user ever sees is a flag nobody finds.
    func testTheUsageLineNamesTheDiskFlag() {
        guard case .failure(let error) = parseCLIArguments(["on", "--frobnicate"]) else {
            return XCTFail("expected an unknown option to be refused")
        }
        XCTAssertTrue(error.message.contains("--keep-disks-awake"),
                      "'on''s usage line does not mention --keep-disks-awake: \(error.message)")
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
            ["--while-volume", "Backup"], ["--while-subnet", "192.168.1.0/24"],
            ["--while-vpn"], ["--while-usb", "05ac:024f"],
            ["--while-schedule", "weekdays 09:00-18:00"],
        ]
        let reachable = Set(invocations.compactMap { flags -> SessionKind.Family? in
            guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on"] + flags) else { return nil }
            return kind.family
        })
        // `.lease` is the one deliberate exclusion: it is created by the XPC
        // lease/renew path, not by `on`, and there is no flag that should make one.
        XCTAssertEqual(reachable, Set(SessionKind.Family.allCases).subtracting([.lease]))
    }

    /// A volume name is taken verbatim, spaces and all: Finder names contain
    /// them ("Time Machine", "Backup 1") and this is matched exactly.
    func testVolumeNameIsTakenVerbatim() {
        guard case .success(.on(let kind, _, _)) =
                parseCLIArguments(["on", "--while-volume", "Time Machine"]) else {
            return XCTFail("expected a session kind")
        }
        XCTAssertEqual(kind, .whileVolumeMounted(name: "Time Machine"))
    }

    /// The block is stored as typed rather than normalized, matching
    /// `--while-app`'s bundle id: it is what `sessions` will print back, and
    /// `IPv4Subnet` masks the host bits when it matches, so the two cannot
    /// disagree.
    func testSubnetIsStoredExactlyAsTyped() {
        for typed in ["192.168.1.0/24", "192.168.1.50", "10.0.0.0/8"] {
            guard case .success(.on(let kind, _, _)) =
                    parseCLIArguments(["on", "--while-subnet", typed]) else {
                return XCTFail("'--while-subnet \(typed)' must be accepted")
            }
            XCTAssertEqual(kind, .whileOnSubnet(cidr: typed))
        }
    }

    /// Every way a person actually writes a USB pair parses to the same thing,
    /// and the stored form is a canonical `UInt16` pair rather than the text —
    /// so `05ac:024f`, `0x05AC:0x024F` and `5ac:24f` are one rule, not three.
    func testAUSBDeviceIsParsedHoweverItWasWritten() {
        for typed in ["05ac:024f", "0x05ac:0x024f", "0X05AC:0X024F", "5ac:24f", "05AC:024F"] {
            guard case .success(.on(let kind, _, _)) =
                    parseCLIArguments(["on", "--while-usb", typed]) else {
                return XCTFail("'--while-usb \(typed)' must be accepted")
            }
            XCTAssertEqual(kind, .whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f), typed)
        }
    }

    /// A pair that can never match is refused at the keyboard, for the reason
    /// an unparseable subnet is — and the message has to answer the question a
    /// user is actually stuck on, which is not "what shape" but "where do I
    /// find my device's IDs".
    func testUSBRejectsAValueThatCanNeverMatch() {
        for bad in ["05ac", "05ac:", ":024f", "zzzz:024f", "05ac024f", "12345:024f", "05ac:024f:0"] {
            guard case .failure(let error) = parseCLIArguments(["on", "--while-usb", bad]) else {
                return XCTFail("'--while-usb \(bad)' must be refused")
            }
            XCTAssertTrue(error.message.contains(bad), "the message must quote what was typed: \(error.message)")
            XCTAssertTrue(error.message.contains("05ac:024f"),
                          "the message must give a form that would work: \(error.message)")
            XCTAssertTrue(error.message.contains("system_profiler"),
                          "the message must say where to find the IDs: \(error.message)")
        }
    }

    /// `--while-usb`'s value contains a colon, which is the one thing about it
    /// that could confuse a wire-format consumer. `wireDescription`'s documented
    /// rule is "everything after the *first* colon", so splitting once gives the
    /// pair back whole.
    func testTheUSBWireDescriptionSurvivesASingleSplit() {
        let wire = SessionKind.whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f).wireDescription
        XCTAssertEqual(wire, "while-usb-device-present:0x05ac:0x024f")
        let halves = wire.split(separator: ":", maxSplits: 1)
        XCTAssertEqual(String(halves[0]), "while-usb-device-present")
        XCTAssertEqual(String(halves[1]), "0x05ac:0x024f")
        XCTAssertEqual(USBDeviceID(text: String(halves[1])),
                       USBDeviceID(vendorID: 0x05ac, productID: 0x024f),
                       "the value a consumer recovers must parse back to the pair")
    }

    /// A block that can never match is refused at the keyboard, exactly as an
    /// out-of-range CPU threshold is — the alternative is a session that will
    /// not end on its own condition, with nothing to say why.
    func testSubnetRejectsAValueThatCanNeverMatch() {
        for bad in ["192.168.1", "256.0.0.1", "192.168.1.0/33", "banana", "fe80::1/64"] {
            guard case .failure(let error) = parseCLIArguments(["on", "--while-subnet", bad]) else {
                return XCTFail("'--while-subnet \(bad)' must be refused")
            }
            XCTAssertTrue(error.message.contains(bad), "the message must quote what was typed: \(error.message)")
            XCTAssertTrue(error.message.contains("192.168.1.0/24"),
                          "the message must give a form that would work: \(error.message)")
        }
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
            guard case .success(.on(let kind, _, let power)) = parseCLIArguments(["on"] + args) else {
                return XCTFail("expected .on for \(args)")
            }
            XCTAssertEqual(kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
            XCTAssertEqual(power.wakeMode, .systemAndDisplay)
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
        // Hand-written because `OnOption` is private to the parser. It had
        // silently fallen two flags behind (`--while-volume`, `--while-subnet`)
        // by the time `--while-vpn` arrived, which is the failure this test is
        // about, one level up.
        for flag in ["--for", "--until", "--while-app", "--while-process",
                     "--while-display", "--while-ac-power", "--while-cpu-busy",
                     "--while-volume", "--while-subnet", "--while-vpn", "--while-usb"]
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
            guard case .success(.on(_, _, let power)) = parseCLIArguments(["on", flag]) else {
                return XCTFail("'on \(flag)' should parse")
            }
            XCTAssertEqual(power.wakeMode, mode)
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

    /// The same invisibility argument, one axis over: without this clause a
    /// `--keep-disks-awake` session prints exactly like one without it, in the
    /// one listing whose job is to say what each session asked for.
    ///
    /// Annotating the exception, so the common row is byte-for-byte what it was
    /// — stated as an equality rather than a substring, so a clause leaking onto
    /// every row fails here.
    func testASessionRowSaysWhenTheSessionAlsoHoldsDisksAwake() {
        for mode in WakeMode.allCases {
            let plain = PowerRequest(wakeMode: mode, keepsDisksAwake: false)
            XCTAssertEqual(plain.sessionListDescription, mode.sessionListDescription,
                           "a session that asked nothing of the disks reads exactly as before")

            let holding = PowerRequest(wakeMode: mode, keepsDisksAwake: true)
            XCTAssertTrue(holding.sessionListDescription.hasPrefix(mode.sessionListDescription),
                          "the mode still leads: \(holding.sessionListDescription)")
            XCTAssertTrue(holding.sessionListDescription.contains("disks"),
                          holding.sessionListDescription)
        }
    }
}
