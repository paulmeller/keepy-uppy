import XCTest
@testable import KeepyUppy

/// Two absurd combinations, used by every registration test below.
///
/// `kVK_F20` (0x5A) and `kVK_F19` (0x50) with all four modifiers. Nothing
/// ships either one: most keyboards have no F19/F20 key at all, and no
/// shipping app or macOS symbolic hot key claims them with every modifier
/// held. They are registered and unregistered inside a single test, and the
/// suite's `tearDown` stops every centre it made, so nothing survives a run.
private let absurdBinding = HotKeyBinding(
    keyCode: 0x5A, modifiers: [.control, .option, .shift, .command])
private let otherAbsurdBinding = HotKeyBinding(
    keyCode: 0x50, modifiers: [.control, .option, .shift, .command])

// MARK: - The pure part

final class HotKeyBindingTests: XCTestCase {
    /// NSEvent's modifier bits and Carbon's are different constants, and the
    /// two are the same *idea* — which is exactly what makes a mix-up
    /// invisible. Get it wrong and `RegisterEventHotKey` returns `noErr` for a
    /// combination nobody asked for: success, doing nothing, in this project's
    /// favourite shape.
    ///
    /// The round trip alone would not catch that — a single wrong table round
    /// trips perfectly well. So the literals are pinned too: these are the
    /// documented values of `cmdKey`, `shiftKey`, `optionKey` and `controlKey`
    /// from `<MacTypes.h>`/`Events.h`, and of the four `NSEvent.ModifierFlags`
    /// bits, and the test asserts that no Carbon bit equals its NSEvent
    /// counterpart. If someone swaps one table for the other, the equality
    /// assertions go red rather than the round trip.
    func testEveryModifierConvertsToItsCarbonBitAndBack() {
        let expected: [(HotKeyModifiers, UInt32, NSEvent.ModifierFlags)] = [
            (.command, 0x0100, .command),
            (.shift, 0x0200, .shift),
            (.option, 0x0800, .option),
            (.control, 0x1000, .control),
        ]

        for (modifier, carbonBit, eventFlag) in expected {
            XCTAssertEqual(modifier.carbonFlags, carbonBit,
                           "\(modifier) does not carry Carbon's documented bit")
            XCTAssertEqual(modifier.eventFlags, eventFlag)
            // The mix-up this whole test exists for: no Carbon bit is the same
            // number as the NSEvent bit for the same modifier.
            XCTAssertNotEqual(UInt(carbonBit), eventFlag.rawValue,
                              "Carbon and NSEvent agree on \(modifier)'s bit, which they must not")

            XCTAssertEqual(HotKeyModifiers(carbonFlags: carbonBit), modifier)
            XCTAssertEqual(HotKeyModifiers(eventFlags: eventFlag), modifier)
        }

        // And both directions for every combination, not just the singletons:
        // a table that is right one modifier at a time can still drop one when
        // they are combined.
        for raw in 0...0b1111 {
            let modifiers = HotKeyModifiers(rawValue: UInt8(raw))
            XCTAssertEqual(HotKeyModifiers(carbonFlags: modifiers.carbonFlags), modifiers)
            XCTAssertEqual(HotKeyModifiers(eventFlags: modifiers.eventFlags), modifiers)
        }
    }

