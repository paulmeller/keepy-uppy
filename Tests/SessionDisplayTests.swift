import XCTest
@testable import KeepyUppy

final class SessionDisplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ kind: SessionKind, origin: SessionOrigin = .manual) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"),
               persistence: .clientBound, origin: origin, startedAt: t0)
    }

    func testIndefiniteHasNoRemainingTimeText() {
        XCTAssertEqual(remainingTimeText(for: session(.indefinite), now: t0), "Indefinite")
    }

    func testDurationShowsRoundedMinutesRemaining() {
        let s = session(.duration(until: t0.addingTimeInterval(90 * 60)))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "1h 30m left")
    }

    func testDurationUnderAnHourShowsMinutesOnly() {
        let s = session(.duration(until: t0.addingTimeInterval(45 * 60)))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "45m left")
    }

    func testWhileAppRunningShowsTheAppCondition() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While Xcode is running")
    }

    func testWhileExternalDisplayShowsItsCondition() {
        XCTAssertEqual(remainingTimeText(for: session(.whileExternalDisplay), now: t0), "While an external display is connected")
    }

    func testWhileProcessRunningShowsTheProcessCondition() {
        let s = session(.whileProcessRunning(processName: "claude"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While claude is running")
    }

    func testOriginTextDistinguishesManualAndTrigger() {
        XCTAssertEqual(originText(for: session(.indefinite, origin: .manual)), "Started manually")
        XCTAssertEqual(originText(for: session(.indefinite, origin: .trigger)), "Started automatically")
    }

    func testDefaultSessionKindMapsToRealSessionKind() {
        XCTAssertEqual(DefaultSessionKind.indefinite.sessionKind(now: t0), .indefinite)
        XCTAssertEqual(DefaultSessionKind.oneHour.sessionKind(now: t0), .duration(until: t0.addingTimeInterval(3600)))
    }
}

/// The trigger row's copy is load-bearing: it is the only place the UI
/// explains what a trigger will do, and a redesign once shipped wording
/// ("While it's running — keep awake indefinitely") that promised a stop the
/// system never performs. These pin the semantics, not the prose.
final class TriggerCopyTests: XCTestCase {
    private func rule(_ condition: TriggerCondition, _ kind: DefaultSessionKind) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, defaultKind: kind, enabled: true)
    }

    func testConditionTitlesDescribeTheStartingEventNotAnOngoingState() {
        // "when … connects", never "while … is connected": a trigger starts a
        // session, and nothing ends it when the condition goes away.
        XCTAssertEqual(triggerConditionTitle(.externalDisplayConnected), "When an external display connects")
        XCTAssertEqual(triggerConditionTitle(.acPowerConnected), "When power is connected")
        for condition: TriggerCondition in [.externalDisplayConnected, .acPowerConnected,
                                            .appLaunched(bundleID: "com.apple.dt.Xcode")] {
            let title = triggerConditionTitle(condition).lowercased()
            XCTAssertTrue(title.hasPrefix("when "), "\(title) should describe an event")
            XCTAssertFalse(title.contains("while "), "\(title) must not imply a condition-bound lifetime")
        }
    }

    func testEffectSubtitleNeverImpliesTheSessionEndsWithTheCondition() {
        for kind in DefaultSessionKind.allCases {
            let subtitle = triggerEffectSubtitle(rule(.externalDisplayConnected, kind)).lowercased()
            XCTAssertTrue(subtitle.hasPrefix("starts a session"),
                          "\(subtitle) should say what firing does")
            XCTAssertFalse(subtitle.contains("while "),
                           "\(subtitle) must not promise a stop the evidence loop never performs")
        }
    }

    func testEffectSubtitleReportsTheKindThatWillActuallyBeStarted() {
        XCTAssertTrue(triggerEffectSubtitle(rule(.acPowerConnected, .fourHours)).contains("for 4 hours"))
        XCTAssertTrue(triggerEffectSubtitle(rule(.acPowerConnected, .indefinite)).contains("indefinitely"))
    }

    /// The deliberate exception to both invariants above: `.processRunning`
    /// is the one condition whose fired session genuinely does end when the
    /// condition goes away (`TriggerRule.sessionKind(firing:now:)` ignores
    /// `defaultKind` for it and always ends on process exit), so it's the
    /// one condition allowed — expected — to say "while".
    func testProcessRunningIsTheDeliberateExceptionAndDoesSayWhile() {
        let title = triggerConditionTitle(.processRunning(processName: "claude")).lowercased()
        XCTAssertTrue(title.contains("while "), "\(title) should say \"while\" — this condition actually does bind the session's lifetime")

        let subtitle = triggerEffectSubtitle(rule(.processRunning(processName: "claude"), .fourHours)).lowercased()
        XCTAssertTrue(subtitle.contains("claude"))
        XCTAssertFalse(subtitle.contains("4 hours"), "defaultKind must be ignored for a process-running rule")
    }
}

