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
        XCTAssertEqual(menuStartLabel(.indefinite, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake indefinitely")
        XCTAssertEqual(menuStartLabel(.oneHour, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake for 1 hour")
        XCTAssertEqual(menuStartLabel(.eightHours, wakeMode: .clamshell, keepsDisksAwake: false),
                       "Keep awake for 8 hours")
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
        for other in ["defaultSessionKind", DefaultWakeModePreference.key] {
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
                for row in [menuStopLabel(for: session, isOnlyOneOfMine: true, now: t0),
                            menuStopLabel(for: session, isOnlyOneOfMine: false, now: t0),
                            menuForeignSessionLabel(for: session, now: t0)] {
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