    /// Caps Lock is a modifier NSEvent reports and this app must not record:
    /// a binding that only fires with Caps Lock on is a binding that stops
    /// working when somebody types in capitals.
    func testModifiersThisAppDoesNotRecordAreDroppedRatherThanMisread() {
        let withCapsLock: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function]
        XCTAssertEqual(HotKeyModifiers(eventFlags: withCapsLock), [.command, .shift])
        // Carbon's alphaLock (0x0400) likewise.
        XCTAssertEqual(HotKeyModifiers(carbonFlags: 0x0100 | 0x0400), .command)
    }

    /// A bare key with no modifiers would steal that key system-wide — press
    /// `k` in any app and a session starts. `RegisterEventHotKey` has allowed
    /// it since 10.3 (its header says so) and returns `noErr`; this app does
    /// not.
    func testABindingWithNoModifiersIsRefusedWithAReason() {
        let problem = hotKeyBindingProblem(HotKeyBinding(keyCode: 0x28, modifiers: []))
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("modifier") == true,
                      "the sentence must name what is missing: \(problem ?? "nil")")
    }

    /// A modifier's own key code with modifiers held. The recorder cannot
    /// produce one (a modifier press is `flagsChanged`, never `keyDown`), but a
    /// stored value can hold one, and `RegisterEventHotKey` accepts it happily.
    func testAModifierOnlyBindingIsRefusedWithAReason() {
        // kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
        // kVK_RightCommand/Shift/Option/Control, kVK_Function.
        for keyCode: UInt16 in [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F] {
            let binding = HotKeyBinding(keyCode: keyCode, modifiers: [.command, .option])
            let problem = hotKeyBindingProblem(binding)
            XCTAssertNotNil(problem, "key code \(keyCode) is a modifier and must be refused")
        }
    }

    /// Unset is not wrong. The same rule `processNameProblem` and
    /// `subnetProblem` follow for an empty field: nothing to say about a
    /// shortcut nobody has chosen.
    func testAnUnsetBindingIsNotAProblem() {
        XCTAssertNil(hotKeyBindingProblem(nil))
    }

    func testAnOrdinaryBindingHasNoProblem() {
        XCTAssertNil(hotKeyBindingProblem(absurdBinding))
        XCTAssertNil(hotKeyBindingProblem(HotKeyBinding(keyCode: 0x28, modifiers: [.command, .shift])))
    }

    /// Display form, so a stored binding reads back as what was pressed.
    /// macOS orders modifier glyphs ⌃⌥⇧⌘ regardless of the order they were
    /// pressed in, and a shortcut printed in any other order reads as a
    /// different shortcut.
    func testTheDisplayStringUsesTheStandardGlyphOrder() {
        // Built in the wrong order deliberately; an OptionSet has no order of
        // its own, so this is checking the renderer rather than the input.
        let all: HotKeyModifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(all.glyphs, "⌃⌥⇧⌘")
        XCTAssertEqual(HotKeyModifiers([.command, .control]).glyphs, "⌃⌘")
        XCTAssertEqual(HotKeyModifiers([.shift, .option]).glyphs, "⌥⇧")
        XCTAssertEqual(HotKeyModifiers().glyphs, "")

        // The whole string, over a key whose label does not depend on the
        // keyboard layout. kVK_F20 = 0x5A.
        XCTAssertEqual(hotKeyDisplayString(absurdBinding), "⌃⌥⇧⌘F20")
        // kVK_Space = 0x31, named rather than rendered as an invisible glyph.
        XCTAssertEqual(hotKeyDisplayString(HotKeyBinding(keyCode: 0x31, modifiers: .command)),
                       "⌘Space")
        // kVK_Escape = 0x35.
        XCTAssertEqual(hotKeyDisplayString(HotKeyBinding(keyCode: 0x35, modifiers: .control)),
                       "⌃⎋")
    }

    /// A key code with no name and no layout translation still renders as
    /// *something*: a row reading "⌘" with nothing after it is a row that
    /// looks unset while being set.
    func testAnUnnameableKeyStillRendersSomethingAfterTheModifiers() {
        let label = hotKeyKeyLabel(0xFE)
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(hotKeyDisplayString(HotKeyBinding(keyCode: 0xFE, modifiers: .command))
            .hasPrefix("⌘"))
        XCTAssertGreaterThan(hotKeyDisplayString(HotKeyBinding(keyCode: 0xFE, modifiers: .command)).count, 1)
    }

    /// Every key this app can record renders as something a person can read
    /// back. Run over the whole 0...127 virtual key-code space rather than a
    /// hand-picked list, because the gap this catches is a key nobody thought
    /// to name.
    func testEveryVirtualKeyCodeRendersANonEmptyLabel() {
        for code in UInt16(0)...UInt16(127) {
            XCTAssertFalse(hotKeyKeyLabel(code).isEmpty, "key code \(code) renders as nothing")
        }
    }

    func testABindingRoundTripsThroughItsStoredForm() {
        for binding in [absurdBinding, otherAbsurdBinding,
                        HotKeyBinding(keyCode: 0x31, modifiers: .command)] {
            let stored = binding.storedForm
            XCTAssertEqual(HotKeyBinding(storedForm: stored), binding)
        }
    }

    /// An unparseable stored value is *unset*, never a binding nobody chose.
    /// The alternative — falling back to some default combination — arms a
    /// global shortcut the user never asked for, which is the worst outcome
    /// available on this surface.
    func testAnUnparseableStoredValueReadsBackAsUnsetRatherThanAsSomeBinding() {
        for junk in ["", "   ", "nonsense", "{}", "{\"keyCode\":", "null", "0",
                     "{\"keyCode\":90}", "{\"modifiers\":15}"] {
            XCTAssertNil(HotKeyBinding(storedForm: junk),
                         "\(junk) parsed into a binding")
        }
    }
}