final class SafetyCopyTests: XCTestCase {
    func testBatteryFootnoteReportsTheGuardIsOffWhenItIs() {
        var config = SafetyConfig.default
        config.batteryCutoff = nil
        XCTAssertTrue(batteryGuardFootnote(config).lowercased().contains("off"))
        // Must not invent a threshold for a guard that isn't running.
        XCTAssertFalse(batteryGuardFootnote(config).contains("0%"))
    }

    func testBatteryFootnoteQuotesTheEngineSEffectiveLidClosedThreshold() {
        var config = SafetyConfig.default
        config.batteryCutoff = 10
        config.lidClosedStricter = true
        let footnote = batteryGuardFootnote(config)
        XCTAssertTrue(footnote.contains("10%"))
        // Derived from SafetyConfig, so it cannot drift from what breach() applies.
        XCTAssertTrue(footnote.contains("\(10 + SafetyConfig.lidClosedMargin)%"))
    }

    func testBatteryFootnoteQuotesOneThresholdWhenTheLidRuleIsOff() {
        var config = SafetyConfig.default
        config.batteryCutoff = 10
        config.lidClosedStricter = false
        XCTAssertFalse(batteryGuardFootnote(config).contains("15%"))
    }

    func testEveryThermalLevelExplainsItself() {
        for level in ThermalSensitivity.allCases {
            XCTAssertFalse(thermalSensitivityTitle(level).isEmpty)
            XCTAssertGreaterThan(thermalSensitivityExplanation(level).count, 40,
                                 "\(level) needs a real explanation, not a restated label")
        }
    }
}

final class EffectiveBatteryCutoffTests: XCTestCase {
    func testNilCutoffMeansTheGuardIsOffRegardlessOfLid() {
        var config = SafetyConfig.default
        config.batteryCutoff = nil
        XCTAssertNil(config.effectiveBatteryCutoff(lidClosed: false))
        XCTAssertNil(config.effectiveBatteryCutoff(lidClosed: true))
    }

    func testLidClosedAddsTheMarginOnlyWhenStricterIsOn() {
        var config = SafetyConfig.default
        config.batteryCutoff = 10
        config.lidClosedStricter = true
        XCTAssertEqual(config.effectiveBatteryCutoff(lidClosed: false), 10)
        XCTAssertEqual(config.effectiveBatteryCutoff(lidClosed: true), 10 + SafetyConfig.lidClosedMargin)

        config.lidClosedStricter = false
        XCTAssertEqual(config.effectiveBatteryCutoff(lidClosed: true), 10)
    }
}

