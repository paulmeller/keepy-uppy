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
        XCTAssertEqual(menuStartLabel(.indefinite), "Keep awake indefinitely")
        XCTAssertEqual(menuStartLabel(.oneHour), "Keep awake for 1 hour")
        XCTAssertEqual(menuStartLabel(.eightHours), "Keep awake for 8 hours")
    }
}