// MARK: - The actions

final class HotKeyActionTests: XCTestCase {
    /// Two actions, both mapping onto something the menu already does. A hot
    /// key must never be able to do something the menu cannot.
    func testEveryActionHasALabelAndAPreferenceKey() {
        var labels: Set<String> = []
        var keys: Set<String> = []
        var variables: Set<String> = []
        for action in HotKeyAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertFalse(action.preferenceKey.isEmpty)
            labels.insert(action.label)
            keys.insert(action.preferenceKey)
            variables.insert(action.debugEnvironmentVariable)
            // A preference key that collides with another preference is a
            // shortcut that silently reads somebody else's value.
            for other in ["defaultSessionKind", DefaultWakeModePreference.key,
                          DefaultKeepDisksAwakePreference.key,
                          SessionNotificationPreference.stopKey,
                          SessionNotificationPreference.triggerStartKey] {
                XCTAssertNotEqual(action.preferenceKey, other)
            }
        }
        XCTAssertEqual(labels.count, HotKeyAction.allCases.count)
        XCTAssertEqual(keys.count, HotKeyAction.allCases.count)
        XCTAssertEqual(variables.count, HotKeyAction.allCases.count)
    }

    /// **The label has to match the scope, and the scope is narrower than the
    /// obvious name.** `stopAllSessions(all: false)` filters on
    /// `$0.owner == caller` (`Shared/XPCProtocol.swift`), and the caller here
    /// is the app — `app-<uid>`. This user's own trigger session is owned by
    /// `agent-<uid>` and their own CLI session by `cli-<uid>`, so neither is
    /// stopped. A row called "Stop my sessions" would therefore be a lie on the
    /// commonest case, on the one surface that gives no feedback either way.
    func testTheStopActionSaysItStopsWhatTheMenuStartedAndNotMore() {
        let label = HotKeyAction.stopAppSessions.label
        XCTAssertTrue(label.lowercased().contains("menu"),
                      "the stop label must name the menu as its scope: \(label)")
        for overclaim in ["all sessions", "my sessions", "every session", "this mac"] {
            XCTAssertFalse(label.lowercased().contains(overclaim),
                           "the stop label claims \(overclaim), which it cannot do: \(label)")
        }
    }

    /// The id travelling through Carbon's `EventHotKeyID`. Explicit per case
    /// rather than an index into `allCases`, so reordering the enum cannot
    /// silently repoint a stored registration at the other action.
    func testEveryActionHasADistinctNonZeroHotKeyIDThatRoundTrips() {
        var ids: Set<UInt32> = []
        for action in HotKeyAction.allCases {
            XCTAssertNotEqual(action.hotKeyID, 0, "0 is the id an uninitialised EventHotKeyID carries")
            ids.insert(action.hotKeyID)
            XCTAssertEqual(HotKeyAction(hotKeyID: action.hotKeyID), action)
        }
        XCTAssertEqual(ids.count, HotKeyAction.allCases.count)
        XCTAssertNil(HotKeyAction(hotKeyID: 0))
        XCTAssertNil(HotKeyAction(hotKeyID: 9999))
    }
}

// MARK: - Registration against the real Carbon API

/// These talk to the live window server. Every test unregisters what it
/// registered, and `tearDown` stops every centre this class made even if an
/// assertion threw first — so a failing run cannot leave a global shortcut
/// bound to a test process.
final class HotKeyRegistrationTests: XCTestCase {
    private var centres: [HotKeyCenter] = []