/// The menu is the only surface most people ever see, and its previous
/// wording — "Indefinite — Started manually — Stop" — hid the verb behind two
/// pieces of trivia on a row that was secretly a button. These pin the shape
/// that replaced it.
final class MenuCopyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let mineID = ClientID(rawValue: "app-501")
    private let theirsID = ClientID(rawValue: "cli-501")

    private func session(_ kind: SessionKind, owner: ClientID, origin: SessionOrigin = .manual) -> Session {
        Session(id: UUID(), kind: kind, owner: owner, persistence: .clientBound,
                origin: origin, startedAt: t0)
    }

    func testIdleSaysSoPlainly() {
        XCTAssertEqual(menuStatusLine(mine: [], others: [], now: t0), "Not keeping awake")
    }

    func testOneSessionNamesWhatItIsRatherThanCountingIt() {
        let line = menuStatusLine(mine: [session(.indefinite, owner: mineID)], others: [], now: t0)
        XCTAssertEqual(line, "Keeping awake — indefinite")
    }

    func testStatusDistinguishesSessionsYouCannotStop() {
        let line = menuStatusLine(mine: [session(.indefinite, owner: mineID)],
                                  others: [session(.indefinite, owner: theirsID)], now: t0)
        XCTAssertTrue(line.contains("2 sessions"))
        XCTAssertTrue(line.contains("1 yours"), "the menu must say how many are actually yours: \(line)")

        let noneMine = menuStatusLine(mine: [], others: [session(.indefinite, owner: theirsID),
                                                        session(.indefinite, owner: theirsID)], now: t0)
        XCTAssertTrue(noneMine.contains("none yours"), noneMine)
    }

    func testTheStopLabelLeadsWithTheVerb() {
        for label in [menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfMine: true, now: t0),
                      menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfMine: false, now: t0)] {
            XCTAssertTrue(label.hasPrefix("Stop"), "\(label) must read as an action, not a status")
        }
    }

    func testASingleSessionNeedsNoDescriptionQuotedBackAtYou() {
        XCTAssertEqual(
            menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfMine: true, now: t0),
            "Stop keeping awake")
    }

    func testSeveralSessionsAreDistinguishableFromEachOther() {
        let timed = session(.duration(until: t0.addingTimeInterval(3600)), owner: mineID)
        let label = menuStopLabel(for: timed, isOnlyOneOfMine: false, now: t0)
        XCTAssertNotEqual(label, "Stop keeping awake")
        XCTAssertTrue(label.contains("1h"), label)
    }

    func testOriginIsMentionedOnlyWhenItIsSurprising() {
        // "Started manually" on a session you started by hand is noise; the
        // automatic case is the one worth a word.
        XCTAssertEqual(menuAutomaticSuffix(for: session(.indefinite, owner: mineID, origin: .manual)), "")
        XCTAssertTrue(menuAutomaticSuffix(for: session(.indefinite, owner: mineID, origin: .trigger))
            .contains("automatically"))
    }

    func testForeignSessionsSayWhyTheyCannotBeStopped() {
        let label = menuForeignSessionLabel(for: session(.indefinite, owner: theirsID), now: t0)
        XCTAssertFalse(label.hasPrefix("Stop"), "not a button — this app cannot stop it: \(label)")
        XCTAssertTrue(label.contains("elsewhere"), label)
    }

    func testStartLabelsReadAsInstructionsNotNouns() {
        // In the default mode — the only one that existed when these were
        // written — the label is exactly what it always was. That is the
        // "annotate the exception, not the rule" claim, stated as an equality
        // rather than a substring so a tag leaking onto the common case fails
        // here.
        XCTAssertEqual(menuStartLabel(.indefinite, wakeMode: .clamshell), "Keep awake indefinitely")
        XCTAssertEqual(menuStartLabel(.oneHour, wakeMode: .clamshell), "Keep awake for 1 hour")
        XCTAssertEqual(menuStartLabel(.eightHours, wakeMode: .clamshell), "Keep awake for 8 hours")
    }
}

