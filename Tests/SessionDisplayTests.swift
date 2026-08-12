import XCTest
@testable import KeepyUppy

final class SessionDisplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ kind: SessionKind, origin: SessionOrigin = .manual) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"), ownerUID: 0,
                persistence: .clientBound, origin: origin, startedAt: t0,
                triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
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

    func testWhileOnACPowerShowsItsCondition() {
        XCTAssertEqual(remainingTimeText(for: session(.whileOnACPower), now: t0), "While on AC power")
    }

    /// The row has to name the threshold, because the threshold is now the
    /// user's to pick: two `--while-cpu-busy` sessions with different numbers
    /// would otherwise be one indistinguishable row repeated, in the one place
    /// the menu explains why the Mac is awake.
    func testWhileCPUBusyNamesTheThresholdItWasGiven() {
        XCTAssertEqual(remainingTimeText(for: session(.whileCPUBusy(threshold: 0.30)), now: t0),
                       "While the CPU is at least 30% busy")
        XCTAssertEqual(remainingTimeText(for: session(.whileCPUBusy(threshold: 0.05)), now: t0),
                       "While the CPU is at least 5% busy")
    }

    /// The units, end to end. `SessionKind` stores a fraction and the flag takes
    /// a percentage, so the two sides can disagree by a factor of a hundred
    /// while each looks right on its own — `--while-cpu-busy 30` rendering as
    /// "3000% busy" is what that mistake looks like from the menu.
    func testTheThresholdTypedOnTheCommandLineIsTheThresholdShown() {
        guard case .success(.on(let kind, _, _)) = parseCLIArguments(["on", "--while-cpu-busy", "30"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(remainingTimeText(for: session(kind), now: t0), "While the CPU is at least 30% busy")
    }

    func testWhileProcessRunningShowsTheProcessCondition() {
        let s = session(.whileProcessRunning(processName: "claude"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While claude is running")
    }

    func testWhileVolumeMountedShowsTheVolumeCondition() {
        let s = session(.whileVolumeMounted(name: "Time Machine"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While Time Machine is mounted")
    }

    func testWhileOnSubnetShowsTheNetworkCondition() {
        let s = session(.whileOnSubnet(cidr: "192.168.1.0/24"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While on 192.168.1.0/24")
    }

    func testWhileVPNActiveShowsTheVPNCondition() {
        let s = session(.whileVPNActive)
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While a VPN is connected")
    }

    /// A device that is not attached renders as its identifiers rather than as
    /// nothing — the `appDisplayName` bargain, and here it is the ordinary case
    /// rather than the exception.
    func testWhileUSBDevicePresentFallsBackToTheIdentifiersWhenNothingIsAttached() {
        let s = session(.whileUSBDevicePresent(vendorID: 0xdead, productID: 0xbeef))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While 0xdead:0xbeef is attached")
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
                                            .appLaunched(bundleID: "com.apple.dt.Xcode"),
                                            .appFrontmost(bundleID: "com.apple.dt.Xcode")] {
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

    // MARK: - Driven by TriggerConditionKind rather than by a hand-written list

    /// Every condition must have copy. Before this, adding a case to the switch in
    /// triggerConditionTitle was compiler-forced but adding it to the *picker* was
    /// not, so the failure mode was a condition with perfect copy and no way to
    /// create it.
    func testEveryConditionKindHasATitleAndASubtitle() {
        for kind in TriggerConditionKind.allCases {
            let rule = TriggerRule(id: UUID(), condition: kind.sampleCondition,
                                   defaultKind: .oneHour, enabled: true)
            XCTAssertFalse(triggerConditionTitle(rule.condition).isEmpty, "\(kind)")
            XCTAssertFalse(triggerEffectSubtitle(rule).isEmpty, "\(kind)")
        }
    }

    /// A binding condition must never describe a duration it will ignore. This is
    /// the copy bug `.processRunning` already documents: `defaultKind` is stored on
    /// the rule but discarded at fire time, so a subtitle promising "for 4 hours"
    /// would be describing something that never happens.
    func testABindingConditionsSubtitleNeverPromisesADuration() {
        for kind in TriggerConditionKind.allCases where kind.bindsSessionLifetime {
            let rule = TriggerRule(id: UUID(), condition: kind.sampleCondition,
                                   defaultKind: .fourHours, enabled: true)
            XCTAssertFalse(triggerEffectSubtitle(rule).contains("4 hours"), "\(kind)")
        }
    }

    /// The general form of `testConditionTitlesDescribeTheStartingEventNotAnOngoingState`
    /// above, which names its three conditions by hand and so cannot see a
    /// fourth. "While" is licensed by `bindsSessionLifetime` and by nothing
    /// else: a title saying "while" for a condition whose session outlives it
    /// promises a stop that never comes.
    ///
    /// Machine-dependent in principle, and knowingly so. `.appLaunched`'s
    /// sample resolves its bundle ID through `NSWorkspace` (`appDisplayName`),
    /// so the title carries whatever *this* Mac calls `com.apple.dt.Xcode` —
    /// "Xcode" where it is installed, the raw bundle ID where it is not. A
    /// sample whose locally-installed app name contained "while" would fail
    /// here on one machine and pass on every other. None does today, and
    /// threading a fake resolver through the copy functions buys less than it
    /// costs; this note is so that a failure nobody else can reproduce is
    /// looked for in the right place.
    func testOnlyABindingConditionsTitleMaySayWhile() {
        for kind in TriggerConditionKind.allCases {
            let title = triggerConditionTitle(kind.sampleCondition).lowercased()
            XCTAssertEqual(title.contains("while "), kind.bindsSessionLifetime,
                           "\(kind): the title and the lifetime table disagree — \(title)")
        }
    }

    /// The two copy tables that only a *binding* condition may fill in. Each is
    /// an exhaustive switch, so a new condition cannot skip them silently; this
    /// pins that whichever branch it lands in matches the lifetime table, since
    /// a binding condition with no footnote leaves the Add sheet showing
    /// neither a duration picker nor a reason there isn't one.
    func testTheBoundCopyExistsForExactlyTheBindingConditions() {
        for kind in TriggerConditionKind.allCases {
            let condition = kind.sampleCondition
            XCTAssertEqual(triggerBoundEffectSubtitle(condition) != nil, kind.bindsSessionLifetime,
                           "\(kind): the row subtitle and the lifetime table disagree")
            XCTAssertEqual(triggerBindingFootnote(condition) != nil, kind.bindsSessionLifetime,
                           "\(kind): the Add sheet footnote and the lifetime table disagree")
            if kind.bindsSessionLifetime {
                XCTAssertFalse(triggerBoundEffectSubtitle(condition)?.isEmpty ?? true, "\(kind)")
                XCTAssertFalse(triggerBindingFootnote(condition)?.isEmpty ?? true, "\(kind)")
            }
        }
    }

    /// The picker labels. They live here rather than as raw values on the
    /// `Shared/` enum — where the old parallel `AddTriggerSheet.ConditionKind`
    /// kept them — for the same reason `wakeModeSettingsTitle` does: a raw
    /// value is a wire name, and `Shared/` compiles into the daemon and the
    /// CLI, neither of which has any business carrying Settings copy.
    func testEveryConditionKindHasItsOwnPickerLabel() {
        let labels = TriggerConditionKind.allCases.map(triggerConditionKindLabel)
        for (kind, label) in zip(TriggerConditionKind.allCases, labels) {
            XCTAssertFalse(label.isEmpty, "\(kind) has no label, so its picker row would be blank")
            XCTAssertFalse(wireNameLeaks(kind.rawValue, into: label),
                           "\(kind.rawValue) is a wire name, not a thing to show a user: \(label)")
        }
        XCTAssertEqual(Set(labels).count, labels.count,
                       "two conditions sharing a label are indistinguishable in the picker")
    }

    /// Whether `wireName` survives into `label` as one unbroken run of letters
    /// and digits — which is what a pasted or interpolated case name always
    /// looks like, and what English copy about the same subject does not.
    ///
    /// **Separators in the label are now required, and that is the fix.** This
    /// used to squash the label too — lowercase it and delete everything that
    /// was not a letter or a digit — so any label whose words happened to spell
    /// the case name in order tripped it. That is the natural way to write this
    /// copy, not a leak. Of ten plausible Plan 5 labels a reviewer tried, five
    /// false-alarmed: `wifiNetwork`/"A Wi-Fi network is joined",
    /// `wifiSSID`/"A Wi-Fi SSID matches", `bluetoothDevice`/"A Bluetooth device
    /// connects", `batteryLevel`/"Battery level is above" and
    /// `timeOfDay`/"A time of day arrives". The four current cases passed only
    /// by an accident of English tense and the copula — "An app launche**s**"
    /// against `appLaunche**d**` — which is not a property that survives six
    /// more conditions.
    ///
    /// It is loosened rather than tuned because of what a failure here provokes:
    /// the obvious response to "wire name leaked" on correct copy is to reword
    /// the copy, so a check that cries wolf does not merely waste time, it
    /// actively degrades the thing it guards.
    ///
    /// What it no longer catches, said plainly so nobody rediscovers it as a
    /// bug: "Wi-Fi SSID" for `wifiSSID`, because the hyphen breaks the run.
    /// That was this check's motivating catch, and it is arguably a false
    /// positive anyway — "Wi-Fi SSID" is the term macOS itself shows users, and
    /// there is no better name for the thing. A paraphrase ("A wireless network
    /// is joined") was never caught either. This finds a case name that reached
    /// the UI verbatim, which is the failure that actually happens.
    private func wireNameLeaks(_ wireName: String, into label: String) -> Bool {
        let needle = wireName.lowercased().filter { $0.isLetter || $0.isNumber }
        return label.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.contains(needle) }
    }

    /// The heuristic checked against the copy it is about to meet.
    ///
    /// These are the labels Plan 5's six conditions want. Every one is correct
    /// copy with no wire name in it, and five of them failed the previous form
    /// of the check. Asserting them here, rather than only through the loop
    /// over `allCases`, means the next attempt to tighten this cannot
    /// reintroduce the nuisance quietly — it has to turn these red first, with
    /// the labels in front of it.
    func testThePickerLabelCheckAcceptsTheCopyPlan5ActuallyWants() {
        for (wireName, label) in [("wifiNetwork", "A Wi-Fi network is joined"),
                                  ("wifiSSID", "A Wi-Fi SSID matches"),
                                  ("bluetoothDevice", "A Bluetooth device connects"),
                                  ("batteryLevel", "Battery level is above"),
                                  ("timeOfDay", "A time of day arrives"),
                                  ("appLaunched", "An app launches"),
                                  ("externalDisplayConnected", "An external display connects"),
                                  ("acPowerConnected", "Power is connected"),
                                  ("processRunning", "A process is running")] {
            XCTAssertFalse(wireNameLeaks(wireName, into: label),
                           "\(wireName): \"\(label)\" is copy about the condition, not its wire name")
        }
    }

    /// ...and it still catches what it exists for: a case name that reached the
    /// label verbatim, whatever the capitalisation and wherever it sits.
    func testThePickerLabelCheckStillCatchesAWireNameThatReachedTheLabel() {
        for (wireName, label) in [("wifiNetwork", "wifiNetwork"),
                                  ("wifiNetwork", "Trigger: wifiNetwork"),
                                  ("wifiNetwork", "WIFINETWORK"),
                                  ("batteryLevel", "When batteryLevel is above"),
                                  ("timeOfDay", "timeofday")] {
            XCTAssertTrue(wireNameLeaks(wireName, into: label),
                          "\(wireName) reached the label verbatim: \"\(label)\"")
        }
    }

    /// The labels the picker shipped with, pinned. The parallel enum they came
    /// off is gone; these are the strings it held.
    func testThePickerLabelsAreTheOnesTheSheetAlreadyShowed() {
        XCTAssertEqual(triggerConditionKindLabel(.appLaunched), "An app launches")
        XCTAssertEqual(triggerConditionKindLabel(.externalDisplayConnected), "An external display connects")
        XCTAssertEqual(triggerConditionKindLabel(.acPowerConnected), "Power is connected")
        XCTAssertEqual(triggerConditionKindLabel(.processRunning), "A process is running")
        XCTAssertEqual(triggerConditionKindLabel(.appFrontmost), "An app comes to the front")
        XCTAssertEqual(triggerConditionKindLabel(.volumeMounted), "A volume is mounted")
        XCTAssertEqual(triggerConditionKindLabel(.onSubnet), "This Mac is on a network")
        XCTAssertEqual(triggerConditionKindLabel(.vpnActive), "A VPN is connected")
        XCTAssertEqual(triggerConditionKindLabel(.usbDevicePresent), "A USB device is attached")
    }

    /// The subnet condition binds too, so its copy has to name the leaving —
    /// the event that will end the session — and it has to quote the block
    /// back, because a rule that just said "a network" would be
    /// indistinguishable from the next one in the list.
    func testTheSubnetConditionSaysWhatWillEndTheSession() {
        XCTAssertEqual(triggerConditionTitle(.onSubnet(cidr: "192.168.1.0/24")),
                       "While this Mac is on 192.168.1.0/24")
        XCTAssertEqual(triggerBoundEffectSubtitle(.onSubnet(cidr: "192.168.1.0/24")),
                       "Keeps this Mac awake until it leaves 192.168.1.0/24")
        XCTAssertEqual(triggerBindingFootnote(.onSubnet(cidr: "")),
                       "Ends automatically when this Mac leaves that network — no duration to pick.")
    }

    /// The question this condition has to answer for a user who came looking
    /// for a Wi-Fi trigger, because there is no Wi-Fi trigger to find.
    ///
    /// The SSID condition was specified alongside `.onSubnet` and was cut on
    /// the research: an unauthorized `CWInterface.ssid()` read is
    /// indistinguishable from "not on Wi-Fi" (measured — a Mac with a live
    /// association answered `nil`), and the agent that would do the reading can
    /// never obtain the Location Services grant, because
    /// `CLLocationManager`'s own header says a request from something that is
    /// not in use "will do nothing". See `NetworkAddressObserving` and
    /// `.superpowers/sdd/plan5-wifi-research.md`.
    ///
    /// So the person who opens this sheet wanting "while I'm on the office
    /// Wi-Fi" finds a picker row about *networks* and a field wanting an
    /// address block, and nothing tells them the two are the same thing. That
    /// is the `vpnDetectionLimitationNote` situation exactly — a rule that
    /// looks correct with a limitation nobody stated — so it gets the same
    /// treatment, and this pins the three halves that carry the meaning rather
    /// than the wording: that Wi-Fi **is** covered, why it is matched by block
    /// and not by name, and the compensation (Ethernet on the same network
    /// matches too, which an SSID rule could never have done).
    func testTheSubnetConditionSaysItIsHowAWiFiNetworkIsNamed() {
        let note = subnetCoversWiFiNote
        XCTAssertTrue(note.contains("Wi-Fi"), "a user looking for Wi-Fi must find it here: \(note)")
        XCTAssertTrue(note.contains("Location Services"),
                      "why it is not matched by name is the part that stops the question: \(note)")
        XCTAssertTrue(note.contains("Ethernet"),
                      "the block is better than an SSID here, not merely a substitute: \(note)")
    }

    /// The VPN condition binds too, and unlike the other three it has no
    /// associated value — so its copy is the same sentence everywhere and the
    /// Add-sheet footnote has no empty-field variant to get wrong.
    func testTheVPNConditionSaysWhatWillEndTheSession() {
        XCTAssertEqual(triggerConditionTitle(.vpnActive), "While a VPN is connected")
        XCTAssertEqual(triggerBoundEffectSubtitle(.vpnActive),
                       "Keeps this Mac awake until the VPN disconnects")
        XCTAssertEqual(triggerBindingFootnote(.vpnActive),
                       "Ends automatically when the VPN disconnects — no duration to pick.")
    }

    /// The one limitation a user cannot see, said where the rule is written.
    ///
    /// The observer asks macOS which of its network services is a VPN, so a
    /// tunnel that never registers one is invisible to it. Pinned on the two
    /// halves that matter — that it says what *is* covered, and that it names
    /// the command-line tools that are not — rather than on the exact wording,
    /// so the sentence can be improved without a test rewrite, but cannot
    /// quietly lose either half.
    func testTheVPNLimitationIsStatedRatherThanSilent() {
        let note = vpnDetectionLimitationNote
        XCTAssertTrue(note.contains("System Settings"), note)
        XCTAssertTrue(note.contains("won't be detected"), note)
        for tool in ["wg-quick", "openvpn", "Tunnelblick"] {
            XCTAssertTrue(note.contains(tool), "the note must name what is not covered: \(note)")
        }
    }

    /// The USB condition binds, so it says "while" — and both the title and the
    /// row subtitle go through the live-lookup display helper, which falls back
    /// to `0x05ac:0x024f` for a device that is not plugged in. That fallback is
    /// the *common* case for this condition (the point of the rule is a device
    /// that is not attached yet), so it is what is pinned here: a made-up pair
    /// nothing can be reporting.
    func testTheUSBConditionSaysWhatWillEndTheSession() {
        let absent = TriggerCondition.usbDevicePresent(vendorID: 0xdead, productID: 0xbeef)
        XCTAssertEqual(triggerConditionTitle(absent), "While 0xdead:0xbeef is attached")
        XCTAssertEqual(triggerBoundEffectSubtitle(absent),
                       "Keeps this Mac awake until 0xdead:0xbeef is unplugged")
    }

    /// Unlike the volume and subnet footnotes, this one names no device: it is
    /// read while the field is still being filled in, where the value is
    /// whatever half-typed hex is there — `0x0000:0x0000` before anything is
    /// chosen. "The device" is true at every moment the sheet is open.
    func testTheUSBAddSheetFootnoteNamesNoDeviceBecauseThereMayNotBeOneYet() {
        for condition: TriggerCondition in [.usbDevicePresent(vendorID: 0, productID: 0),
                                            .usbDevicePresent(vendorID: 0x05ac, productID: 0x024f)] {
            XCTAssertEqual(triggerBindingFootnote(condition),
                           "Ends automatically when the device is unplugged — no duration to pick.")
        }
    }

    /// The volume condition binds, so it is entitled to "while" — and its
    /// bound copy has to name the *unmount*, because that is the event that
    /// will end the session.
    func testTheVolumeConditionSaysWhatWillEndTheSession() {
        XCTAssertEqual(triggerConditionTitle(.volumeMounted(name: "Backup")), "While Backup is mounted")
        XCTAssertEqual(triggerBoundEffectSubtitle(.volumeMounted(name: "Backup")),
                       "Keeps this Mac awake until Backup is unmounted")
        XCTAssertEqual(triggerBindingFootnote(.volumeMounted(name: "")),
                       "Ends automatically when the volume is unmounted — no duration to pick.")
    }

    /// The two app conditions sit next to each other in one picker, so their
    /// labels and their titles have to be tellable apart at a glance — a user
    /// choosing between "An app launches" and "An app comes to the front" is
    /// choosing between two genuinely different triggers.
    func testTheTwoAppConditionsReadDifferentlyFromEachOther() {
        XCTAssertNotEqual(triggerConditionKindLabel(.appLaunched),
                          triggerConditionKindLabel(.appFrontmost))
        let title = triggerConditionTitle(.appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(title.hasSuffix(" comes to the front"), title)
        XCTAssertNotEqual(title, triggerConditionTitle(.appLaunched(bundleID: "com.apple.dt.Xcode")))
    }

    /// Nothing to report is reported as nothing: the pane must not carry a
    /// permanent line about a situation almost no one is in.
    func testNoUnreadableRulesMeansNoNotice() {
        XCTAssertNil(unreadableTriggerNotice(count: 0))
    }

    /// The two facts that stop a user acting on a missing trigger: it was kept,
    /// and it is not running here. A notice that only said "hidden" would leave
    /// them recreating a rule that already exists — a duplicate the newer build
    /// then shows twice.
    func testTheUnreadableNoticeSaysBothKeptAndNotRunning() {
        for count in [1, 2, 7] {
            guard let notice = unreadableTriggerNotice(count: count) else {
                return XCTFail("\(count) unreadable rules must produce a notice")
            }
            XCTAssertTrue(notice.contains("kept"), notice)
            XCTAssertTrue(notice.contains("won't run"), notice)
        }
    }

    /// "1 triggers were created" in a pane about data the user is worried about
    /// reads as a bug, which is the last impression this line should give.
    func testTheUnreadableNoticeCountsGrammatically() {
        XCTAssertEqual(unreadableTriggerNotice(count: 1)?.hasPrefix("1 trigger was"), true)
        XCTAssertEqual(unreadableTriggerNotice(count: 3)?.hasPrefix("3 triggers were"), true)
    }

    /// The Add sheet's footnote names the process before one has been typed,
    /// where the row subtitle never has to — the sheet renders it while the
    /// field is still empty.
    func testTheAddSheetFootnoteReadsBeforeAnythingHasBeenTyped() {
        guard let empty = triggerBindingFootnote(.processRunning(processName: "")) else {
            return XCTFail("a binding condition needs a footnote")
        }
        XCTAssertEqual(empty, "Ends automatically when the process exits — no duration to pick.")
        XCTAssertEqual(triggerBindingFootnote(.processRunning(processName: "claude")),
                       "Ends automatically when claude exits — no duration to pick.")
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
        Session(id: UUID(), kind: kind, owner: owner, ownerUID: 0, persistence: .clientBound,
                origin: origin, startedAt: t0, triggerID: nil, wakeMode: .clamshell,
                keepsDisksAwake: false)
    }

    func testIdleSaysSoPlainly() {
        XCTAssertEqual(menuStatusLine(yours: [], others: [], now: t0), "Not keeping awake")
    }

    func testOneSessionNamesWhatItIsRatherThanCountingIt() {
        let line = menuStatusLine(yours: [session(.indefinite, owner: mineID)], others: [], now: t0)
        XCTAssertEqual(line, "Keeping awake — indefinite")
    }

    func testStatusDistinguishesSessionsYouCannotStop() {
        let line = menuStatusLine(yours: [session(.indefinite, owner: mineID)],
                                  others: [session(.indefinite, owner: theirsID)], now: t0)
        XCTAssertTrue(line.contains("2 sessions"))
        XCTAssertTrue(line.contains("1 yours"), "the menu must say how many are actually yours: \(line)")

        let noneMine = menuStatusLine(yours: [], others: [session(.indefinite, owner: theirsID),
                                                        session(.indefinite, owner: theirsID)], now: t0)
        XCTAssertTrue(noneMine.contains("none yours"), noneMine)
    }

    func testTheStopLabelLeadsWithTheVerb() {
        for label in [menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfYours: true, now: t0),
                      menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfYours: false, now: t0)] {
            XCTAssertTrue(label.hasPrefix("Stop"), "\(label) must read as an action, not a status")
        }
    }

    func testASingleSessionNeedsNoDescriptionQuotedBackAtYou() {
        XCTAssertEqual(
            menuStopLabel(for: session(.indefinite, owner: mineID), isOnlyOneOfYours: true, now: t0),
            "Stop keeping awake")
    }

    func testSeveralSessionsAreDistinguishableFromEachOther() {
        let timed = session(.duration(until: t0.addingTimeInterval(3600)), owner: mineID)
        let label = menuStopLabel(for: timed, isOnlyOneOfYours: false, now: t0)
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

    /// **The suffix is a provenance clause now, not a parenthetical**, and the
    /// change is deliberate rather than cosmetic. Plan 7 Task 3 gave it its
    /// first real caller — the row for a session a trigger rule started, which
    /// this app cannot stop — and every such row has the shape
    /// `"<kind> — <provenance>"`. As `" (started automatically)"` it produced
    /// "Indefinite (started automatically)" beside "Indefinite — started by
    /// another user", which is two shapes for one list, or forced a second copy
    /// of the same three words to live in the label function.
    ///
    /// Its own contract is untouched: empty for the ordinary case, and the
    /// exception is what earns a mention.
    func testTheAutomaticMentionIsShapedLikeEveryOtherProvenanceClause() {
        let suffix = menuAutomaticSuffix(for: session(.indefinite, owner: mineID, origin: .trigger))
        XCTAssertEqual(suffix, " — started automatically")
    }

    func testForeignSessionsSayWhoStartedThemRatherThanThatItWasNotYou() {
        let label = menuSessionLabel(for: session(.indefinite, owner: theirsID),
                                     group: .anotherUsers, now: t0)
        XCTAssertFalse(label.hasPrefix("Stop"), "not a button — this app cannot stop it: \(label)")
        // "started elsewhere" was written when this row covered three unrelated
        // situations — another account's session, this user's own command-line
        // session, and this user's own trigger — and it had to be vague enough
        // to be true of all three. Now that the other two have rows of their
        // own, the word can say the one thing it actually means. It reveals
        // nothing the row does not already reveal: the kind text in front of it
        // is that session's own description, and it was always shown.
        XCTAssertTrue(label.contains("another user"), label)
    }

    func testStartLabelsReadAsInstructionsNotNouns() {
        // In the default mode — the only one that existed when these were
        // written — the label is exactly what it always was. That is the
        // "annotate the exception, not the rule" claim, stated as an equality
        // rather than a substring so a tag leaking onto the common case fails
        // here.
        XCTAssertEqual(menuStartLabel(.indefinite, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake indefinitely")
        XCTAssertEqual(menuStartLabel(.oneHour, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake for 1 hour")
        XCTAssertEqual(menuStartLabel(.eightHours, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake for 8 hours")
    }
}

/// Plan 7 Task 3: the menu's session list answers a **three-way** question, not
/// a two-way one.
///
/// `MenuContent` used to filter on `owner == app-<uid>` and call everything else
/// "started elsewhere". `owner` is `<role>-<uid>`, so a session started by a
/// trigger rule the user wrote themselves — owned by `agent-<uid>` — rendered
/// character for character like a session belonging to another human being on a
/// shared Mac. The Mac was awake because of the user's own rule and the one
/// surface whose job is to say why gave them a row about somebody else.
///
/// These pin the partition rather than the prose, because a wrong comparison
/// here produces a menu that looks entirely plausible: every row is present,
/// every row is well-formed, and one of them is about the wrong person.
final class MenuSessionGroupingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    /// A literal rather than `getuid()`: the partition takes the uid as an
    /// argument precisely so these can pin both sides of the comparison, and a
    /// test that asked the machine who it was could not describe a second user
    /// at all.
    private let me: UInt32 = 501
    private let someoneElse: UInt32 = 502

    private func app(_ uid: UInt32) -> ClientID { ClientRole.app.clientID(forUserID: uid) }
    private func agent(_ uid: UInt32) -> ClientID { ClientRole.agent.clientID(forUserID: uid) }
    private func cli(_ uid: UInt32) -> ClientID { ClientRole.cli.clientID(forUserID: uid) }

    private func session(owner: ClientID, ownerUID: UInt32, origin: SessionOrigin = .manual,
                         kind: SessionKind = .indefinite,
                         wakeMode: WakeMode = .clamshell) -> Session {
        Session(id: UUID(), kind: kind, owner: owner, ownerUID: ownerUID,
                persistence: .detached, origin: origin, startedAt: t0, triggerID: nil,
                wakeMode: wakeMode, keepsDisksAwake: false)
    }

    /// Partition and label together, which is the only combination the user
    /// ever sees: a partition that is right and a label that is wrong reads
    /// exactly like the bug this task closes.
    private func row(_ session: Session) -> String {
        menuSessionLabel(for: session, group: menuSessionGroup(for: session, userID: me), now: t0)
    }

    // MARK: - The three buckets that used to be one

    func testYourOwnTriggerSessionIsNotGroupedWithAnotherUsersSession() {
        let trigger = session(owner: agent(me), ownerUID: me, origin: .trigger)
        let stranger = session(owner: cli(someoneElse), ownerUID: someoneElse)

        XCTAssertEqual(menuSessionGroup(for: trigger, userID: me), .yoursAutomatic)
        XCTAssertEqual(menuSessionGroup(for: stranger, userID: me), .anotherUsers)
        XCTAssertNotEqual(row(trigger), row(stranger),
                          "a session your own rule started must not read like one belonging to "
                          + "somebody else: \(row(trigger))")
    }

    func testYourOwnCLISessionIsNotGroupedWithAnotherUsersSession() {
        let terminal = session(owner: cli(me), ownerUID: me)
        let stranger = session(owner: cli(someoneElse), ownerUID: someoneElse)

        XCTAssertEqual(menuSessionGroup(for: terminal, userID: me), .yoursCommandLine)
        XCTAssertEqual(menuSessionGroup(for: stranger, userID: me), .anotherUsers)
        XCTAssertNotEqual(row(terminal), row(stranger))
        XCTAssertTrue(row(terminal).lowercased().contains("command line"),
                      "the same binary the user typed into a terminal, named: \(row(terminal))")
    }

    /// The corroboration rule, as a test. `origin` is one of the fields
    /// `HelperProtocol.startSession` documents as *client-chosen* — the daemon
    /// overwrites `id`, `owner`, `ownerUID` and `startedAt` and leaves this one
    /// alone — so on its own it is a session's self-description. `ownerUID` is
    /// server-stamped from the peer's audit token, and it is what keeps another
    /// account's session out of this user's rows however that session describes
    /// itself.
    func testAnotherUsersSessionIsStillForeignEvenWhenItsOriginIsTrigger() {
        let theirs = session(owner: agent(someoneElse), ownerUID: someoneElse, origin: .trigger)
        XCTAssertEqual(menuSessionGroup(for: theirs, userID: me), .anotherUsers)
        XCTAssertFalse(row(theirs).contains("automatic"),
                       "another account's trigger is not this user's automatic session: \(row(theirs))")
    }

    /// The regression guard, asserted against the daemon's own authority rather
    /// than against a second hand-written list, so the menu cannot come to
    /// disagree with the daemon about what it is allowed to do. A row with a
    /// button the daemon refuses is a button that silently does nothing; a
    /// session the daemon would end with no row is a capability nobody can
    /// reach.
    ///
    /// **It was `testOnlyTheAppsOwnSessionsAreStoppable`, welded to
    /// `sessionsToStop(all: false)`, and both halves of that had to change in
    /// Plan 8 Task 5.** Two groups have buttons now, not one — spec §4 gained
    /// its single exception — and the authority is `authorize`, not the sweep:
    /// the sweep deliberately did *not* widen, so welding to it would now
    /// assert the opposite of the intended behaviour.
    func testTheRowsWithAStopButtonAreExactlyWhatTheDaemonWouldLetThisAppStop() {
        let all = [
            session(owner: app(me), ownerUID: me),
            session(owner: agent(me), ownerUID: me, origin: .trigger),
            session(owner: agent(me), ownerUID: me, origin: .manual),
            session(owner: cli(me), ownerUID: me, origin: .trigger),
            session(owner: ClientID(rawValue: "shortcuts-\(me)"), ownerUID: me),
            session(owner: app(someoneElse), ownerUID: someoneElse),
            session(owner: agent(someoneElse), ownerUID: someoneElse, origin: .trigger),
        ]
        let clickable: Set<MenuSessionGroup> = [.thisApp, .yoursAutomatic]
        let stoppableInTheMenu = all.filter { clickable.contains(menuSessionGroup(for: $0, userID: me)) }
        let stoppableByTheDaemon = all.filter {
            SessionIsolation.authorize(sessionID: $0.id, action: .stop, requestedBy: app(me),
                                       uid: me, role: .app, among: all) == .authorized
        }
        XCTAssertEqual(stoppableInTheMenu.map(\.id), stoppableByTheDaemon.map(\.id),
                       "the rows with a stop button must be exactly the sessions the daemon would "
                       + "let this app stop")
        XCTAssertEqual(stoppableInTheMenu.count, 2, "this app's own session, and this user's trigger")
    }

    /// The other half of the same weld, and the reason the sweep row has its
    /// own label: what "Stop all started from this menu" ends is a **strict
    /// subset** of the rows that have buttons.
    ///
    /// Stated as a subset relation rather than as a literal list, so it stays
    /// true if `sessionsToStop` is ever widened deliberately — and fails loudly
    /// if a row is ever given a button the sweep would silently sweep past
    /// without the label being reconsidered.
    func testTheSweepEndsFewerSessionsThanTheMenuOffersToStop() {
        let all = [
            session(owner: app(me), ownerUID: me),
            session(owner: agent(me), ownerUID: me, origin: .trigger),
        ]
        let swept = Set(SessionIsolation.sessionsToStop(all: false, requestedBy: app(me), among: all))
        let clickable: Set<MenuSessionGroup> = [.thisApp, .yoursAutomatic]
        let withButtons = Set(all.filter { clickable.contains(menuSessionGroup(for: $0, userID: me)) }
            .map(\.id))
        XCTAssertTrue(swept.isSubset(of: withButtons),
                      "the sweep must never end something the menu does not even offer to stop")
        XCTAssertEqual(swept, Set([all[0].id]),
                       "and today it is exactly this app's own sessions — see "
                       + "SessionIsolation.sessionsToStop for why it was not widened")
    }

    /// The sweep row must not claim the whole of "yours" while ending part of
    /// it. It said "Stop all mine" when those were the same set.
    func testTheSweepRowNamesItsScopeRatherThanClaimingAllOfYours() {
        XCTAssertFalse(menuStopAllLabel.lowercased().contains("mine"), menuStopAllLabel)
        XCTAssertFalse(menuStopAllLabel.lowercased().contains("yours"), menuStopAllLabel)
        XCTAssertTrue(menuStopAllLabel.lowercased().contains("menu"),
                      "it has to say where the sessions it ends came from: \(menuStopAllLabel)")
        // Same set, so the same words: a user who reads one and presses the
        // other must not be surprised.
        XCTAssertTrue(HotKeyAction.stopAppSessions.label.lowercased().contains("started from the menu"),
                      HotKeyAction.stopAppSessions.label)
    }

    // MARK: - One rule, read in two places

    /// "This user's own trigger rule started this session" was written out by
    /// hand twice — here, inside `menuSessionGroup`'s `.agent` branch, and again
    /// in `SessionNotificationTracker.isAutomatic`, which said so itself
    /// ("exactly what `menuSessionGroup` already does for the equivalent menu
    /// row"). Two hand-written copies of a two-clause security predicate is the
    /// drift this codebase closes everywhere else — `ClientRole.clientID(forUserID:)`,
    /// `TriggerCondition.boundSessionKind`, `MenuDefaultStart` — and the copy
    /// that would be loosened first is the one whose file never mentions the
    /// other.
    ///
    /// So there is one rule now, and this is the weld: the predicate is not
    /// merely *equal* to the group today, it is defined as the group, and this
    /// test fails the moment somebody re-writes it out by hand.
    func testTheAutomaticRuleIsTheGroupingItself() {
        for candidate in [
            session(owner: agent(me), ownerUID: me, origin: .trigger),
            session(owner: agent(me), ownerUID: me, origin: .manual),
            session(owner: app(me), ownerUID: me, origin: .trigger),
            session(owner: app(me), ownerUID: me, origin: .manual),
            session(owner: cli(me), ownerUID: me, origin: .trigger),
            session(owner: agent(someoneElse), ownerUID: someoneElse, origin: .trigger),
            session(owner: ClientID(rawValue: "shortcuts-\(me)"), ownerUID: me, origin: .trigger),
        ] {
            XCTAssertEqual(candidate.startedByTrigger(forUserID: me),
                           menuSessionGroup(for: candidate, userID: me) == .yoursAutomatic,
                           "the predicate and the grouping must not be two rules: \(candidate.owner)")
        }
    }

    /// The four cases the conjunction exists for, one assertion each.
    ///
    /// The second is the whole reason it is a conjunction: `origin` is
    /// client-chosen — `HelperProtocol.startSession` passes it through untouched
    /// — so any client of this user can *say* `.trigger`. `owner` is stamped by
    /// the daemon from the listener that accepted the connection, and only the
    /// agent can connect on the agent's service, so it is the half that cannot
    /// be asserted into existence.
    func testOnlyThisUsersAgentStartingATriggerSessionCountsAsAutomatic() {
        XCTAssertTrue(session(owner: agent(me), ownerUID: me, origin: .trigger)
            .startedByTrigger(forUserID: me))
        XCTAssertFalse(session(owner: cli(me), ownerUID: me, origin: .trigger)
            .startedByTrigger(forUserID: me),
                       "a terminal saying \"trigger\" is a claim, not a fact")
        XCTAssertFalse(session(owner: agent(me), ownerUID: me, origin: .manual)
            .startedByTrigger(forUserID: me),
                       "the agent can start a session that no rule asked for")
        XCTAssertFalse(session(owner: agent(someoneElse), ownerUID: someoneElse, origin: .trigger)
            .startedByTrigger(forUserID: me),
                       "another account's rule fired, not this user's")
    }

    // MARK: - The suffix that finally arrives somewhere

    /// `menuAutomaticSuffix` has been written and tested since Plan 4 and has
    /// never once returned anything in a running app: it was appended only to
    /// `mine`, which was `app-<uid>`, while the only producer of
    /// `origin == .trigger` is the agent. This is the test that says it arrives.
    func testAnAutomaticSessionOfYoursSaysSo() {
        let trigger = session(owner: agent(me), ownerUID: me, origin: .trigger)
        let suffix = menuAutomaticSuffix(for: trigger)

        XCTAssertFalse(suffix.isEmpty,
                       "the session a trigger rule started is exactly the one this was written for")
        XCTAssertEqual(row(trigger), "Indefinite" + suffix,
                       "the automatic row must be built from that suffix, not from a second copy "
                       + "of its words: \(row(trigger))")
        XCTAssertTrue(row(trigger).contains("automatically"), row(trigger))
    }

    /// The suffix stays silent on the ordinary case, which is the whole reason
    /// it is a suffix and not a column: "started manually" on a session you
    /// started by hand is noise.
    func testAManualSessionOfYoursStillSaysNothingAboutItsOrigin() {
        XCTAssertEqual(menuAutomaticSuffix(for: session(owner: app(me), ownerUID: me)), "")
        XCTAssertEqual(row(session(owner: app(me), ownerUID: me)), "Indefinite")
    }

    // MARK: - The combination nobody named

    /// `ownerUID` and `owner` are independent axes, so "yours" and "this app's"
    /// make four combinations, not three. The one with no name is a session of
    /// this user's from a client this build cannot identify — and the reason the
    /// command-line row is right for a `cli-<uid>` session is that its owner
    /// *says* `cli`, not that it is whatever was left over. A `switch` written
    /// as "app / trigger / else foreign / else command line" would tell the user
    /// that a future Shortcuts extension came from a terminal they never opened.
    func testASessionOfYoursFromAnUnknownClientIsNotCalledTheCommandLine() {
        let unknownRole = session(owner: ClientID(rawValue: "shortcuts-\(me)"), ownerUID: me)
        XCTAssertEqual(menuSessionGroup(for: unknownRole, userID: me), .yoursOtherClient)
        XCTAssertFalse(row(unknownRole).lowercased().contains("command line"),
                       "nothing here knows that: \(row(unknownRole))")
        XCTAssertFalse(row(unknownRole).contains("automatic"), row(unknownRole))
    }

    /// The same bucket from the other direction, and the one the design review
    /// actually named: an agent-owned session that is not a trigger. Unreachable
    /// today — `EvidenceLoopRunner` is the only thing that connects on the agent
    /// service and it only ever starts triggers — and it must not borrow the
    /// automatic row's claim on the strength of its owner alone.
    func testAnAgentSessionThatIsNotATriggerDoesNotClaimToBeAutomatic() {
        let notATrigger = session(owner: agent(me), ownerUID: me, origin: .manual)
        XCTAssertEqual(menuSessionGroup(for: notATrigger, userID: me), .yoursOtherClient)
        XCTAssertFalse(row(notATrigger).contains("automatic"), row(notATrigger))
    }

    /// A `cli-<uid>` session claiming `origin == .trigger` — which no shipped
    /// client sends, and which a hand-rolled XPC client of this user could —
    /// gets the row its *owner* earns. The owner is server-derived; the origin
    /// is not, and the row's job is to say where the session came from.
    func testAClientAssertedTriggerOriginCannotPromoteACommandLineSession() {
        let claimsTrigger = session(owner: cli(me), ownerUID: me, origin: .trigger)
        XCTAssertEqual(menuSessionGroup(for: claimsTrigger, userID: me), .yoursCommandLine)
    }

    // MARK: - What every row does and does not say

    /// Four situations, four sentences. The word "elsewhere" used to cover three
    /// of them at once, which is exactly why nobody could tell them apart.
    func testEveryGroupThisAppCannotStopReadsDifferentlyFromEveryOther() {
        let examples: [MenuSessionGroup: Session] = [
            .yoursAutomatic: session(owner: agent(me), ownerUID: me, origin: .trigger),
            .yoursCommandLine: session(owner: cli(me), ownerUID: me),
            .yoursOtherClient: session(owner: ClientID(rawValue: "shortcuts-\(me)"), ownerUID: me),
            .anotherUsers: session(owner: cli(someoneElse), ownerUID: someoneElse),
        ]
        var seen: [String: MenuSessionGroup] = [:]
        for group in MenuSessionGroup.allCases where group != .thisApp {
            guard let example = examples[group] else {
                return XCTFail("\(group) has no example row; a new group needs its own sentence")
            }
            XCTAssertEqual(menuSessionGroup(for: example, userID: me), group)
            let label = menuSessionLabel(for: example, group: group, now: t0)
            XCTAssertTrue(label.hasPrefix("Indefinite — "),
                          "the shape is <kind> — <provenance>: \(label)")
            if let clash = seen.updateValue(group, forKey: label) {
                XCTFail("\(group) and \(clash) render identically: \(label)")
            }
        }
    }

    /// **No row explains why it has no stop button.** The absence of the button
    /// is the existing, deliberate signal — the menu was rebuilt away from rows
    /// that carried three facts each — and a line apologising for its own limits
    /// on every rebuild is the verbosity that rebuild removed. The limitation is
    /// the README's job.
    func testNoRowApologisesForNotBeingAButton() {
        for group in MenuSessionGroup.allCases where group != .thisApp {
            let label = menuSessionLabel(
                for: session(owner: cli(someoneElse), ownerUID: someoneElse), group: group, now: t0)
            XCTAssertFalse(label.hasPrefix("Stop"), "not a button: \(label)")
            for word in ["stop", "can't", "cannot", "unable"] {
                XCTAssertFalse(label.lowercased().contains(word),
                               "\(group): the missing button is the signal, not a sentence: \(label)")
            }
        }
    }

    /// Every unstoppable row still carries its session's wake mode, for the
    /// reason `menuForeignSessionLabel` did: a `.system` session that reads like
    /// a lid-safe one is how somebody shuts the lid on work that then stops.
    func testEveryRowStillCarriesItsSessionsWakeMode() {
        for group in MenuSessionGroup.allCases {
            for mode in WakeMode.allCases {
                let label = menuSessionLabel(
                    for: session(owner: cli(me), ownerUID: me, wakeMode: mode),
                    group: group, now: t0)
                XCTAssertEqual(label.contains("lid"), !mode.requiresSleepDisabled,
                               "\(group)/\(mode.rawValue): the mode that survives a lid close is "
                               + "the rule and goes untagged; every other mode must be visible: \(label)")
            }
        }
    }

    /// The kind is still what leads the row — it is the answer to "why is this
    /// Mac awake", and the provenance is the qualifier.
    func testTheRowStillLeadsWithWhatTheSessionActuallyIs() {
        let timed = session(owner: agent(me), ownerUID: me, origin: .trigger,
                            kind: .duration(until: t0.addingTimeInterval(3600)))
        XCTAssertTrue(row(timed).hasPrefix("1h 0m left"), row(timed))
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
                         kind: SessionKind = .indefinite,
                         keepsDisksAwake: Bool = false) -> Session {
        Session(id: UUID(), kind: kind, owner: owner ?? mineID, ownerUID: 0,
                persistence: .clientBound, origin: .manual, startedAt: t0,
                triggerID: nil, wakeMode: mode, keepsDisksAwake: keepsDisksAwake)
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
        let plain = menuStopLabel(for: session(.clamshell), isOnlyOneOfYours: true, now: t0)
        XCTAssertEqual(plain, "Stop keeping awake", "the default mode adds nothing")

        let tagged = menuStopLabel(for: session(.system), isOnlyOneOfYours: true, now: t0)
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
        let tagged = menuStopLabel(for: session(.system), isOnlyOneOfYours: false, now: t0)
        XCTAssertEqual(tagged, "Stop “indefinite”" + menuWakeModeSuffix(.system))
    }

    func testAForeignSessionCarriesItsModeToo() {
        let plain = menuSessionLabel(for: session(.clamshell, owner: theirsID),
                                     group: .anotherUsers, now: t0)
        XCTAssertFalse(plain.contains("lid"), "the default mode adds nothing: \(plain)")

        let tagged = menuSessionLabel(for: session(.systemAndDisplay, owner: theirsID),
                                      group: .anotherUsers, now: t0)
        XCTAssertTrue(tagged.contains("another user"), tagged)
        XCTAssertTrue(tagged.contains("lid"),
                      "a CLI `--display-may-sleep` session must not read like a lid-safe one: \(tagged)")
    }

    /// The start rows are the point of use for the stored default, and the
    /// place someone who set it months ago will next meet it. Same reasoning as
    /// the CLI's stderr note: warn where the mistake is being made.
    func testTheStartRowsSayWhatTheStoredDefaultWillActuallyStart() {
        for kind in DefaultSessionKind.allCases {
            XCTAssertEqual(menuStartLabel(kind, wakeMode: .clamshell, keepsDisksAwake: false),
                           "Keep awake \(kind.durationPhrase)",
                           "the common case gains nothing")
            let tagged = menuStartLabel(kind, wakeMode: .system, keepsDisksAwake: false)
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
        XCTAssertTrue(menuStopLabel(for: mixed[0], isOnlyOneOfYours: true, now: t0).contains("lid"))
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
            // Reduced from the same sessions the line is computed from, not from
            // a parallel list of modes: `menuLidCaveat` maps `\.power`, so
            // rebuilding requests here by hand would let the two drift on the
            // disk axis and still agree on the lid.
            let planHoldsTheLid = PowerPlan.reduce(sessions.map(\.power)).sleepDisabled
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

/// The stored default session kind — the oldest of the three preferences and
/// the last to be named, having been a bare literal in three production files
/// and eleven test lines while the two types below were written specifically to
/// avoid that shape.
///
/// The literal `"defaultSessionKind"` survives in exactly one place now, the
/// first test here, and that is the point of it: every other reader and writer
/// goes through `DefaultSessionKindPreference.key`, so this one assertion is
/// what stands between a rename and every existing user's chosen default being
/// silently forgotten. It is the discipline `TriggerStore.key` states — tests
/// plant under the constant the store reads, because "a second copy of the
/// literal in the tests could drift from this one, and a test that writes
/// somewhere the store never looks proves nothing".
final class DefaultSessionKindPreferenceTests: XCTestCase {
    /// **The stored value must not change.** This key has shipped; a build that
    /// renamed it would not migrate anybody's choice, it would forget it — and
    /// not loudly. The symptom is a General pane that looks like it works while
    /// every menu row goes back to offering "Indefinitely".
    func testTheKeyIsTheOneAlreadyOnDisk() {
        XCTAssertEqual(DefaultSessionKindPreference.key, "defaultSessionKind")
    }

    func testAStoredKindRoundTrips() {
        for kind in DefaultSessionKind.allCases {
            XCTAssertEqual(DefaultSessionKindPreference.kind(rawValue: kind.rawValue), kind)
        }
    }

    /// A case removed in a later version, a hand-edited plist, a value written
    /// by a future build: none of them may leave the menu, the Settings picker
    /// or the hot key unable to start anything.
    func testAnUnrecognisedStoredValueFallsBackRatherThanFailing() {
        for stored in ["", "fortnight", "INDEFINITE", "4", "fourHoursish"] {
            XCTAssertEqual(DefaultSessionKindPreference.kind(rawValue: stored),
                           DefaultSessionKindPreference.fallback,
                           "unrecognised value \"\(stored)\" must fall back")
        }
    }

    /// The fallback is one value used at both ends — the value `@AppStorage`
    /// starts from before anybody has chosen, and the value an unreadable one
    /// lands on. Two spellings of it is how the picker and the reader come to
    /// disagree about what "nobody has chosen yet" means, and there were three
    /// spellings of it before this type existed: two `@AppStorage` starting
    /// values and `MenuDefaultStart`'s inline `?? .indefinite`.
    ///
    /// `.indefinite` in particular, on the same reasoning as
    /// `DefaultWakeModePreference.fallback`: absence must not silently take
    /// something away. A session that ends at a time nobody chose is exactly
    /// that, and it is the failure a user cannot see coming.
    func testTheFallbackIsNamedOnceAndUsedAtBothEnds() {
        XCTAssertEqual(DefaultSessionKindPreference.fallback, .indefinite)
        XCTAssertEqual(DefaultSessionKindPreference.defaultRawValue,
                       DefaultSessionKindPreference.fallback.rawValue)
        XCTAssertEqual(DefaultSessionKindPreference.kind(rawValue: "nothing this build knows"),
                       DefaultSessionKindPreference.fallback)
    }

    func testItsKeyIsItsOwn() {
        for other in [DefaultWakeModePreference.key, DefaultKeepDisksAwakePreference.key,
                      SessionNotificationPreference.stopKey,
                      SessionNotificationPreference.triggerStartKey, TriggerStore.key] {
            XCTAssertNotEqual(DefaultSessionKindPreference.key, other,
                              "two preferences sharing a key is two controls fighting over one value")
        }
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
        XCTAssertNotEqual(DefaultWakeModePreference.key, DefaultSessionKindPreference.key)
    }

    func testTheDiskPreferenceIsNotTheWakeModeKey() {
        XCTAssertNotEqual(DefaultWakeModePreference.key, DefaultKeepDisksAwakePreference.key,
                          "two preferences sharing a key is two controls fighting over one value")
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

    /// Plan 6 Task 1. The mechanism behind `.systemAndDisplay` is
    /// `kIOPMAssertPreventUserIdleDisplaySleep`, and its header promises
    /// exactly two things: the display does not dim, and it does not turn off
    /// on the idle-activity timer. Both are facts about the panel's **power
    /// state**. Neither is a promise about what is *drawn* on it.
    ///
    /// The shipped copy used to end this mode's first sentence with "for a
    /// dashboard or a progress window you want to be able to glance at" — a
    /// promise about visibility that no measurement underwrites, and one a
    /// screensaver defeats while satisfying every measured effect of the
    /// assertion. See `.superpowers/sdd/plan6-display-sleep-research.md`:
    /// `HIDIdleTime` climbed 43.275 s over 43 wall-clock seconds *while the
    /// assertion was held*, so the assertion does not stop the idle clock.
    ///
    /// Written over `allCases` rather than against `.systemAndDisplay`
    /// literally, so a fourth mode cannot reintroduce the promise quietly, and
    /// asserting the *distinction* rather than pinning the sentence, so a
    /// rewording that keeps faith with the measurement doesn't fail for
    /// nothing.
    func testNoModePromisesTheScreenStaysWatchableRatherThanMerelyLit() {
        // Vocabulary of *visibility*, which is what the assertion does not
        // buy — as distinct from vocabulary of the panel being powered, which
        // is what it does.
        let unsupported = ["glance", "watch", "visible", "dashboard", "read the screen"]
        for mode in WakeMode.allCases {
            let explanation = wakeModeSettingsExplanation(mode).lowercased()
            for word in unsupported {
                XCTAssertFalse(explanation.contains(word),
                               "\(mode.rawValue)'s explanation promises “\(word)” — a claim about "
                               + "what you can see. The assertion holds the display's power state, "
                               + "not its contents: \(explanation)")
            }
        }
    }

    /// The companion guard, and the more important of the two: the copy must
    /// stay **silent** on screensavers, not take a side.
    ///
    /// Claiming suppression would be false — `HIDIdleTime` runs at full speed
    /// under the assertion. Claiming the opposite ("it cannot stop a
    /// screensaver") would be an inference about `loginwindow`, which nobody
    /// here has observed, published as a limitation. The measurement that
    /// settles it is a manual-checklist item that runs after this ships, so
    /// until then neither sentence may appear in any mode's copy.
    ///
    /// This pins the *absence* of a claim; it does not pin the claim.
    func testNoModeCopyTakesASideOnScreensaversWhileThatIsStillUnmeasured() {
        for mode in WakeMode.allCases {
            for text in [wakeModeSettingsExplanation(mode), menuWakeModeTag(mode) ?? "",
                         wakeModeSettingsTitle(mode)] {
                XCTAssertFalse(text.lowercased().contains("screensaver"),
                               "\(mode.rawValue): unmeasured, so unsaid — \(text)")
                XCTAssertFalse(text.lowercased().contains("screen saver"),
                               "\(mode.rawValue): unmeasured, so unsaid — \(text)")
            }
        }
        XCTAssertFalse(wakeModeSettingsScopeNote.lowercased().contains("screensaver"),
                       wakeModeSettingsScopeNote)
    }

    /// The claim each mode's copy *is* allowed to make about the screen, pinned
    /// against `holdsDisplayAwake` rather than against a list of case names —
    /// the same discipline as `testOnlyTheScreenHoldingModeMentionsTheScreen`
    /// on the menu tag, applied to the longer Settings sentence.
    ///
    /// A mode that holds the display says so; a mode that does not says the
    /// screen is free to sleep. "Both modes leave the screen alone" and "both
    /// modes hold it" are each a single edit away and each silently wrong, and
    /// this is what catches them.
    func testEachModesScreenClaimMatchesWhetherItActuallyHoldsTheDisplay() {
        for mode in WakeMode.allCases {
            let explanation = wakeModeSettingsExplanation(mode).lowercased()
            XCTAssertTrue(explanation.contains("screen") || explanation.contains("display"),
                          "\(mode.rawValue) says nothing about the screen at all: \(explanation)")
            let saysFreeToSleep = explanation.contains("free to sleep")
            XCTAssertEqual(saysFreeToSleep, !mode.holdsDisplayAwake,
                           "\(mode.rawValue)'s explanation disagrees with `holdsDisplayAwake`: "
                           + explanation)
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
        // with an explicit `wakeMode: .clamshell`, so they are lid-safe whatever
        // this preference says. Stated as the positive fact, which is the one
        // that stays true under the union.
        XCTAssertTrue(wakeModeSettingsScopeNote.contains("lid closed"), wakeModeSettingsScopeNote)
    }
}

/// The stored disk default, and the pane that writes it.
///
/// It takes the **naming discipline** from `DefaultWakeModePreference` — the key
/// named once, the fallback named once — because that is what stops two files
/// that never call each other from disagreeing on a string, which is not a
/// compile error and not a crash but a Settings pane that appears to work while
/// the menu reads the old value.
///
/// It deliberately does **not** take that type's unrecognised-value machinery,
/// and there is no test for one here. `DefaultWakeModePreference` needs it
/// because a `String` read back from `UserDefaults` can be a string matching no
/// `WakeMode` case, so "unrecognised stored value → fall back" is a real state.
/// A `Bool` has no such state: `UserDefaults.bool(forKey:)` returns `false` for
/// an absent key and for a non-boolean value alike, and there is no third thing
/// it can be. Writing `defaults.set("banana", forKey:)` to manufacture one would
/// be a test of `UserDefaults`, not of this type.
final class DefaultKeepDisksAwakePreferenceTests: XCTestCase {
    func testTheKeyIsNamedOnceAndIsItsOwn() {
        XCTAssertEqual(DefaultKeepDisksAwakePreference.key, "defaultKeepDisksAwake")
        for other in [DefaultSessionKindPreference.key, DefaultWakeModePreference.key] {
            XCTAssertNotEqual(DefaultKeepDisksAwakePreference.key, other,
                              "two preferences sharing a key is two controls fighting over one value")
        }
    }

    /// Absent means off, matching the decode-time direction `Session` chose and
    /// the CLI's absent-flag direction, for the same reason in all three places:
    /// nobody asked for it, and inventing a machine-wide held assertion for
    /// somebody who never opened this pane is over-application — a Mac whose
    /// disks never spin down, for a reason nothing on screen explains.
    ///
    /// Note this is the *opposite* direction from `DefaultWakeModePreference`'s
    /// fallback, which is the strongest mode. That asymmetry is deliberate and
    /// is the same one `Session.init(from:)` documents: absence must not weaken
    /// a promise anybody already relies on, and must not manufacture one nobody
    /// asked for.
    func testTheFallbackIsOffAndIsNamedOnce() {
        XCTAssertFalse(DefaultKeepDisksAwakePreference.fallback)
    }
}

/// The Settings copy for the disk toggle. Two true things and no third one.
final class KeepDisksAwakeCopyTests: XCTestCase {
    /// The promise: attached disks stay spun up while the session runs. That is
    /// what the assertion actually buys, and it is why anyone would turn this
    /// on.
    func testTheFooterSaysWhatItActuallyDoes() {
        let footnote = keepDisksAwakeSettingsFootnote.lowercased()
        XCTAssertTrue(footnote.contains("disks") || footnote.contains("drive"), footnote)
        XCTAssertTrue(footnote.contains("session"),
                      "it is a property of a running session, not of the Mac forever: \(footnote)")
    }

    /// The limitation, in the same breath as the promise, because the name
    /// promises more than the mechanism can deliver: the assertion is
    /// system-wide (`.superpowers/sdd/plan6-drive-alive-research.md` grepped
    /// four `pwr_mgt` headers for a per-device assertion and found a decade-dead
    /// notification API and nothing else), and it suspends macOS's `disksleep`
    /// timer without any authority over an enclosure's own firmware.
    ///
    /// This is the sentence that has to be *here* rather than on stderr. A note
    /// printed on every use of a flag people put in backup scripts is a note
    /// people learn to skip, and "your enclosure may ignore this" is wrong on a
    /// Mac with only internal storage — a note that is sometimes wrong is worse
    /// than none, which is the scoping argument `lidCloseCaveat` already
    /// settled. Settings is where the choice is made once, by somebody reading.
    func testTheFooterSaysWhatItCannotDo() {
        let footnote = keepDisksAwakeSettingsFootnote.lowercased()
        XCTAssertTrue(footnote.contains("system-wide") || footnote.contains("every"),
                      "the assertion cannot be scoped to one drive, and the copy must not "
                      + "let anyone believe otherwise: \(footnote)")
        XCTAssertTrue(footnote.contains("firmware") || footnote.contains("enclosure"),
                      "an enclosure that decides for itself still decides for itself: \(footnote)")
    }

    /// It must not claim to *wake* a drive. The header is explicit — "this
    /// assertion doesn't increase a disk's power state (it just prevents that
    /// device from idling)" — so a drive already parked when the session starts
    /// stays parked, and Keepy Uppy deliberately does not do the I/O the header
    /// suggests for getting them back.
    func testTheFooterDoesNotPromiseToSpinAParkedDriveUp() {
        let footnote = keepDisksAwakeSettingsFootnote.lowercased()
        for overclaim in ["wakes", "spins up", "spin up", "wake up"] where footnote.contains(overclaim) {
            XCTFail("the assertion prevents idling; it does not spin a parked drive up: \(footnote)")
        }
    }

    /// Whose sessions this governs, said the way the wake-mode picker's scope
    /// note says it: the menu's future sessions, not the command line's and not
    /// a trigger's. Cross-checked against what the other two clients actually
    /// do rather than against a sentence somebody wrote.
    func testTheScopeNoteSaysWhichSessionsThisGoverns() {
        XCTAssertTrue(keepDisksAwakeSettingsScopeNote.contains("menu"),
                      keepDisksAwakeSettingsScopeNote)
        XCTAssertTrue(keepDisksAwakeSettingsScopeNote.contains("from now on"),
                      "a session's request is fixed when it starts; this cannot reach a running "
                      + "one: " + keepDisksAwakeSettingsScopeNote)
        XCTAssertTrue(keepDisksAwakeSettingsScopeNote.contains(keepDisksAwakeFlag),
                      "the command line asks per session, and the note should name the flag: "
                      + keepDisksAwakeSettingsScopeNote)
    }
}

/// What the menu says about the disk axis — and, more to the point, where it
/// deliberately says nothing.
final class MenuDiskAxisCopyTests: XCTestCase {
    /// **Nothing on a live session's row.** `menuWakeModeTag`'s rule is
    /// "annotate the exception, not the rule", and its doc comment adds the
    /// stricter one this follows: a row describes **this session**, never the
    /// machine. The lid tag survives that rule because a session really does
    /// individually give up surviving a lid close. The disk assertion has no
    /// per-session meaning at all — it does nothing *to* the session, only to
    /// the machine, and the machine holds it if **any** live session asked. So a
    /// per-session disk badge would be a machine claim on a row that means "this
    /// session", which is precisely the error the lid tag was scoped to avoid.
    ///
    /// This is also the answer to "why does my session's row not say it is
    /// holding disks awake": because the row cannot say it truthfully, and
    /// `pmset -g assertions` can.
    func testALiveSessionsRowSaysNothingAboutDisks() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for mode in WakeMode.allCases {
            for disks in [false, true] {
                let session = Session(id: UUID(), kind: .indefinite,
                                      owner: ClientID(rawValue: "app-501"), ownerUID: 501,
                                      persistence: .clientBound, origin: .manual, startedAt: t0,
                                      triggerID: nil, wakeMode: mode, keepsDisksAwake: disks)
                let rows = [menuStopLabel(for: session, isOnlyOneOfYours: true, now: t0),
                            menuStopLabel(for: session, isOnlyOneOfYours: false, now: t0)]
                    + MenuSessionGroup.allCases.map {
                        menuSessionLabel(for: session, group: $0, now: t0)
                    }
                for row in rows {
                    XCTAssertFalse(row.lowercased().contains("disk"),
                                   "\(mode.rawValue)/disks=\(disks): a row describes one session, "
                                   + "and this axis has no per-session meaning: \(row)")
                }
            }
        }
    }

    /// **Something on a start row, and only when the stored default is on.**
    /// The argument is the one that put the wake-mode tag on `menuStartLabel`:
    /// these rows are a promise about what the button is *about to do*, the
    /// stored default is what it will do, and it costs nothing in the
    /// overwhelmingly common case because the tag is empty when the default is
    /// off.
    func testTheStartRowsSayWhenTheStoredDefaultHoldsDisksAwake() {
        for kind in DefaultSessionKind.allCases {
            let off = menuStartLabel(kind, wakeMode: .clamshell, keepsDisksAwake: false)
            let on = menuStartLabel(kind, wakeMode: .clamshell, keepsDisksAwake: true)
            XCTAssertFalse(off.lowercased().contains("disk"),
                           "the default is off, so the common row carries nothing extra: \(off)")
            XCTAssertTrue(on.lowercased().contains("disk"),
                          "a stored default that holds disks awake must be named on the button "
                          + "that acts on it: \(on)")
        }
    }

    /// Two tags, one parenthetical. A row reading "… (lid open only) (disks
    /// stay awake)" is the accumulation the menu was rebuilt to remove.
    func testTwoTagsShareOneParentheticalRatherThanStackingUp() {
        let both = menuStartLabel(.indefinite, wakeMode: .system, keepsDisksAwake: true)
        XCTAssertEqual(both.filter { $0 == "(" }.count, 1, both)
        XCTAssertTrue(both.contains("lid open only"), both)
        XCTAssertTrue(both.lowercased().contains("disk"), both)
    }
}

/// The copy in the CLI & Advanced tab's first section.
///
/// `AdvancedSettingsPlaceholderTests` was here — two tests over the sentence
/// the tab showed while it had no controls in it. The tab has a control now and
/// the sentence is gone, so they went with it rather than being weakened into
/// passing.
final class CLIInstallCopyTests: XCTestCase {
    private let link = "/usr/local/bin/keepy-uppy"
    private let binary = "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy"

    private var everyState: [CLIInstallState] {
        [.notInstalled, .installed,
         .linkedElsewhere(target: "/opt/homebrew/bin/keepy-uppy"),
         .dangling(target: "/Users/x/Downloads/Keepy Uppy.app/Contents/MacOS/keepy-uppy"),
         .occupied]
    }

    /// Five states, five different sentences. A pane whose text does not change
    /// with the state is a pane that is describing something other than this
    /// Mac.
    func testEveryStateGetsItsOwnSentence() {
        let sentences = everyState.map { cliInstallStatusSentence($0, linkPath: link) }
        XCTAssertEqual(Set(sentences).count, sentences.count, "\(sentences)")
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertTrue(sentence.contains(link), "every sentence names the path: \(sentence)")
        }
    }

    /// "Installed" is a claim about *this* copy, not about some `keepy-uppy`.
    /// A machine with two copies of the app is the case that makes the
    /// difference visible, and it is the case the sentence has to survive.
    func testOnlyTheInstalledSentenceClaimsTheLinkIsThisCopy() {
        for state in everyState {
            let sentence = cliInstallStatusSentence(state, linkPath: link)
            let claims = sentence.lowercased().contains("points at this copy")
            XCTAssertEqual(claims, state == .installed, sentence)
        }
    }

    /// The three states this app will not act on say so *and say why*. "Won't"
    /// on its own reads as a malfunction.
    func testTheStatesThisAppWillNotTouchSayThatAndWhy() {
        for state in [CLIInstallState.linkedElsewhere(target: "/somewhere/else"),
                      .dangling(target: "/gone"),
                      .occupied] {
            let sentence = cliInstallStatusSentence(state, linkPath: link)
            XCTAssertTrue(sentence.contains("won't"), sentence)
        }
    }

    // MARK: The command strings

    /// The whole reason `shellSingleQuoted` exists. Unquoted, a shell splits
    /// `/Applications/Keepy Uppy.app/…` into two words and `ln -s` makes a link
    /// called `Keepy` — as root, from a command this pane handed over.
    func testTheFallbackCommandQuotesAPathWithSpaces() {
        let command = cliInstallCommand(binaryPath: binary, linkPath: link)
        XCTAssertTrue(command.contains("'\(binary)'"), command)
        XCTAssertTrue(command.contains("'\(link)'"), command)
        XCTAssertTrue(command.contains("'/usr/local/bin'"), command)
        // Printed, because this assertion is the weak half of the proof and
        // knows it: it checks that quotes were *written*, not that a shell
        // parses the result as one word. `CLIInstallationRealFilesystemTests`
        // hands the string to a real `/bin/sh`; this line is so that the exact
        // characters of the shipping-layout command are legible in a log
        // without anyone retyping them.
        print("shipping-layout command: \(command)")
    }

    /// `mkdir -p` before the link, because `/usr/local/bin` may be absent and
    /// `/usr/local` is not user-writable either — so the directory cannot be
    /// created by a separate unprivileged step.
    func testTheFallbackCommandCreatesTheDirectoryFirst() {
        let command = cliInstallCommand(binaryPath: binary, linkPath: link)
        guard let mkdirRange = command.range(of: "mkdir -p"),
              let linkRange = command.range(of: "ln -s") else {
            return XCTFail("both halves have to be there: \(command)")
        }
        XCTAssertTrue(mkdirRange.lowerBound < linkRange.lowerBound, command)
    }

    /// No `-f` on the install command. A plain `ln -s` fails loudly when
    /// something is already at the path, which is the same rule the app itself
    /// follows: never overwrite silently.
    func testTheInstallCommandRefusesToOverwrite() {
        let command = cliInstallCommand(binaryPath: binary, linkPath: link)
        XCTAssertFalse(command.contains("ln -sf"), command)
        XCTAssertFalse(command.contains("ln -sfh"), command)
        XCTAssertTrue(command.contains("ln -s '"), command)
    }

    /// And `-h` wherever `-f` appears: `ln -sf` onto a symlink that points at a
    /// **directory** creates the link inside it instead of replacing it.
    func testTheReplaceCommandForcesAndDoesNotFollowTheOldLink() {
        let command = cliReplaceCommand(binaryPath: binary, linkPath: link)
        XCTAssertTrue(command.contains("ln -sfh"), command)
    }

    /// Every command is `sudo`-prefixed, because none of them can work without
    /// it on the directory they target.
    func testEveryCommandThisPaneHandsOverAsksForRoot() {
        for command in [cliInstallCommand(binaryPath: binary, linkPath: link),
                        cliReplaceCommand(binaryPath: binary, linkPath: link),
                        cliRemoveCommand(linkPath: link)] {
            XCTAssertTrue(command.hasPrefix("sudo "), command)
        }
    }

    // MARK: Quoting, which is the part a shell reads

    /// Total quoting, not "we remembered the space". A file name may legally
    /// contain a `$`, a backtick, a `"` and a `'`, and all but the last survive
    /// single quotes untouched.
    func testSingleQuotingSurvivesEveryCharacterAShellWouldInterpret() {
        XCTAssertEqual(shellSingleQuoted("/a b"), "'/a b'")
        XCTAssertEqual(shellSingleQuoted("/a$b`c\"d\\e"), "'/a$b`c\"d\\e'")
        XCTAssertEqual(shellSingleQuoted("/it's"), "'/it'\\''s'")
    }

    /// The nested form needs double quotes, which interpret four characters —
    /// so those four are escaped and nothing else is.
    func testDoubleQuotingEscapesExactlyWhatDoubleQuotesInterpret() {
        XCTAssertEqual(shellDoubleQuoted("/a b"), "\"/a b\"")
        XCTAssertEqual(shellDoubleQuoted("/a$b"), "\"/a\\$b\"")
        XCTAssertEqual(shellDoubleQuoted("/a`b"), "\"/a\\`b\"")
        XCTAssertEqual(shellDoubleQuoted("/a\"b"), "\"/a\\\"b\"")
        XCTAssertEqual(shellDoubleQuoted("/a\\b"), "\"/a\\\\b\"")
        XCTAssertEqual(shellDoubleQuoted("/it's"), "\"/it's\"")
    }

    // MARK: What it does and does not buy

    /// **The claim this pane is most likely to be read as making, and cannot.**
    /// `ssh host 'keepy-uppy on'` runs in a shell whose `PATH` never includes
    /// `/usr/local/bin` — measured — so it fails today and still fails after
    /// this ships. The pane is the surface somebody reads immediately before
    /// trying exactly that.
    func testThePaneSaysTheLinkDoesNotMakeTheBareNameWorkOverSSH() {
        let note = cliRemoteInvocationNote.lowercased()
        XCTAssertTrue(note.contains("ssh"), cliRemoteInvocationNote)
        XCTAssertTrue(note.contains("doesn't") || note.contains("does not"), cliRemoteInvocationNote)
        XCTAssertTrue(note.contains("/usr/local/bin"), cliRemoteInvocationNote)
    }

    /// Saying "that doesn't work" without saying what does is a diagnosis, and
    /// the user came for an answer. Both measured-working forms are offered.
    func testItOffersTheTwoFormsThatDoWorkRemotely() {
        let forms = cliRemoteInvocationForms(binaryPath: binary)
        XCTAssertEqual(forms.count, 2)
        XCTAssertEqual(forms[0], "ssh mac-mini 'zsh -lc \"keepy-uppy on --for 8h\"'")
        XCTAssertEqual(forms[1],
                       "ssh mac-mini '\"/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy\" on --for 8h'")
    }

    /// The second form names the bundle the user is actually running, not a
    /// literal `/Applications`. Somebody running from `~/Downloads` gets a
    /// command that works for them.
    func testTheAbsolutePathFormNamesThisBundleRatherThanApplications() {
        let elsewhere = "/Users/x/Downloads/Keepy Uppy.app/Contents/MacOS/keepy-uppy"
        let forms = cliRemoteInvocationForms(binaryPath: elsewhere)
        XCTAssertTrue(forms[1].contains(elsewhere), forms[1])
        XCTAssertFalse(forms[1].contains("/Applications/"), forms[1])
    }

    /// The two verbs the link cannot serve, named in the pane rather than left
    /// to the README — and described as *refusing*, which is what the CLI now
    /// does, rather than as "may not work".
    func testThePaneNamesTheTwoVerbsTheLinkCannotServe() {
        let note = cliSetupThroughLinkNote.lowercased()
        XCTAssertTrue(note.contains("setup"), cliSetupThroughLinkNote)
        XCTAssertTrue(note.contains("reset"), cliSetupThroughLinkNote)
        XCTAssertTrue(note.contains("refuse"), cliSetupThroughLinkNote)
    }

    /// The footer claims the link follows an app update and breaks on a move,
    /// which is what a symlink into a bundle actually does — and is the reason
    /// nothing is copied.
    func testTheFooterSaysNothingIsCopied() {
        let footnote = cliInstallSectionFootnote(linkPath: link).lowercased()
        XCTAssertTrue(footnote.contains(link), footnote)
        XCTAssertTrue(footnote.contains("nothing is copied"), footnote)
    }

    // MARK: Prompts

    /// A refused write must produce the command, not a dead end.
    func testARefusedInstallPromptsWithTheCommand() {
        let command = cliInstallCommand(binaryPath: binary, linkPath: link)
        let prompt = cliPrompt(after: CLIInstallResult.needsPrivilege(command: command))
        XCTAssertEqual(prompt?.command, command)
        XCTAssertFalse(prompt?.note.isEmpty ?? true)
    }

    func testARefusedRemovePromptsWithTheCommand() {
        let command = cliRemoveCommand(linkPath: link)
        let prompt = cliPrompt(after: CLIRemoveResult.needsPrivilege(command: command))
        XCTAssertEqual(prompt?.command, command)
    }

    /// Success says nothing extra: the status sentence above the button is
    /// already both the outcome and the evidence.
    func testSuccessAddsNoSecondSentence() {
        XCTAssertNil(cliPrompt(after: CLIInstallResult.installed))
        XCTAssertNil(cliPrompt(after: CLIInstallResult.alreadyInstalled))
        XCTAssertNil(cliPrompt(after: CLIRemoveResult.removed))
        XCTAssertNil(cliPrompt(after: CLIRemoveResult.nothingToRemove))
    }

    /// A press that changed nothing must not be silent — and must not hand over
    /// a command that would clobber whatever appeared at the path.
    func testABlockedPressSaysSoAndOffersNoCommand() {
        let prompt = cliPrompt(after: CLIInstallResult.blocked(.occupied))
        XCTAssertNotNil(prompt)
        XCTAssertNil(prompt?.command)
        XCTAssertNil(cliPrompt(after: CLIRemoveResult.refused(.linkedElsewhere(target: "/x")))?.command)
    }

    /// The should-be-unreachable branch still has words, because the
    /// alternative is believing a call that returned without throwing.
    func testAnUnverifiedWriteSaysItReadItBackAndDisagreed() {
        XCTAssertEqual(cliPrompt(after: CLIInstallResult.createdButNotVerified(.occupied))?.note,
                       cliUnverifiedNote)
        XCTAssertEqual(cliPrompt(after: CLIRemoveResult.removedButStillThere(.occupied))?.note,
                       cliUnverifiedNote)
    }
}

// MARK: - Notifications

/// The Settings surface for the two notifications, and the sentence a refused
/// grant gets.
///
/// Spec §4: ask lazily, at first use; degrade honestly; never require it. **A
/// refused grant must not silently mean "nothing happens with no visible
/// reason"** — the discipline Plan 5 designed for a refused Location grant,
/// applied a second time so that both read the same. (Notifications are the
/// only other grant in this project. Plan 6's Accessibility surface went with
/// the jiggler when it was cut, and the notification grant is not TCC at all —
/// `tccd`'s own service-string table has no entry for it, so the
/// helper-attributed-to-the-enclosing-bundle finding from Plan 6 does not
/// govern here. What governs is that the agent's `bundleIdentifier` is its own,
/// which would make an agent-held centre a second, separately-refusable client
/// in System Settings.)
final class NotificationAuthorizationCopyTests: XCTestCase {
    /// Written over the enum rather than over the three states anybody thought
    /// of. A `switch` that misses one is a blank line under a toggle.
    func testEveryAuthorizationStateHasASentence() {
        var sentences: Set<String> = []
        for state in NotificationAuthorization.allCases {
            let sentence = notificationAuthorizationSentence(state)
            XCTAssertGreaterThan(sentence.count, 30, "\(state) has no real sentence: \(sentence)")
            XCTAssertTrue(sentence.hasSuffix("."), "\(state): \(sentence)")
            XCTAssertFalse(sentence.contains("UNAuthorization"),
                           "\(state) names the framework's vocabulary: \(sentence)")
            sentences.insert(sentence)
        }
        XCTAssertEqual(sentences.count, NotificationAuthorization.allCases.count,
                       "two states sharing a sentence is a state the user cannot act on")
    }

    /// **The one that matters.** A toggle that is ON while the grant is denied
    /// must say so — the "on but doing nothing" failure, in the one place this
    /// project still has a grant to be refused.
    func testAnEnabledToggleWithADeniedGrantReportsThatItIsNotWorking() {
        guard let note = notificationStatusNote(state: .denied, anyToggleOn: true) else {
            return XCTFail("a denied grant under an enabled toggle must say something")
        }
        let sentence = note.sentence.lowercased()
        XCTAssertTrue(sentence.contains("system settings"),
                      "it has to name where the fix is: \(sentence)")
        XCTAssertTrue(sentence.contains("won't") || sentence.contains("nothing"),
                      "it has to say the toggle above it is not doing anything: \(sentence)")
        XCTAssertTrue(note.offersSystemSettings,
                      "naming System Settings without offering to open it is half the affordance")
    }

    /// Nothing switched on is not a problem, and a pane that reports one is a
    /// nag. This is the difference between "degrade honestly" and "ask again".
    func testNothingIsReportedWhileBothTogglesAreOff() {
        for state in NotificationAuthorization.allCases {
            XCTAssertNil(notificationStatusNote(state: state, anyToggleOn: false),
                         "\(state) is nobody's problem while nothing is switched on")
        }
    }

    /// A working grant under an enabled toggle says nothing either: the toggle
    /// being on is already the report.
    func testAWorkingGrantSaysNothing() {
        XCTAssertNil(notificationStatusNote(state: .authorized, anyToggleOn: true))
    }

    /// Every other state under an enabled toggle *is* reported, written over
    /// the enum so a sixth state cannot arrive and be silently treated as fine.
    func testEveryStateThatIsNotWorkingIsReported() {
        for state in NotificationAuthorization.allCases where state != .authorized {
            XCTAssertNotNil(notificationStatusNote(state: state, anyToggleOn: true),
                            "\(state) leaves a toggle on with nothing to explain it")
        }
    }

    /// ..."you have not been asked yet" is a different sentence from "you said
    /// no", because the action that fixes them is different: one is a toggle in
    /// this pane, the other is a switch in System Settings.
    func testNotDeterminedAndDeniedReadDifferently() {
        let notDetermined = notificationAuthorizationSentence(.notDetermined)
        let denied = notificationAuthorizationSentence(.denied)
        XCTAssertNotEqual(notDetermined, denied)
        XCTAssertTrue(denied.lowercased().contains("system settings"), denied)
        XCTAssertFalse(notDetermined.lowercased().contains("system settings"),
                       "nobody has been asked yet, so System Settings is not where the fix is: "
                       + notDetermined)
        // ...and the affordance follows the fix rather than being offered on
        // every non-working state alike.
        XCTAssertEqual(notificationStatusNote(state: .denied, anyToggleOn: true)?.offersSystemSettings,
                       true)
        XCTAssertEqual(
            notificationStatusNote(state: .notDetermined, anyToggleOn: true)?.offersSystemSettings,
            false, "the fix for “not asked yet” is in this pane, not in that one")
    }

    /// The deep link, pinned. Verified against this machine rather than
    /// remembered: `/System/Library/ExtensionKit/Extensions/NotificationsSettings.appex`
    /// carries `CFBundleIdentifier = com.apple.Notifications-Settings.extension`
    /// and `allowsXAppleSystemPreferencesURLScheme = true` on macOS 26.2
    /// (25C56). A deep link that lands on the wrong pane is worse than a
    /// sentence telling the user where to go.
    func testTheSystemSettingsLinkNamesTheNotificationsPane() {
        XCTAssertEqual(notificationSettingsURL,
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        XCTAssertNotNil(URL(string: notificationSettingsURL),
                        "a URL the app cannot even parse opens nothing at all")
    }
}

/// The two toggles' labels and the section's footer.
final class NotificationSettingsCopyTests: XCTestCase {
    /// The stop toggle is scoped to the user's own sessions, exactly as the
    /// banner it switches on is. `listSessions` is unfiltered and a Mac can
    /// have two people logged in, so "when this Mac stops being kept awake" is
    /// a machine claim this event cannot make — the same union-sensitivity
    /// argument as `menuLidCaveat`.
    func testTheToggleLabelsAreDistinctAndTheStopOneIsScopedToYourSessions() {
        XCTAssertNotEqual(notifyWhenStoppedTitle, notifyWhenTriggerStartsTitle)
        XCTAssertTrue(notifyWhenStoppedTitle.lowercased().contains("yours")
                        || notifyWhenStoppedTitle.lowercased().contains("your"),
                      "another account's session may still hold the Mac awake: "
                      + notifyWhenStoppedTitle)
        XCTAssertTrue(notifyWhenTriggerStartsTitle.lowercased().contains("trigger"),
                      notifyWhenTriggerStartsTitle)
    }

    /// Limitation 1, stated in the copy rather than discovered. The app is the
    /// notifier — it has the UI that can ask, the run loop that can present and
    /// a lifetime the user understands, none of which is true of the UI-less
    /// agent — so a session that ends overnight with the menu bar app quit
    /// produces no notification. That is the correct trade and it has to be
    /// said, because the alternative is a user concluding the feature is broken.
    func testTheFooterSaysNothingIsAnnouncedWhileTheAppIsNotRunning() {
        let footnote = notificationsSectionFootnote.lowercased()
        XCTAssertTrue(footnote.contains("running") || footnote.contains("quit"), footnote)
        XCTAssertTrue(footnote.contains("keepy uppy") || footnote.contains("menu bar"), footnote)
    }

    /// Limitation 2, and the one most likely to be filed as a bug. Task 6's
    /// suppression makes "stopping a session yourself here is not announced"
    /// true; the second half follows from the app being unable to tell a
    /// `keepy-uppy off` from an expiry or a safety stop. Said plainly, because
    /// a user who has just learned that clicking Stop produces no banner and
    /// then gets one for typing `off` will otherwise read it as a defect.
    func testTheFooterSaysWhichStopsAreAnnouncedAndWhichAreNot() {
        let footnote = notificationsSectionFootnote
        XCTAssertTrue(footnote.contains("keepy-uppy off") || footnote.lowercased().contains("terminal"),
                      "the command-line stop is the one that surprises people: " + footnote)
        XCTAssertTrue(footnote.lowercased().contains("yourself")
                        || footnote.lowercased().contains("you stop"),
                      "the suppression has to be stated, not merely implemented: " + footnote)
    }

    /// The footer must not imply the app knows why anything ended, in the one
    /// place where explaining the command-line case invites exactly that.
    func testTheFooterDoesNotClaimTheAppCanTellWhyASessionEnded() {
        let footnote = notificationsSectionFootnote.lowercased()
        for overclaim in ["knows why", "tells you why", "the reason it stopped"]
        where footnote.contains(overclaim) {
            XCTFail("nothing outside the daemon knows why a session ended: " + footnote)
        }
    }

    /// **Signposted in both directions.** The three ways of being told a
    /// session ended are now split across two tabs, and an unsignposted split
    /// is how a user concludes a feature was removed. One-directional
    /// signposting only helps the user who happened to start on the right tab.
    func testTheTwoTabsSignpostEachOther() {
        XCTAssertTrue(notificationsTriggersSignpost.contains("Triggers"),
                      notificationsTriggersSignpost)
        XCTAssertTrue(notificationsTriggersSignpost.contains("On Session End"),
                      notificationsTriggersSignpost)
        XCTAssertTrue(sessionEndActionsNotificationsSignpost.contains("General"),
                      sessionEndActionsNotificationsSignpost)
        XCTAssertTrue(sessionEndActionsNotificationsSignpost.contains("Notifications"),
                      sessionEndActionsNotificationsSignpost)
    }

    /// The Triggers footer keeps saying what it always said — this task adds a
    /// line beside it, it does not replace one.
    func testTheSessionEndActionsFootnoteStillSaysWhatItFiresFor() {
        let footnote = sessionEndActionsFootnote.lowercased()
        XCTAssertTrue(footnote.contains("script"), footnote)
        XCTAssertTrue(footnote.contains("webhook"), footnote)
        XCTAssertTrue(footnote.contains("any"),
                      "it fires for every session ending, not only trigger-started ones: "
                      + footnote)
    }
}

/// **Every preference the app has, written and read back.**
///
/// This exists because of what the five-tab restructure could break without
/// the compiler, the diff, or the eye noticing. Moving a control into a new
/// `View` and losing its binding on the way — a `@State` where an
/// `@AppStorage` was, a dropped `store:`, a key literal pasted from the
/// control above it — produces a pane that compiles, renders correctly, and
/// silently stops persisting, while a mechanical diff stays clean because the
/// key is still spelled the same.
///
/// It is not a view test and cannot be one: `@AppStorage` only resolves inside
/// a `View`'s update cycle, so nothing here can prove that
/// `DisplaySettingsTab`'s toggle is wired to this key rather than to a fresh
/// local variable. What it does pin is everything underneath that line — that
/// each key still reads back what was written to it, through the same type the
/// UI reads it through, and that no two preferences share storage — so a
/// restructure that lands a real preference on a real key cannot also have
/// broken the round trip. The wiring itself is checked by reading the diff
/// (the `@AppStorage` lines moved verbatim) and by the manual checklist.
final class SettingsPreferenceRoundTripTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Same guarantee the other suites take: this refuses to clear the
        // shipping domain, which this test host would otherwise be.
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    private var defaults: UserDefaults { PreferencesSuite.defaults }

    /// One preference: how the UI writes it, and what the UI reads back.
    /// Deliberately spelled out per preference rather than derived, because
    /// the thing being pinned is exactly the pairing of a key with a type.
    private struct PreferenceUnderTest {
        let name: String
        let write: () -> Void
        let readsBackWhatWasWritten: () -> Bool
    }

    /// Every preference this app persists, in tab order. Add a row here when a
    /// task adds a preference; the independence test below is only as complete
    /// as this list.
    private var allPreferences: [PreferenceUnderTest] {
        [
            // General — the default session kind. Not the fallback, so an
            // unwritten preference cannot pass this by accident.
            PreferenceUnderTest(
                name: DefaultSessionKindPreference.key,
                write: { self.defaults.set(DefaultSessionKind.fourHours.rawValue,
                                           forKey: DefaultSessionKindPreference.key) },
                readsBackWhatWasWritten: {
                    DefaultSessionKindPreference.kind(
                        rawValue: self.defaults.string(forKey: DefaultSessionKindPreference.key) ?? "")
                        == .fourHours
                }
            ),
            // Display — the wake mode. Not the fallback, so an unwritten
            // preference cannot pass this by accident.
            PreferenceUnderTest(
                name: DefaultWakeModePreference.key,
                write: { self.defaults.set(WakeMode.systemAndDisplay.rawValue,
                                           forKey: DefaultWakeModePreference.key) },
                readsBackWhatWasWritten: {
                    DefaultWakeModePreference.mode(
                        rawValue: self.defaults.string(forKey: DefaultWakeModePreference.key) ?? "")
                        == .systemAndDisplay
                }
            ),
            // Display — the disk axis. `true`, again the opposite of the
            // fallback.
            PreferenceUnderTest(
                name: DefaultKeepDisksAwakePreference.key,
                write: { self.defaults.set(true, forKey: DefaultKeepDisksAwakePreference.key) },
                readsBackWhatWasWritten: {
                    (self.defaults.object(forKey: DefaultKeepDisksAwakePreference.key) as? Bool
                        ?? DefaultKeepDisksAwakePreference.fallback) == true
                }
            ),
            // General — the two notification toggles. `true` for both, which is
            // the opposite of their fallback, so neither can pass by accident.
            PreferenceUnderTest(
                name: SessionNotificationPreference.stopKey,
                write: { self.defaults.set(true, forKey: SessionNotificationPreference.stopKey) },
                readsBackWhatWasWritten: { SessionNotificationPreference.load().onStop }
            ),
            PreferenceUnderTest(
                name: SessionNotificationPreference.triggerStartKey,
                write: {
                    self.defaults.set(true, forKey: SessionNotificationPreference.triggerStartKey)
                },
                readsBackWhatWasWritten: { SessionNotificationPreference.load().onTriggerStart }
            ),
            // CLI & Advanced — the two global shortcuts, one row each.
            //
            // Both rows matter more than most here. The two keys are the only
            // pair in this list that were introduced together, by one task, in
            // one file — which is exactly the shape that produces two controls
            // sharing a key — and the symptom would be a Settings pane where
            // setting either shortcut silently rebinds the other. Two absurd
            // combinations, distinct from each other, so neither row can pass
            // by reading the other's value.
            PreferenceUnderTest(
                name: HotKeyAction.startDefaultSession.preferenceKey,
                write: {
                    HotKeyPreference.setBinding(Self.distinctiveStartBinding,
                                                for: .startDefaultSession, in: self.defaults)
                },
                readsBackWhatWasWritten: {
                    HotKeyPreference.binding(for: .startDefaultSession, in: self.defaults)
                        == Self.distinctiveStartBinding
                }
            ),
            PreferenceUnderTest(
                name: HotKeyAction.stopAppSessions.preferenceKey,
                write: {
                    HotKeyPreference.setBinding(Self.distinctiveStopBinding,
                                                for: .stopAppSessions, in: self.defaults)
                },
                readsBackWhatWasWritten: {
                    HotKeyPreference.binding(for: .stopAppSessions, in: self.defaults)
                        == Self.distinctiveStopBinding
                }
            ),
            // Safety & Guards — every field of it, through its own store.
            PreferenceUnderTest(
                name: "safetyConfig",
                write: { SafetyConfigStore.save(Self.distinctiveSafetyConfig) },
                readsBackWhatWasWritten: { SafetyConfigStore.load() == Self.distinctiveSafetyConfig }
            ),
            // Triggers — the rule list.
            PreferenceUnderTest(
                name: TriggerStore.key,
                write: { TriggerStore.save([Self.distinctiveRule]) },
                readsBackWhatWasWritten: { TriggerStore.load() == [Self.distinctiveRule] }
            ),
            // Triggers — "On Session End". A script path and a webhook URL,
            // which are the two values a user notices losing.
            PreferenceUnderTest(
                name: "sessionCompletionConfig",
                write: { SessionCompletionStore.save(Self.distinctiveCompletionConfig) },
                readsBackWhatWasWritten: {
                    SessionCompletionStore.load() == Self.distinctiveCompletionConfig
                }
            ),
        ]
    }

    /// `kVK_F20` and `kVK_F19` with all four modifiers — combinations nothing
    /// ships, and distinct from each other so the two rows above cannot pass by
    /// reading one another.
    private static let distinctiveStartBinding = HotKeyBinding(
        keyCode: 0x5A, modifiers: [.control, .option, .shift, .command])
    private static let distinctiveStopBinding = HotKeyBinding(
        keyCode: 0x50, modifiers: [.control, .option, .shift, .command])

    private static let distinctiveSafetyConfig = SafetyConfig(
        thermalSensitivity: .cautious, batteryCutoff: 37, maxSessionDuration: 3 * 3600,
        lidClosedStricter: false, gracePeriod: 42, cooldown: 43, batteryHysteresis: 7)

    private static let distinctiveRule = TriggerRule(
        id: UUID(uuidString: "8A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!,
        condition: .processRunning(processName: "claude"),
        defaultKind: .eightHours, enabled: false)

    private static let distinctiveCompletionConfig = SessionCompletionConfig(
        scriptPath: "/usr/local/bin/tell-me.sh", webhookURL: "https://example.com/hook")

    /// The round trip itself, one preference at a time: write a value that is
    /// not the default, read it back through the type the UI reads it through.
    func testEveryPreferenceRoundTripsThroughItsOwnType() {
        for preference in allPreferences {
            XCTAssertFalse(preference.readsBackWhatWasWritten(),
                           "\(preference.name): the test value equals the unwritten default, so "
                           + "this test would pass without persisting anything")
            preference.write()
            XCTAssertTrue(preference.readsBackWhatWasWritten(),
                          "\(preference.name) did not survive the round trip")
        }
    }

    /// The copy-paste failure a restructure actually makes: a control lands in
    /// a new file with the key of the control above it, so two settings fight
    /// over one value. Writing each preference in turn must leave every other
    /// preference exactly as it was.
    func testWritingOnePreferenceDisturbsNoOther() {
        let preferences = allPreferences
        for preference in preferences { preference.write() }
        for preference in preferences {
            XCTAssertTrue(preference.readsBackWhatWasWritten(),
                          "\(preference.name) lost its value to another preference's write — "
                          + "two controls are sharing one key")
        }
    }

    /// Nothing written: every preference answers with its documented default
    /// rather than with an empty value. This is what a brand-new user gets,
    /// and it is the state a mis-keyed control also produces — so the two
    /// tests above are read together with this one.
    func testAnUnwrittenSuiteReadsBackTheDocumentedDefaults() {
        XCTAssertNil(defaults.string(forKey: DefaultSessionKindPreference.key))
        XCTAssertEqual(
            DefaultSessionKindPreference.kind(
                rawValue: defaults.string(forKey: DefaultSessionKindPreference.key) ?? ""),
            DefaultSessionKindPreference.fallback)
        XCTAssertEqual(SessionNotificationPreference.load(),
                       SessionNotificationPreferences(onStop: false, onTriggerStart: false))
        XCTAssertEqual(
            DefaultWakeModePreference.mode(
                rawValue: defaults.string(forKey: DefaultWakeModePreference.key) ?? ""),
            DefaultWakeModePreference.fallback)
        XCTAssertEqual(
            defaults.object(forKey: DefaultKeepDisksAwakePreference.key) as? Bool
                ?? DefaultKeepDisksAwakePreference.fallback,
            DefaultKeepDisksAwakePreference.fallback)
        XCTAssertEqual(SafetyConfigStore.load(), .default)
        XCTAssertEqual(TriggerStore.load(), [])
        XCTAssertEqual(SessionCompletionStore.load(), SessionCompletionConfig())
    }

    /// The same guarantee, counted rather than listed: writing every
    /// preference into an empty suite must leave exactly one key per
    /// preference behind. Asked of the suite itself rather than of a list of
    /// key literals on purpose — half of these keys are `private` to their
    /// store, and a list of copies here would be a second place for them to
    /// be spelled, which is the failure `PreferencesSuite` exists to prevent.
    func testEveryPreferenceOccupiesExactlyOneKeyOfItsOwn() {
        let preferences = allPreferences
        XCTAssertEqual(storedKeys().count, 0, "setUp should have left an empty suite")
        for preference in preferences { preference.write() }
        XCTAssertEqual(storedKeys().count, preferences.count,
                       "\(preferences.count) preferences wrote \(storedKeys().count) keys "
                       + "(\(storedKeys().sorted())) — two of them are sharing storage")
    }

    /// The suite's own keys, and nothing else's: `dictionaryRepresentation()`
    /// would fold in every global default on the machine.
    private func storedKeys() -> Set<String> {
        Set((UserDefaults.standard.persistentDomain(forName: PreferencesSuite.name) ?? [:]).keys)
    }
}

// MARK: - The stored shortcuts

/// The preference behind the recorder. `HotKeyAction.preferenceKey` names the
/// two keys (Task 8); everything here is about the value stored under them and
/// about the one failure that matters — a stored string that no longer parses.
final class HotKeyPreferenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    private var defaults: UserDefaults { PreferencesSuite.defaults }

    private let binding = HotKeyBinding(
        keyCode: 0x5A, modifiers: [.control, .option, .shift, .command])

    /// **Unset is the default, and it has to be.** Every other preference in
    /// this app can afford a non-nil fallback; this one cannot, because its
    /// fallback would be a global keystroke nobody chose, armed on the surface
    /// with no feedback.
    func testNobodyHasAShortcutUntilTheySetOne() {
        for action in HotKeyAction.allCases {
            XCTAssertNil(HotKeyPreference.binding(for: action, in: defaults),
                         "\(action.rawValue) came with a shortcut nobody set")
        }
        XCTAssertTrue(HotKeyPreference.allBindings(in: defaults).isEmpty)
    }

    func testABindingRoundTripsThroughThePreference() {
        for action in HotKeyAction.allCases {
            HotKeyPreference.setBinding(binding, for: action, in: defaults)
            XCTAssertEqual(HotKeyPreference.binding(for: action, in: defaults), binding)
        }
        XCTAssertEqual(HotKeyPreference.allBindings(in: defaults).count,
                       HotKeyAction.allCases.count)
    }

    /// The key is `HotKeyAction.preferenceKey` and nothing else. Named once,
    /// there, for the reason `DefaultWakeModePreference.key` is: the pane that
    /// writes it and the centre that reads it are different files that never
    /// call each other, and a typo in either is not a compile error.
    func testThePreferenceUsesTheActionSOwnKeyAndNoOther() {
        for action in HotKeyAction.allCases {
            HotKeyPreference.setBinding(binding, for: action, in: defaults)
            XCTAssertEqual(defaults.string(forKey: action.preferenceKey), binding.storedForm)
            XCTAssertEqual(HotKeyPreference.key(for: action), action.preferenceKey)
        }
    }

    /// A distinct key per action, proven by behaviour rather than by comparing
    /// two strings: setting one must not disturb the other.
    func testEachActionHasItsOwnStorage() {
        let other = HotKeyBinding(keyCode: 0x50, modifiers: [.command, .shift])
        HotKeyPreference.setBinding(binding, for: .startDefaultSession, in: defaults)
        HotKeyPreference.setBinding(other, for: .stopAppSessions, in: defaults)

        XCTAssertEqual(HotKeyPreference.binding(for: .startDefaultSession, in: defaults), binding)
        XCTAssertEqual(HotKeyPreference.binding(for: .stopAppSessions, in: defaults), other)

        HotKeyPreference.setBinding(nil, for: .startDefaultSession, in: defaults)
        XCTAssertNil(HotKeyPreference.binding(for: .startDefaultSession, in: defaults))
        XCTAssertEqual(HotKeyPreference.binding(for: .stopAppSessions, in: defaults), other,
                       "clearing one shortcut cleared the other")
    }

    /// **An unparseable stored value is unset, never "some binding".** The
    /// tempting fallback — substitute a sensible combination — arms a global
    /// shortcut the user never chose. Compare `DefaultWakeModePreference`,
    /// which *does* fall back, because an unrecognised wake mode still has to
    /// produce a session whereas an unrecognised shortcut can simply not exist.
    func testAnUnparseableStoredValueReadsBackAsUnsetRatherThanAsSomeBinding() {
        for junk in ["", "   ", "nonsense", "{}", "null", "0", "{\"keyCode\":90}"] {
            defaults.set(junk, forKey: HotKeyAction.startDefaultSession.preferenceKey)
            XCTAssertNil(HotKeyPreference.binding(for: .startDefaultSession, in: defaults),
                         "\(junk) parsed into a binding")
            XCTAssertTrue(HotKeyPreference.allBindings(in: defaults).isEmpty)
        }
    }

    /// The two ways the UI can unset one — the Clear button writes an empty
    /// string through `@AppStorage`, `setBinding(nil:)` removes the key — read
    /// back identically. Otherwise "cleared" would mean two different things
    /// depending on which path cleared it.
    func testBothWaysOfClearingReadBackTheSame() {
        HotKeyPreference.setBinding(binding, for: .startDefaultSession, in: defaults)
        HotKeyPreference.setBinding(nil, for: .startDefaultSession, in: defaults)
        XCTAssertNil(HotKeyPreference.binding(for: .startDefaultSession, in: defaults))

        HotKeyPreference.setBinding(binding, for: .startDefaultSession, in: defaults)
        defaults.set("", forKey: HotKeyAction.startDefaultSession.preferenceKey)
        XCTAssertNil(HotKeyPreference.binding(for: .startDefaultSession, in: defaults))
    }

    /// A stored binding that cannot work is still *stored* — it reads back —
    /// and it is `hotKeyBindingProblem`'s job to refuse it, not this type's.
    /// Otherwise a hand-edited preference would vanish with no explanation
    /// anywhere, which is the same silence this feature is trying to remove.
    func testAStoredBindingThatCannotWorkStillReadsBackSoTheRowCanExplainIt() {
        let bare = HotKeyBinding(keyCode: 0x5A, modifiers: [])
        HotKeyPreference.setBinding(bare, for: .startDefaultSession, in: defaults)
        XCTAssertEqual(HotKeyPreference.binding(for: .startDefaultSession, in: defaults), bare)
        XCTAssertNotNil(hotKeyBindingProblem(bare))
    }
}

// MARK: - What the recorder says

/// **The copy is the whole product here.** `RegisterEventHotKey` cannot detect
/// the conflict users actually hit, so what this pane says about that gap is
/// the only thing standing between a silently dead shortcut and a user
/// concluding the app is broken.
final class HotKeyCopyTests: XCTestCase {
    /// Every row says what it will do, in words that match the scope the
    /// mechanism can actually honour.
    func testEveryActionHasAnExplanationDistinctFromEveryOther() {
        var explanations: Set<String> = []
        for action in HotKeyAction.allCases {
            let explanation = hotKeyActionExplanation(action)
            XCTAssertFalse(explanation.isEmpty, "\(action.rawValue) explains nothing")
            explanations.insert(explanation)
        }
        XCTAssertEqual(explanations.count, HotKeyAction.allCases.count)
    }

    /// The row for the stop action must not claim the sessions it will not
    /// stop. `stopAllSessions(all: false)` scopes to `app-<uid>`; this user's
    /// own trigger session (`agent-<uid>`) and CLI session (`cli-<uid>`) keep
    /// running, and this is the one surface with no feedback to reveal that.
    func testTheStopExplanationNamesWhatItLeavesRunning() {
        let explanation = hotKeyActionExplanation(.stopAppSessions).lowercased()
        XCTAssertTrue(explanation.contains("trigger") || explanation.contains("command line"),
                      "the stop row must say what it leaves running: \(explanation)")
        for overclaim in ["everything", "all sessions", "every session"] {
            XCTAssertFalse(explanation.contains(overclaim),
                           "the stop row claims \(overclaim), which it cannot do: \(explanation)")
        }
    }

    /// Every failure the centre can report becomes a sentence, and every one of
    /// them says what to do next. A row that names an error and offers no
    /// action is a row that reads as the app being broken.
    func testEveryRegistrationFailureSaysWhatHappenedAndWhatToDo() {
        let failures: [HotKeyRegistrationFailure] = [
            .unusableBinding("A shortcut needs at least one modifier key."),
            .alreadyTaken(hotKeyAlreadyTakenStatus),
            .refused(OSStatus(-50)),
            .noEventHandler(OSStatus(-50)),
        ]
        for failure in failures {
            let sentence = hotKeyRegistrationFailureSentence(failure)
            XCTAssertFalse(sentence.isEmpty, "\(failure) says nothing")
            XCTAssertTrue(sentence.count > 20, "\(failure) says too little: \(sentence)")
        }
        // The three that name a status must name it, because "it didn't work"
        // about an OSStatus nobody can see is not a bug report anybody can act
        // on.
        XCTAssertTrue(hotKeyRegistrationFailureSentence(.refused(OSStatus(-50))).contains("-50"))
        XCTAssertTrue(hotKeyRegistrationFailureSentence(.noEventHandler(OSStatus(-50))).contains("-50"))
    }

    /// The refused-binding case shows the recorder's own sentence rather than a
    /// second wording of it, so the pane cannot describe one rejection two
    /// different ways.
    func testARefusedBindingShowsTheSameSentenceTheRecorderWouldHave() {
        let problem = hotKeyBindingProblem(HotKeyBinding(keyCode: 0x5A, modifiers: []))
        XCTAssertNotNil(problem)
        XCTAssertEqual(hotKeyRegistrationFailureSentence(.unusableBinding(problem!)), problem)
    }

    /// The one failure `kEventHotKeyExclusive` *can* report. It must not be
    /// described as "macOS is using it", because that is the case this API is
    /// silent about — it means another `RegisterEventHotKey` client.
    func testTheAlreadyTakenSentenceBlamesAnotherAppRatherThanMacOS() {
        let sentence = hotKeyRegistrationFailureSentence(.alreadyTaken(hotKeyAlreadyTakenStatus))
        XCTAssertTrue(sentence.lowercased().contains("another app"), sentence)
        XCTAssertTrue(sentence.lowercased().contains("different") ||
                      sentence.lowercased().contains("another combination"), sentence)
    }

    /// **The standing note, and the reason this task exists in the shape it
    /// does.** `kEventHotKeyExclusive` detects another `RegisterEventHotKey`
    /// client holding the combination — the rarer case. It does not detect an
    /// app that swallows the key another way: the call returns `noErr`, the row
    /// shows success, and the shortcut silently never fires. Measured in
    /// `HotKeyRegistrationTests`, where ⌘Space registers cleanly.
    ///
    /// So the note has to say three things: that it can happen, that the app
    /// cannot tell, and what to do about it.
    func testTheStandingNoteSaysASilentlyDeadShortcutIsPossibleAndWhatToDo() {
        let note = hotKeySilentConflictNote.lowercased()
        XCTAssertTrue(note.contains("another app"),
                      "the note must name who takes the shortcut: \(note)")
        XCTAssertTrue(note.contains("nothing") || note.contains("won't work")
                      || note.contains("never"),
                      "the note must say the shortcut can silently do nothing: \(note)")
        XCTAssertTrue(note.contains("different") || note.contains("another one"),
                      "the note must say what to do: \(note)")
    }

    /// And it must not promise detection it cannot deliver. Saying "Keepy Uppy
    /// will tell you if a shortcut is taken" on the strength of
    /// `kEventHotKeyExclusive` would be a claim the mechanism does not support,
    /// and it is the claim a reader most naturally infers from an error row.
    func testTheStandingNoteDoesNotPromiseToDetectEveryConflict() {
        let note = hotKeySilentConflictNote.lowercased()
        for overclaim in ["will tell you", "will warn you", "always detect", "detects every",
                          "we check every"] {
            XCTAssertFalse(note.contains(overclaim),
                           "the note promises detection it cannot deliver: \(note)")
        }
        // It must be explicit that the app cannot see the conflict, not merely
        // vague about it.
        XCTAssertTrue(note.contains("can't tell") || note.contains("cannot tell")
                      || note.contains("can't see") || note.contains("cannot see"),
                      "the note must say plainly that the app cannot detect it: \(note)")
    }

    /// The part of "already taken" that *is* knowable — macOS's own symbolic
    /// hot keys, which `CopySymbolicHotKeys` enumerates. This sentence is
    /// shown for those, and it must not be confused with the exclusive-
    /// registration error above: nothing failed, the registration succeeded,
    /// and the key will simply never arrive.
    func testTheSystemShortcutWarningSaysTheKeyWillNeverArrive() {
        let warning = hotKeySystemConflictWarning.lowercased()
        XCTAssertTrue(warning.contains("macos"), warning)
        XCTAssertTrue(warning.contains("never") || warning.contains("won't reach")
                      || warning.contains("nothing"), warning)
        XCTAssertTrue(warning.contains("different") || warning.contains("another"), warning)
    }

    /// The section footer has to say the one thing that makes a *global*
    /// shortcut different from a menu shortcut, because the menu deliberately
    /// does not show these bindings (see `MenuContent`) and this is therefore
    /// the only place a user can learn it.
    func testTheSectionFootnoteSaysTheShortcutsWorkWithoutTheMenuBeingOpen() {
        let footnote = hotKeyShortcutsSectionFootnote.lowercased()
        XCTAssertTrue(footnote.contains("menu"), footnote)
        XCTAssertTrue(footnote.contains("any app") || footnote.contains("anywhere")
                      || footnote.contains("without"), footnote)
    }
}

// MARK: - Diagnostics

/// The CLI & Advanced tab's third section: two versions, whether the daemon is
/// answering, and the one command in this app whose exact characters matter to
/// a machine rather than to a person.
final class DiagnosticsCopyTests: XCTestCase {
    /// What this app would call itself. Written as a `bundleVersionText`
    /// result rather than as the literal `"0.1.0 (2)"` so that a change to the
    /// format cannot leave these tests asserting against a shape the product
    /// no longer produces.
    private let appVersion = bundleVersionText(shortVersion: "0.1.0", build: "2")
    /// The daemon a previous copy of this app registered, still running.
    private let olderDaemon = bundleVersionText(shortVersion: "0.1.0", build: "1")

    private var everyState: [DaemonReachability] {
        [.unasked, .unreachable, .reachable(version: appVersion),
         .reachable(version: olderDaemon)]
    }

    // MARK: How a version is written

    func testAVersionIsTheShortVersionAndTheBuildNumber() {
        XCTAssertEqual(bundleVersionText(shortVersion: "0.1.0", build: "2"), "0.1.0 (2)")
    }

    /// **The build number is the half that actually moves, and this is the
    /// test that earns its presence.** Every target in `project.yml` ships
    /// `MARKETING_VERSION: "0.1.0"` and has since the first commit, while
    /// `just bump` moves `CURRENT_PROJECT_VERSION` on every release — so a
    /// comparison on the short version alone reads *equal* for every pair of
    /// builds this project has ever produced, including the one pair this
    /// section exists to catch.
    func testTwoBuildsOfTheSameMarketingVersionAreToldApart() {
        XCTAssertNotEqual(bundleVersionText(shortVersion: "0.1.0", build: "1"),
                          bundleVersionText(shortVersion: "0.1.0", build: "2"))
    }

    /// No empty parentheses trailing a version nobody can read.
    func testAMissingBuildNumberDropsItsParenthesesRatherThanShowingAnEmptyPair() {
        XCTAssertEqual(bundleVersionText(shortVersion: "0.1.0", build: nil), "0.1.0")
        XCTAssertEqual(bundleVersionText(shortVersion: "0.1.0", build: ""), "0.1.0")
    }

    /// A bundle that cannot name its own version says so. The alternative is a
    /// blank where a version should be, which reads as a rendering failure
    /// rather than as missing information — and, worse, compares unequal to
    /// everything and would report a mismatch that isn't one.
    func testAnAbsentVersionSaysUnknownRatherThanNothing() {
        XCTAssertEqual(bundleVersionText(shortVersion: nil, build: nil), "unknown")
        XCTAssertEqual(bundleVersionText(shortVersion: "", build: nil), "unknown")
    }

    /// The app really does carry both keys. `Bundle.main` here is the test
    /// host — `Keepy Uppy.app` itself — so this is a check on the shipping
    /// `Info.plist`, not on a fixture.
    ///
    /// It cannot make the same check for the daemon, whose `Info.plist` is a
    /// `__TEXT,__info_plist` section in a binary the test target cannot reach;
    /// that half is verified by reading `project.yml` and by `otool`, and is
    /// recorded in this task's report.
    func testThisBuildCanNameItsOwnVersion() {
        let text = bundleVersionText(of: .main)
        XCTAssertNotEqual(text, "unknown", "the app's Info.plist has no CFBundleShortVersionString")
        XCTAssertTrue(text.contains("("), "the app's Info.plist has no CFBundleVersion: \(text)")
    }

    // MARK: The four states

    func testEveryStateGetsItsOwnSentenceAndItsOwnRowValue() {
        let sentences = everyState.map { daemonDiagnosticsSentence($0, appVersion: appVersion) }
        XCTAssertEqual(Set(sentences).count, sentences.count, "\(sentences)")
        let values = everyState.map(daemonVersionRowValue)
        XCTAssertEqual(Set(values).count, values.count, "\(values)")
        for text in sentences + values {
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// **"Nobody has asked yet" is not "nothing answered".** The same
    /// distinction `AppDelegate` draws when it drops the first `$sessions`
    /// value: an empty answer nobody asked for is not an answer that came back
    /// empty, and rendering it as one puts a fault report on screen for a
    /// daemon that is perfectly healthy.
    func testTheUnaskedStateReportsNoFault() {
        let sentence = daemonDiagnosticsSentence(.unasked, appVersion: appVersion).lowercased()
        for wordOfFailure in ["isn't", "can't", "not answering", "failed", "wrong"] {
            XCTAssertFalse(sentence.contains(wordOfFailure), sentence)
        }
        XCTAssertNotEqual(daemonVersionRowValue(.unasked), daemonVersionRowValue(.unreachable))
    }

    /// The row shows the daemon's own answer, verbatim. A restatement — "up to
    /// date", "current" — would be this app's opinion in the one place a bug
    /// report needs the daemon's own words.
    func testTheRowShowsWhateverTheDaemonSaidRatherThanAJudgementOfIt() {
        XCTAssertEqual(daemonVersionRowValue(.reachable(version: "9.9.9 (41)")), "9.9.9 (41)")
    }

    /// Two versions are named exactly when they differ. A matched sentence
    /// repeating the number already in the row above it is noise; a mismatched
    /// one that names only one of them cannot be acted on.
    func testOnlyTheMismatchSentenceNamesBothVersions() {
        for state in everyState {
            let sentence = daemonDiagnosticsSentence(state, appVersion: appVersion)
            let namesBoth = sentence.contains(appVersion) && sentence.contains(olderDaemon)
            XCTAssertEqual(namesBoth, state == .reachable(version: olderDaemon), sentence)
        }
    }

    /// The case the section exists for, end to end: an app updated in place
    /// while the daemon the *previous* copy registered is still the running
    /// process. Same marketing version, different build.
    func testASameVersionDifferentBuildDaemonReadsAsAMismatchAndNotAsAMatch() {
        XCTAssertNotEqual(
            daemonDiagnosticsSentence(.reachable(version: olderDaemon), appVersion: appVersion),
            daemonDiagnosticsSentence(.reachable(version: appVersion), appVersion: appVersion))
    }

    /// A mismatch is **not a failure**, and must not read as one: the wire
    /// format is deliberately version-tolerant in both directions
    /// (`HelperProtocol.startSession`'s doc comment), so sessions started
    /// against an older daemon work. It must still say what clears it, because
    /// a report with no next step reads as a defect.
    func testTheMismatchSentenceSaysWorkContinuesAndWhatClearsIt() {
        let sentence = daemonDiagnosticsSentence(.reachable(version: olderDaemon),
                                                 appVersion: appVersion)
        XCTAssertTrue(sentence.lowercased().contains("restart"), sentence)
        XCTAssertTrue(sentence.lowercased().contains("still work")
                      || sentence.lowercased().contains("still fine"), sentence)
    }

    /// **The one disagreement this pane will produce**, said before somebody
    /// files it: General ▸ Background Services can say "Running" — it asks
    /// `SMAppService` whether the job is *registered* — while this section says
    /// nothing is answering, because a registered job that has crashed, or one
    /// that refuses this app at the code-signing gate, is registered and
    /// unreachable at the same time.
    func testTheUnreachableSentencePointsAtTheStatusItWillDisagreeWith() {
        let sentence = daemonDiagnosticsSentence(.unreachable, appVersion: appVersion)
        XCTAssertTrue(sentence.contains("Background Services"), sentence)
    }

    /// **No copy in this section sends anybody at `keepy-uppy reset`, and no
    /// control here offers it.** This is Task 10's recorded decision, pinned so
    /// that "the pane could just offer a Reset button" has to delete a test
    /// with a reason in it rather than be added on a quiet afternoon.
    ///
    /// The hazard is `Shared/DaemonRemoval.swift`: `prepareForRemoval` exists
    /// because unregistering the daemon evicts the only process that can clear
    /// `SleepDisabled`, and that setting outlives both the process and the next
    /// reboot. The CLI verb already sequences that correctly. A one-click
    /// version of it, on the pane somebody opens *because* something is
    /// already wrong, is a way to reach the hazard by accident.
    func testNothingHereOffersTheResetPath() {
        let copy = everyState.map { daemonDiagnosticsSentence($0, appVersion: appVersion) }
            + [diagnosticsSectionFootnote, diagnosticsLogCommand]
        for text in copy {
            let lowered = text.lowercased()
            XCTAssertFalse(lowered.contains("reset"), text)
            XCTAssertFalse(lowered.contains("unregister"), text)
            XCTAssertFalse(lowered.contains("reinstall"), text)
        }
    }

    // MARK: The command

    /// **Checked against `README.md` itself, not against a copy of it.**
    ///
    /// This is the failure this project keeps naming: two files that never call
    /// each other agree on a string, and a change to one is not a compile error
    /// and not a crash. Here it would be a Copy button handing over a predicate
    /// that no longer matches what a bug reporter was asked for. The same
    /// `#filePath` route `SigningRequirementTests` uses to read the daemon's
    /// launchd plist — the test bundle knows its own source path at compile
    /// time, and `Tests/` sits beside `README.md` in the repo.
    func testTheLogCommandIsTheOneTheREADMEAsksBugReportersFor() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: repoRoot.appendingPathComponent("README.md"),
                                encoding: .utf8)
        let quoted = readme
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("log show") }
        XCTAssertEqual(quoted, [diagnosticsLogCommand],
                       "the pane's Copy button and README.md must hand over the same command")
    }

    /// It is pasted into a shell, so the predicate is single-quoted around the
    /// double quotes `log` itself requires. Unquoted, the shell eats the inner
    /// quotes and `log` rejects the predicate.
    func testTheCommandQuotesItsPredicateForAShell() {
        XCTAssertTrue(
            diagnosticsLogCommand.contains("'subsystem BEGINSWITH \"\(diagnosticsLogSubsystemPrefix)\"'"),
            diagnosticsLogCommand)
    }

    /// `BEGINSWITH`, never `==`. The app logs under
    /// `au.com.workwireless.keepy-uppy` (`Sources/DaemonConnection.swift`), the
    /// daemon under `….helper` (`Helper/DaemonRuntime.swift`) and the agent
    /// under `….agent` (`Agent/DaemonConnection.swift`) — an equality
    /// predicate would fetch one third of a bug report and look complete.
    func testThePredicateReachesEveryPartOfKeepyUppyAndNotJustTheApp() {
        XCTAssertTrue(diagnosticsLogCommand.contains("BEGINSWITH"), diagnosticsLogCommand)
        for subsystem in ["au.com.workwireless.keepy-uppy",
                          "au.com.workwireless.keepy-uppy.helper",
                          "au.com.workwireless.keepy-uppy.agent"] {
            XCTAssertTrue(subsystem.hasPrefix(diagnosticsLogSubsystemPrefix), subsystem)
        }
    }

    /// Measured rather than assumed, on this machine, while writing this
    /// section: 346 of the lines the command returns over the last two days
    /// carry `<private>` where a value should be. The daemon's every
    /// "Accepted connection from …" is one of them. A bug reporter who pastes
    /// the output and gets redactions back needs to know that is macOS, not a
    /// truncated log — otherwise the reply is "please send the real one".
    func testTheFootnoteWarnsThatSomeValuesComeBackRedacted() {
        XCTAssertTrue(diagnosticsSectionFootnote.contains("<private>"),
                      diagnosticsSectionFootnote)
    }

    /// The footnote says what the command is *for*. A monospaced string with a
    /// Copy button beside it and no sentence explaining it is a control that
    /// only helps somebody who already knew.
    func testTheFootnoteSaysWhatTheCommandIsFor() {
        let footnote = diagnosticsSectionFootnote.lowercased()
        XCTAssertTrue(footnote.contains("terminal"), footnote)
        XCTAssertTrue(footnote.contains("bug") || footnote.contains("issue"), footnote)
    }
}