    private func makeCentre() -> HotKeyCenter {
        let centre = HotKeyCenter()
        centres.append(centre)
        return centre
    }

    override func tearDown() {
        for centre in centres { centre.stop() }
        centres = []
        super.tearDown()
    }

    func testRegisteringABindingReportsNoFailure() {
        let centre = makeCentre()
        centre.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(centre.failures.isEmpty, "\(centre.failures)")
        XCTAssertEqual(centre.registeredActionsForTesting, [.startDefaultSession])
    }

    /// **The negative control, and the one that proves the success path above
    /// is not a tautology.**
    ///
    /// Two `kEventHotKeyExclusive` registrations of the same combination: the
    /// second must come back `eventHotKeyExistsErr` (-9878). Measured, not
    /// assumed — the header's Result paragraph says "another *process*" while
    /// the option's own paragraph says "another hot key", and the two readings
    /// disagree about exactly this case.
    ///
    /// Deliberately **not** proven by registering a combination macOS already
    /// owns: see `testACombinationMacOSAlreadyOwnsIsAcceptedWithNoError` below
    /// for why that experiment returns success and proves nothing.
    func testRegisteringTheSameBindingTwiceExclusivelyIsRefused() {
        let first = makeCentre()
        first.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(first.failures.isEmpty, "the first registration must succeed")

        let second = makeCentre()
        second.apply([.startDefaultSession: absurdBinding])

        XCTAssertEqual(second.failures[.startDefaultSession],
                       .alreadyTaken(hotKeyAlreadyTakenStatus))
        XCTAssertEqual(hotKeyAlreadyTakenStatus, -9878,
                       "eventHotKeyExistsErr is -9878 in <CarbonEventsCore.h>")
        // And nothing was half-registered: the refused action holds no
        // registration to leak.
        XCTAssertTrue(second.registeredActionsForTesting.isEmpty)
    }

    /// **A combination macOS already owns is accepted, and that is the whole
    /// reason the copy has to warn rather than promise.**
    ///
    /// macOS symbolic hot keys — Spotlight here — are not
    /// `RegisterEventHotKey` registrations at all: the window server consumes
    /// the key upstream. So the call succeeds, the row would show success, and
    /// the shortcut never fires. This test pins that as a *measured fact*, so
    /// that if a future macOS ever did start reporting it, this goes red and
    /// the standing warning in Settings can be revisited.
    ///
    /// Registered exclusively and unregistered in the same breath. It cannot
    /// take Spotlight's key away in between, for the reason above: nothing ever
    /// delivers ⌘Space to a `RegisterEventHotKey` client.
    func testACombinationMacOSAlreadyOwnsIsAcceptedWithNoError() {
        let centre = makeCentre()
        // kVK_Space = 0x31 with command alone: Spotlight, on a stock Mac.
        centre.apply([.startDefaultSession: HotKeyBinding(keyCode: 0x31, modifiers: .command)])
        XCTAssertTrue(centre.failures.isEmpty,
                      "macOS started reporting a symbolic hot key conflict — revisit the Settings copy")
        centre.stop()
    }

    /// The explicit unregister path, proven by *behaviour* rather than by a
    /// status code: after `stop()`, the combination is free, so a second centre
    /// can take it exclusively. If the first centre had leaked its
    /// registration, this would be `eventHotKeyExistsErr` instead.
    ///
    /// The header says the system unregisters at process termination, which is
    /// true and not enough: a toggle switched off must not leave a stale
    /// registration behind for the rest of the app's life.
    func testStoppingReleasesTheCombinationForSomebodyElse() {
        let first = makeCentre()
        first.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(first.failures.isEmpty)
        first.stop()
        XCTAssertTrue(first.registeredActionsForTesting.isEmpty)

        let second = makeCentre()
        second.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(second.failures.isEmpty,
                      "the first centre leaked its registration: \(second.failures)")
    }

    /// Same proof, for the path a preference change actually takes: applying a
    /// new set must release what the old set held.
    func testChangingABindingReleasesTheOneItReplaced() {
        let centre = makeCentre()
        centre.apply([.startDefaultSession: absurdBinding])
        centre.apply([.startDefaultSession: otherAbsurdBinding])
        XCTAssertTrue(centre.failures.isEmpty)

        let probe = makeCentre()
        probe.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(probe.failures.isEmpty,
                      "the replaced binding is still registered: \(probe.failures)")
    }