/// Plan 4 Task 5: the menu and Settings surface of `WakeMode`.
///
/// The CLI's equivalents (`WakeMode.sessionListDescription`, `.lidCloseCaveat`
/// in `Shared/CLICommand.swift`, pinned by `WakeModeCLISurfaceTests`) say the
/// same things in a different register — a terminal can afford a full sentence
/// per row, a menu cannot — so these are deliberately separate strings with
/// their own tests rather than one string stretched over two surfaces.
///
/// Every assertion below is pinned against `requiresSleepDisabled` or against
/// `PowerPlan.reduce`, never against a hard-coded list of modes, so a fourth
/// `WakeMode` cannot be added without this file forcing a decision about it.
final class WakeModeMenuCopyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let mineID = ClientID(rawValue: "app-501")
    private let theirsID = ClientID(rawValue: "cli-501")

    private func session(_ mode: WakeMode, owner: ClientID? = nil,
                         kind: SessionKind = .indefinite) -> Session {
        Session(id: UUID(), kind: kind, owner: owner ?? mineID, persistence: .clientBound,
                origin: .manual, startedAt: t0, wakeMode: mode)
    }

    // MARK: - The per-session tag

    /// The whole design decision, as a test: `.clamshell` is the default, the
    /// strongest mode, and what almost every session in existence is. Tagging
    /// it would put a badge on every row of a menu that was redesigned this
    /// week *because* it had too much on each row.
    func testExactlyTheNonDefaultModesAreTagged() {
        for mode in WakeMode.allCases {
            XCTAssertEqual(menuWakeModeTag(mode) == nil, mode.requiresSleepDisabled,
                           "\(mode.rawValue): the mode that survives a lid close is the rule and goes "
                           + "untagged; every other mode is the exception and must be visible")
        }
    }

    /// The two tagged modes differ from each other only in what the *display*
    /// does — `.clamshell` and `.system` are identical on that axis, since
    /// neither holds `preventIdleDisplaySleep` (`PowerPlan.reduce`). So the
    /// fact a tag has to carry is the lid, not the screen: a tag reading only
    /// "display may sleep" would imply a difference from the default that does
    /// not exist.
    func testEveryTagNamesTheLidBecauseThatIsWhatTheseModesActuallyGiveUp() {
        for mode in WakeMode.allCases {
            guard let tag = menuWakeModeTag(mode) else { continue }
            XCTAssertTrue(tag.contains("lid"),
                          "\(mode.rawValue)'s tag must name the axis it differs on: \(tag)")
        }
    }

    func testOnlyTheScreenHoldingModeMentionsTheScreen() {
        for mode in WakeMode.allCases {
            guard let tag = menuWakeModeTag(mode) else { continue }
            XCTAssertEqual(tag.contains("screen"), mode.holdsDisplayAwake,
                           "\(mode.rawValue)'s tag disagrees with whether it holds the display awake: \(tag)")
        }
    }

    /// A row describes one session. The daemon unions every live session's mode
    /// (`PowerPlan.reduce`), so a concurrent `.clamshell` session really does
    /// keep the machine awake lid-shut no matter what this row's session asked
    /// for — the exact bug the Task 4 stderr caveat shipped with. A tag that
    /// said "this Mac will sleep" would be false precisely when two sessions
    /// are running, which is when someone is most likely to be reading it.
    func testNoTagMakesAClaimAboutTheWholeMac() {
        for mode in WakeMode.allCases {
            guard let tag = menuWakeModeTag(mode) else { continue }
            XCTAssertFalse(tag.lowercased().contains("mac"),
                           "a per-session tag cannot assert a machine-wide fact: \(tag)")
            XCTAssertFalse(tag.lowercased().contains("will sleep"),
                           "a per-session tag cannot assert a machine-wide fact: \(tag)")
        }
    }

    // MARK: - Where the tag actually appears

    /// The tag has to follow a *noun*. "Stop keeping awake (lid open only)" is
    /// an imperative followed by a parenthetical that grammatically attaches to
    /// the verb, so it can be read as "stop only while the lid is open" — a
    /// condition on the button instead of a fact about the session. It is worst
    /// in the mixed case (`testAConcurrentDefaultSessionSuppressesTheLidLine`),
    /// where a concurrent clamshell session correctly suppresses `menuLidCaveat`
    /// and this row is the only mode signal on screen, with nothing above it to
    /// prime the meaning. The multi-session form is exempt: its parenthetical
    /// follows a quoted description, which a tag can only qualify.
    func testTheStopButtonCarriesItsSessionSMode() {
        let plain = menuStopLabel(for: session(.clamshell), isOnlyOneOfMine: true, now: t0)
        XCTAssertEqual(plain, "Stop keeping awake", "the default mode adds nothing")

        let tagged = menuStopLabel(for: session(.system), isOnlyOneOfMine: true, now: t0)
        XCTAssertEqual(tagged, "Stop this session" + menuWakeModeSuffix(.system),
                       "a session of your own can be non-default now that Settings can choose")
        XCTAssertTrue(tagged.contains("lid"), tagged)
        XCTAssertFalse(tagged.hasPrefix("Stop keeping awake"),
                       "the tag must not sit against the verb, where it reads as a condition on "
                       + "stopping rather than a fact about the session: \(tagged)")
    }

    /// The multi-session form keeps the shape it already had — the noun it
    /// needs is the quoted description — so this pins that the fix above did
    /// not spread to a row that never had the problem.
    func testTheMultiSessionStopLabelStillQualifiesItsQuotedDescription() {
        let tagged = menuStopLabel(for: session(.system), isOnlyOneOfMine: false, now: t0)
        XCTAssertEqual(tagged, "Stop “indefinite”" + menuWakeModeSuffix(.system))
    }

    func testAForeignSessionCarriesItsModeToo() {
        let plain = menuForeignSessionLabel(for: session(.clamshell, owner: theirsID), now: t0)
        XCTAssertFalse(plain.contains("lid"), "the default mode adds nothing: \(plain)")

        let tagged = menuForeignSessionLabel(for: session(.systemAndDisplay, owner: theirsID), now: t0)
        XCTAssertTrue(tagged.contains("elsewhere"), tagged)
        XCTAssertTrue(tagged.contains("lid"),
                      "a CLI `--display-may-sleep` session must not read like a lid-safe one: \(tagged)")
    }

    /// The start rows are the point of use for the stored default, and the
    /// place someone who set it months ago will next meet it. Same reasoning as
    /// the CLI's stderr note: warn where the mistake is being made.
    func testTheStartRowsSayWhatTheStoredDefaultWillActuallyStart() {
        for kind in DefaultSessionKind.allCases {
            XCTAssertEqual(menuStartLabel(kind, wakeMode: .clamshell),
                           "Keep awake \(kind.durationPhrase)",
                           "the common case gains nothing")
            let tagged = menuStartLabel(kind, wakeMode: .system)
            XCTAssertTrue(tagged.hasPrefix("Keep awake"), "still verb-first: \(tagged)")
            XCTAssertTrue(tagged.contains("lid"), tagged)
        }
    }

    // MARK: - The one machine-wide statement

    /// The menu is the only surface that holds the *whole* session list, so it
    /// is the only one that can state the union fact the CLI's per-session
    /// caveat had to work around. It is derived from `PowerPlan.reduce` — the
    /// same reduction the daemon applies — rather than from any one session, so
    /// it cannot drift from what the machine will actually do.
    func testTheLidLineAppearsExactlyWhenNothingLiveHoldsTheLid() {
        XCTAssertNil(menuLidCaveat(for: []), "nothing is being kept awake; there is nothing to qualify")
        XCTAssertNil(menuLidCaveat(for: [session(.clamshell)]))
        XCTAssertNotNil(menuLidCaveat(for: [session(.system)]))
        XCTAssertNotNil(menuLidCaveat(for: [session(.systemAndDisplay)]))
        XCTAssertNotNil(menuLidCaveat(for: [session(.system), session(.systemAndDisplay)]))
    }

    /// The case the Task 4 caveat got wrong, from the other direction: one
    /// `.system` session and one `.clamshell` session means the Mac *does* stay
    /// awake with the lid shut, so the line must not appear — even though a
    /// session that gave the guarantee up is live and visibly tagged.
    func testAConcurrentDefaultSessionSuppressesTheLidLine() {
        let mixed = [session(.system, owner: mineID), session(.clamshell, owner: theirsID)]
        XCTAssertNil(menuLidCaveat(for: mixed),
                     "a live clamshell session keeps the machine awake lid-shut whoever owns it")
        // …and the tagged row is still tagged, because it is a true statement
        // about that session's own contribution, not about the machine.
        XCTAssertTrue(menuStopLabel(for: mixed[0], isOnlyOneOfMine: true, now: t0).contains("lid"))
    }

    /// Exhaustive over every combination of up to three modes rather than the
    /// handful of cases above: the line's presence is *defined* as the negation
    /// of the plan's `sleepDisabled`, so this is the invariant, and the
    /// examples are illustrations of it.
    func testTheLidLineAgreesWithThePlanTheDaemonWillApply() {
        var combinations: [[WakeMode]] = [[]]
        for a in WakeMode.allCases {
            combinations.append([a])
            for b in WakeMode.allCases {
                combinations.append([a, b])
                for c in WakeMode.allCases { combinations.append([a, b, c]) }
            }
        }
        for modes in combinations {
            let sessions = modes.map { session($0) }
            let planHoldsTheLid = PowerPlan.reduce(modes).sleepDisabled
            let shown = menuLidCaveat(for: sessions) != nil
            XCTAssertEqual(shown, !modes.isEmpty && !planHoldsTheLid,
                           "\(modes.map(\.rawValue)) — the menu and the daemon disagree about the lid")
        }
    }

    func testTheLidLineSaysWhatWillHappenNotWhichModeIsToBlame() {
        guard let line = menuLidCaveat(for: [session(.system)]) else { return XCTFail("expected a line") }
        XCTAssertTrue(line.lowercased().contains("lid"), line)
        XCTAssertTrue(line.lowercased().contains("sleep"),
                      "the consequence, not the vocabulary: \(line)")
        XCTAssertFalse(line.contains(WakeMode.system.rawValue),
                       "a wire name has no business in the menu: \(line)")
    }
}