    /// Applying an empty set is how the UI turns a shortcut off.
    func testClearingEveryBindingReleasesEverything() {
        let centre = makeCentre()
        centre.apply([.startDefaultSession: absurdBinding,
                      .stopAppSessions: otherAbsurdBinding])
        XCTAssertEqual(Set(centre.registeredActionsForTesting), Set(HotKeyAction.allCases))
        centre.apply([:])
        XCTAssertTrue(centre.registeredActionsForTesting.isEmpty)

        let probe = makeCentre()
        probe.apply([.startDefaultSession: absurdBinding,
                     .stopAppSessions: otherAbsurdBinding])
        XCTAssertTrue(probe.failures.isEmpty, "\(probe.failures)")
    }

    /// A binding that cannot work is never handed to Carbon at all. Otherwise
    /// the app would register a bare key system-wide and then show a green row
    /// about it.
    func testARefusedBindingIsNotRegistered() {
        let centre = makeCentre()
        centre.apply([.startDefaultSession: HotKeyBinding(keyCode: 0x5A, modifiers: [])])
        XCTAssertTrue(centre.registeredActionsForTesting.isEmpty)
        XCTAssertEqual(centre.failures[.startDefaultSession]?.isUnusableBinding, true)
    }

    /// Two actions cannot hold the same combination, and the second one must
    /// say so rather than silently winning or silently losing.
    func testTwoActionsOnTheSameCombinationReportTheCollision() {
        let centre = makeCentre()
        centre.apply([.startDefaultSession: absurdBinding, .stopAppSessions: absurdBinding])
        XCTAssertEqual(centre.registeredActionsForTesting.count, 1)
        XCTAssertEqual(centre.failures.count, 1)
        XCTAssertEqual(centre.failures.values.first, .alreadyTaken(hotKeyAlreadyTakenStatus))
    }
}

// MARK: - The event handler

/// **What these prove and what they cannot.** No test can press a key: a real
/// global hot key arrives from the window server, and nothing in-process can
/// make that happen without posting a synthetic event to whatever application
/// is frontmost. So the human-pressed-key proof stays on the manual checklist.
///
/// What is proven here is everything between the window server and the action:
/// the handler is installed on the target Carbon delivers hot keys to, for the
/// right event class and kind; it decodes `EventHotKeyID` out of the event; it
/// ignores an id that is not ours; it dispatches to the right action; and it
/// stops dispatching once the centre is stopped. That is the part that can be
/// wrong silently — a handler installed on the wrong target never fires and
/// never says so.
final class HotKeyDispatchTests: XCTestCase {
    private var centres: [HotKeyCenter] = []

    private func makeCentre() -> HotKeyCenter {
        let centre = HotKeyCenter()
        centres.append(centre)
        return centre
    }

    override func tearDown() {
        for centre in centres { centre.stop() }
        centres = []
        super.tearDown()
    }

    func testASyntheticHotKeyEventReachesTheActionItWasRegisteredFor() {
        let centre = makeCentre()
        var performed: [HotKeyAction] = []
        centre.perform = { performed.append($0) }
        centre.apply([.startDefaultSession: absurdBinding,
                      .stopAppSessions: otherAbsurdBinding])

        XCTAssertEqual(centre.deliverSyntheticHotKeyEventForTesting(
            id: HotKeyAction.startDefaultSession.hotKeyID), noErr)
        XCTAssertEqual(performed, [.startDefaultSession])

        XCTAssertEqual(centre.deliverSyntheticHotKeyEventForTesting(
            id: HotKeyAction.stopAppSessions.hotKeyID), noErr)
        XCTAssertEqual(performed, [.startDefaultSession, .stopAppSessions])
    }

    /// `EventHotKeyID` carries a four-character signature precisely so that two
    /// clients of the same process-wide event target cannot be confused for one
    /// another. Without the check, any other hot key client's id that happened
    /// to collide numerically would start a session.
    func testAHotKeyEventCarryingAnotherClientsSignatureIsIgnored() {
        let centre = makeCentre()
        var performed: [HotKeyAction] = []
        centre.perform = { performed.append($0) }
        centre.apply([.startDefaultSession: absurdBinding])

        let status = centre.deliverSyntheticHotKeyEventForTesting(
            id: HotKeyAction.startDefaultSession.hotKeyID,
            signature: HotKeyCenter.foreignSignatureForTesting)
        XCTAssertEqual(status, OSStatus(-9874), "eventNotHandledErr")
        XCTAssertTrue(performed.isEmpty)
    }

    func testAnIdThisAppNeverIssuedIsIgnored() {
        let centre = makeCentre()
        var performed: [HotKeyAction] = []
        centre.perform = { performed.append($0) }
        centre.apply([.startDefaultSession: absurdBinding])

        XCTAssertNotEqual(centre.deliverSyntheticHotKeyEventForTesting(id: 4321), noErr)
        XCTAssertTrue(performed.isEmpty)
    }

    /// The teardown negative control: once stopped, the handler is gone from
    /// the event target entirely, so the same send is not handled at all.
    func testNothingIsDispatchedOnceTheCentreIsStopped() {
        let centre = makeCentre()
        var performed: [HotKeyAction] = []
        centre.perform = { performed.append($0) }
        centre.apply([.startDefaultSession: absurdBinding])
        centre.stop()

        XCTAssertNotEqual(centre.deliverSyntheticHotKeyEventForTesting(
            id: HotKeyAction.startDefaultSession.hotKeyID), noErr)
        XCTAssertTrue(performed.isEmpty)
    }

    /// No handler is installed until there is something for it to deliver. An
    /// app with no shortcuts set should not be sitting on the process-wide
    /// keyboard event target at all.
    func testNoHandlerIsInstalledUntilABindingIsApplied() {
        let centre = makeCentre()
        XCTAssertFalse(centre.hasEventHandlerForTesting)
        centre.apply([:])
        XCTAssertFalse(centre.hasEventHandlerForTesting)
        centre.apply([.startDefaultSession: absurdBinding])
        XCTAssertTrue(centre.hasEventHandlerForTesting)
    }
}

// MARK: - The conflict this API cannot report, and the part of it that can

final class SystemShortcutConflictTests: XCTestCase {
    /// ⌘Space, as `CopySymbolicHotKeys` reports it: `kVK_Space` with Carbon's
    /// `cmdKey`.
    private let spotlight = SystemShortcut(keyCode: 0x31, carbonModifiers: 0x0100, isEnabled: true)

    func testASystemShortcutOnTheSameCombinationIsReported() {
        let binding = HotKeyBinding(keyCode: 0x31, modifiers: .command)
        XCTAssertTrue(systemShortcutTakes(binding, among: [spotlight]))
    }

    func testADifferentCombinationIsNotReported() {
        XCTAssertFalse(systemShortcutTakes(absurdBinding, among: [spotlight]))
        // Same key, one more modifier: a different shortcut.
        XCTAssertFalse(systemShortcutTakes(
            HotKeyBinding(keyCode: 0x31, modifiers: [.command, .shift]), among: [spotlight]))
    }

    /// A shortcut the user has switched off in System Settings is not a
    /// conflict, and warning about it would be a false accusation about a
    /// combination that works.
    func testADisabledSystemShortcutIsNotReported() {
        let disabled = SystemShortcut(keyCode: 0x31, carbonModifiers: 0x0100, isEnabled: false)
        XCTAssertFalse(systemShortcutTakes(HotKeyBinding(keyCode: 0x31, modifiers: .command),
                                           among: [disabled]))
    }

    /// **The conservative rule, and why.** `CopySymbolicHotKeys` returns a
    /// modifier value that is Carbon's `EventModifiers` *plus* at least one bit
    /// with no name in any SDK header — 0x20000, measured on 110 of the 230
    /// entries this Mac reports, always on function and arrow keys. This app
    /// cannot record that modifier and `RegisterEventHotKey` cannot express it,
    /// so an entry carrying it describes a combination no binding here can
    /// equal. Skipping those entries is therefore not a gap: matching on the
    /// four bits alone would report ⌃⇧↑ as taken by ⌃↑'s entry, which is a
    /// warning about a shortcut that works.
    func testAnEntryWithModifiersThisAppCannotRecordIsSkipped() {
        // Mission Control on this Mac: kVK_UpArrow (0x7E) with 0x21000.
        let missionControl = SystemShortcut(keyCode: 0x7E, carbonModifiers: 0x21000, isEnabled: true)
        XCTAssertFalse(systemShortcutTakes(HotKeyBinding(keyCode: 0x7E, modifiers: .control),
                                           among: [missionControl]))
        XCTAssertFalse(systemShortcutTakes(HotKeyBinding(keyCode: 0x7E, modifiers: [.control, .shift]),
                                           among: [missionControl]))
    }