/// The stored default and the Settings pane that writes it. Mirrors
/// `DefaultSessionKind`'s arrangement exactly — Settings writes a raw value,
/// the menu reads it back through `PreferencesSuite.defaults`, and an
/// unrecognised value falls back rather than dropping the control.
final class DefaultWakeModePreferenceTests: XCTestCase {
    func testAStoredModeRoundTrips() {
        for mode in WakeMode.allCases {
            XCTAssertEqual(DefaultWakeModePreference.mode(rawValue: mode.rawValue), mode)
        }
    }

    /// An enum case removed in a later version, a hand-edited plist, a value
    /// written by a future build — none of them may leave the menu unable to
    /// start a session, and none may silently *weaken* what a session gets.
    func testAnUnrecognisedStoredValueFallsBackRatherThanFailing() {
        for stored in ["", "systemAndDisplayAndSomethingElse", "CLAMSHELL", "1"] {
            XCTAssertEqual(DefaultWakeModePreference.mode(rawValue: stored),
                           DefaultWakeModePreference.fallback,
                           "unrecognised value \"\(stored)\" must fall back")
        }
    }

    /// Derived, not asserted: the fallback — and the value `@AppStorage` starts
    /// from before anyone has chosen — has to be the mode that survives a lid
    /// close, for the same reason the CLI's default is selected by absence. Any
    /// other choice silently weakens every session started by someone who never
    /// opened Settings.
    func testTheFallbackIsTheModeThatSurvivesALidClose() {
        XCTAssertTrue(DefaultWakeModePreference.fallback.requiresSleepDisabled)
        XCTAssertEqual(DefaultWakeModePreference.defaultRawValue,
                       DefaultWakeModePreference.fallback.rawValue)
    }

    /// The key is the contract between two files that never call each other.
    /// A typo in one is not a compile error and not a crash — it is a Settings
    /// pane that appears to work while the menu keeps reading the old value.
    func testTheKeyIsNamedOnceAndIsNotTheSessionKindKey() {
        XCTAssertEqual(DefaultWakeModePreference.key, "defaultWakeMode")
        XCTAssertNotEqual(DefaultWakeModePreference.key, "defaultSessionKind")
    }

    func testThePickerOffersEveryModeAndLeadsWithTheDefault() {
        XCTAssertEqual(Set(wakeModeSettingsOrder), Set(WakeMode.allCases),
                       "a mode missing from the picker is a mode nobody can choose")
        XCTAssertEqual(wakeModeSettingsOrder.count, WakeMode.allCases.count, "no duplicates")
        XCTAssertEqual(wakeModeSettingsOrder.first, DefaultWakeModePreference.fallback,
                       "the default leads, as it does in the menu's start list")
    }

    func testEveryModeHasATitleAndAnExplanationRatherThanARestatedLabel() {
        for mode in WakeMode.allCases {
            XCTAssertFalse(wakeModeSettingsTitle(mode).isEmpty)
            XCTAssertFalse(wakeModeSettingsTitle(mode).contains(mode.rawValue),
                           "\(mode.rawValue) is a wire name, not a thing to show a user")
            XCTAssertGreaterThan(wakeModeSettingsExplanation(mode).count, 40,
                                 "\(mode.rawValue) needs a real explanation")
            XCTAssertTrue(wakeModeSettingsExplanation(mode).lowercased().contains("lid"),
                          "the lid is the axis these modes actually differ on")
        }
    }