    /// An unset binding conflicts with nothing.
    func testNoBindingConflictsWithNothing() {
        XCTAssertFalse(systemShortcutTakes(nil, among: [spotlight]))
    }

    /// The live list, read from `CopySymbolicHotKeys`. Deliberately asserts the
    /// shape rather than a particular shortcut: which symbolic hot keys are
    /// enabled is the user's business and a test that demands Spotlight be on
    /// ⌘Space fails on a perfectly reasonable Mac.
    ///
    /// It is still worth having. The API is documented as returning `noErr` or
    /// `memFullErr` and nothing else, and an empty array would be the exact
    /// silent-no-op shape this project keeps finding: the recorder would go on
    /// showing "no conflict" for every combination forever.
    func testTheLiveSymbolicHotKeyListIsReadableAndNotEmpty() {
        let shortcuts = HotKeyCenter.systemShortcuts()
        XCTAssertFalse(shortcuts.isEmpty,
                       "CopySymbolicHotKeys returned nothing — conflict detection is inert")
        XCTAssertTrue(shortcuts.contains { $0.isEnabled },
                      "no symbolic hot key is enabled, which no stock Mac reports")
        // And the pure check runs over the real data without a false positive
        // on a combination nothing ships.
        XCTAssertFalse(systemShortcutTakes(absurdBinding, among: shortcuts))
    }
}

// MARK: - What a hot key starts

/// These live here rather than in `SessionDisplayTests` because the type they
/// pin exists for this task: the hot key has to start *exactly* what the menu's
/// leading row starts, and the way that goes wrong is a fourth axis being added
/// to the menu and not to the shortcut.
final class MenuDefaultStartTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    private var defaults: UserDefaults { PreferencesSuite.defaults }

    /// Nobody has opened Settings. Every axis takes its documented fallback,
    /// and each one is named from its own preference type rather than repeated
    /// here.
    func testAnUnwrittenSuiteReadsBackEveryDocumentedFallback() {
        let start = MenuDefaultStart(readingFrom: defaults)
        XCTAssertEqual(start.kind, .indefinite)
        XCTAssertEqual(start.power.wakeMode, DefaultWakeModePreference.fallback)
        XCTAssertEqual(start.power.keepsDisksAwake, DefaultKeepDisksAwakePreference.fallback)
    }

    /// The weld. The menu builds this from its `@AppStorage` values and the hot
    /// key builds it by reading the suite; the two initialisers must agree, and
    /// they are checked against each other rather than each against a literal.
    func testReadingTheSuiteAgreesWithBuildingItFromTheSameThreeValues() {
        defaults.set(DefaultSessionKind.fourHours.rawValue, forKey: "defaultSessionKind")
        defaults.set(WakeMode.systemAndDisplay.rawValue, forKey: DefaultWakeModePreference.key)
        defaults.set(true, forKey: DefaultKeepDisksAwakePreference.key)

        XCTAssertEqual(
            MenuDefaultStart(readingFrom: defaults),
            MenuDefaultStart(kindRawValue: DefaultSessionKind.fourHours.rawValue,
                             wakeModeRawValue: WakeMode.systemAndDisplay.rawValue,
                             keepsDisksAwake: true))
    }

    /// Every axis is actually read. A test that only set one of them would pass
    /// against an implementation that ignored the other two.
    func testEveryStoredAxisReachesTheRequest() {
        defaults.set(DefaultSessionKind.oneHour.rawValue, forKey: "defaultSessionKind")
        defaults.set(WakeMode.system.rawValue, forKey: DefaultWakeModePreference.key)
        defaults.set(true, forKey: DefaultKeepDisksAwakePreference.key)

        let start = MenuDefaultStart(readingFrom: defaults)
        XCTAssertEqual(start.kind, .oneHour)
        XCTAssertEqual(start.power.wakeMode, .system)
        XCTAssertTrue(start.power.keepsDisksAwake)
        // None of the three is the fallback, so none can pass by accident.
        XCTAssertNotEqual(start.power.wakeMode, DefaultWakeModePreference.fallback)
        XCTAssertNotEqual(start.power.keepsDisksAwake, DefaultKeepDisksAwakePreference.fallback)
    }

    /// An unrecognised raw value falls back rather than failing, exactly as the
    /// menu's own readers do — the shortcut must not become inert because a
    /// later version wrote an enum case this build has never heard of.
    func testUnrecognisedRawValuesFallBackRatherThanDisablingTheShortcut() {
        defaults.set("fortnight", forKey: "defaultSessionKind")
        defaults.set("teleport", forKey: DefaultWakeModePreference.key)
        let start = MenuDefaultStart(readingFrom: defaults)
        XCTAssertEqual(start.kind, .indefinite)
        XCTAssertEqual(start.power.wakeMode, DefaultWakeModePreference.fallback)
    }

    func testTheSessionKindIsComputedFromNowRatherThanStored() {
        let start = MenuDefaultStart(kindRawValue: DefaultSessionKind.oneHour.rawValue,
                                     wakeModeRawValue: WakeMode.clamshell.rawValue,
                                     keepsDisksAwake: false)
        let now = Date(timeIntervalSince1970: 1_000_000)
        guard case .duration(let until) = start.sessionKind(now: now) else {
            return XCTFail("expected a duration")
        }
        XCTAssertEqual(until.timeIntervalSince(now), 3600, accuracy: 0.001)
    }
}

// MARK: - The development-only override

/// **This exists so that testing a hot key never needs a preference write.**
///
/// `PreferencesSuite.name` is the production domain outside XCTest, the
/// installed Release app reads it live through `@AppStorage`, and a stored
/// binding survives the process that wrote it — so a "temporary default" would
/// arm an arbitrary global shortcut in the user's shipping app and leave it
/// armed. An environment variable is read once, by one process, and dies with
/// it.
final class HotKeyDebugOverrideTests: XCTestCase {
    func testAnEnvironmentWithNoOverrideYieldsNoBindings() {
        XCTAssertTrue(hotKeyDebugBindings(in: [:]).isEmpty)
        XCTAssertTrue(hotKeyDebugBindings(in: ["PATH": "/usr/bin"]).isEmpty)
    }

    func testAnOverrideIsReadFromTheEnvironmentForEachAction() {
        let environment = [
            HotKeyAction.startDefaultSession.debugEnvironmentVariable: "control,option,shift,command:90",
            HotKeyAction.stopAppSessions.debugEnvironmentVariable: "control,command:80",
        ]
        let bindings = hotKeyDebugBindings(in: environment)
        XCTAssertEqual(bindings[.startDefaultSession], absurdBinding)
        XCTAssertEqual(bindings[.stopAppSessions],
                       HotKeyBinding(keyCode: 80, modifiers: [.control, .command]))
    }

    /// A malformed override is ignored rather than guessed at. The guess would
    /// be a global shortcut nobody typed.
    func testAMalformedOverrideIsIgnored() {
        for junk in ["", "90", "command:", ":90", "command:notanumber", "banana:90",
                     "command:99999", "command,banana:90"] {
            let bindings = hotKeyDebugBindings(
                in: [HotKeyAction.startDefaultSession.debugEnvironmentVariable: junk])
            XCTAssertTrue(bindings.isEmpty, "\(junk) produced \(bindings)")
        }
    }

    /// The variable names are not preference keys and must never be mistaken
    /// for them: nothing here is ever written anywhere.
    func testTheVariableNamesAreObviouslyDevelopmentOnly() {
        for action in HotKeyAction.allCases {
            XCTAssertTrue(action.debugEnvironmentVariable.hasPrefix("KEEPY_UPPY_DEBUG_HOTKEY_"),
                          action.debugEnvironmentVariable)
            XCTAssertNotEqual(action.debugEnvironmentVariable, action.preferenceKey)
        }
    }
}