    /// The asymmetry that makes this copy safe to write at all: a *positive*
    /// claim ("keeps this Mac awake with the lid shut") is unconditionally true
    /// of a `.clamshell` session, because the union can only strengthen it. A
    /// *negative* one ("this Mac will sleep") is union-sensitive and false the
    /// moment any other client holds a clamshell session — so every negative
    /// statement here is scoped to the session, exactly as the CLI's caveat is.
    func testEveryNegativeLidStatementIsScopedToASessionAndNotToTheMac() {
        for mode in WakeMode.allCases {
            let explanation = wakeModeSettingsExplanation(mode)
            XCTAssertEqual(explanation.contains("does not survive a lid close"),
                           !mode.requiresSleepDisabled,
                           "\(mode.rawValue)'s explanation disagrees with what it actually does")
            guard explanation.contains("does not survive a lid close") else { continue }
            XCTAssertTrue(explanation.contains("A session in this mode"),
                          "a concurrent clamshell session keeps the machine awake lid-shut, so the "
                          + "negative has to be about the session: \(explanation)")
        }
    }

    /// The pane sets a default for one client among four, and only for that
    /// client's *future* sessions. Someone reading it must not conclude that a
    /// `keepy-uppy on` in a terminal, or a trigger firing while they are away,
    /// will follow it — neither does — nor that the session already running
    /// changed mode when they moved the picker. A session's mode is fixed at
    /// start; the picker cannot reach it. That last misreading is the one that
    /// loses work: it ends with someone shutting the lid on a Mac that then
    /// sleeps.
    func testTheScopeNoteSaysWhichSessionsThisActuallyGoverns() {
        XCTAssertTrue(wakeModeSettingsScopeNote.contains("menu"), wakeModeSettingsScopeNote)
        XCTAssertTrue(wakeModeSettingsScopeNote.contains("from now on"),
                      "the scope has to be prospective on its face, not merely inferable: "
                      + wakeModeSettingsScopeNote)
        XCTAssertTrue(wakeModeSettingsScopeNote.lowercased().contains("command line"),
                      wakeModeSettingsScopeNote)
        // Trigger-started sessions are built by `Agent/EvidenceLoopRunner.swift`
        // with no `wakeMode:` at all, so they are `.clamshell` whatever this
        // preference says. Stated as the positive fact, which is the one that
        // stays true under the union.
        XCTAssertTrue(wakeModeSettingsScopeNote.contains("lid closed"), wakeModeSettingsScopeNote)
    }
}
