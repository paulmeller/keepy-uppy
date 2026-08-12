import AppKit
import Carbon.HIToolbox

// Everything in this file is pure: what a binding *is*, what makes one
// unusable, and what it reads as. The Carbon calls that make a binding do
// anything live in `Sources/HotKeyCenter.swift`.
//
// It is in `Sources/` rather than `Shared/` because nothing outside the app has
// any business with a keyboard shortcut — the daemon, the CLI and the agent do
// not have keyboards — and because `Shared/` compiles into all four targets,
// which would put `Carbon.framework` on three of them for nothing.

// MARK: - Modifiers

/// The four modifiers this app will record, in a representation of its own.
///
/// **Its own bits, deliberately, rather than reusing Carbon's or NSEvent's.**
/// Those are the two numbers this type has to convert between, and picking
/// either one as the storage format makes the conversion to *that* side a
/// no-op — which is precisely the direction a mistake would hide in. A separate
/// raw value also means the stored preference does not change meaning if Apple
/// ever renumbers either set.
///
/// Caps Lock is not here and must not be. NSEvent reports it like any other
/// modifier and Carbon has a bit for it (`alphaLock`), but a shortcut that
/// only fires with Caps Lock on is a shortcut that stops working the moment
/// somebody types in capitals. `init(eventFlags:)` drops it rather than
/// refusing, because the recorder sees it arrive on ordinary keystrokes.
///
/// Fn is not here either, and cannot be: `RegisterEventHotKey` takes an
/// `EventModifiers`, which is 16 bits wide and has no Fn bit at all. See
/// `SystemShortcut` for the consequence.
struct HotKeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let control = HotKeyModifiers(rawValue: 1 << 0)
    static let option = HotKeyModifiers(rawValue: 1 << 1)
    static let shift = HotKeyModifiers(rawValue: 1 << 2)
    static let command = HotKeyModifiers(rawValue: 1 << 3)

    /// Every bit this type defines — used to reject a stored value carrying
    /// anything else.
    static let all: HotKeyModifiers = [.control, .option, .shift, .command]

    /// The one table. Order is **glyph order**, which is also the order macOS
    /// draws modifiers in every menu it has ever shipped, so the display string
    /// falls out of the same list the conversions use.
    ///
    /// The Carbon values are `controlKey`, `optionKey`, `shiftKey` and `cmdKey`
    /// from `<Carbon/Events.h>`; the NSEvent values are the corresponding
    /// `NSEvent.ModifierFlags`. They are different numbers for the same idea,
    /// which is what makes a mix-up silent — `RegisterEventHotKey` returns
    /// `noErr` for the combination it was actually given, so the only symptom
    /// is a shortcut that fires on something nobody pressed.
    private static let table: [(HotKeyModifiers, Int, NSEvent.ModifierFlags, String)] = [
        (.control, controlKey, .control, "⌃"),
        (.option, optionKey, .option, "⌥"),
        (.shift, shiftKey, .shift, "⇧"),
        (.command, cmdKey, .command, "⌘"),
    ]

    /// The mask `RegisterEventHotKey` wants.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        for (modifier, carbon, _, _) in Self.table where contains(modifier) {
            flags |= UInt32(carbon)
        }
        return flags
    }

    /// Bits outside the four are dropped rather than refused — `alphaLock` in
    /// particular, and whatever undocumented bit `CopySymbolicHotKeys` returns.
    init(carbonFlags: UInt32) {
        var result = HotKeyModifiers()
        for (modifier, carbon, _, _) in Self.table where carbonFlags & UInt32(carbon) != 0 {
            result.insert(modifier)
        }
        self = result
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        for (modifier, _, event, _) in Self.table where contains(modifier) {
            flags.insert(event)
        }
        return flags
    }

    /// Everything NSEvent reports that this app does not record — Caps Lock,
    /// Fn, the numeric-pad and Help bits — is dropped here, so the recorder can
    /// hand over `event.modifierFlags` unfiltered.
    init(eventFlags: NSEvent.ModifierFlags) {
        var result = HotKeyModifiers()
        for (modifier, _, event, _) in Self.table where eventFlags.contains(event) {
            result.insert(modifier)
        }
        self = result
    }

    /// ⌃⌥⇧⌘, always in that order whatever order they were pressed in. An
    /// `OptionSet` has no order of its own, so this is the only thing that
    /// gives a stored binding a stable reading.
    var glyphs: String {
        var result = ""
        for (modifier, _, _, glyph) in Self.table where contains(modifier) {
            result += glyph
        }
        return result
    }
}

// MARK: - A binding

/// A key and the modifiers held with it. **No member has a default**, following
/// `Session` and `PowerRequest`: a construction site that omits the modifiers
/// would compile into a bare-key shortcut that takes a letter away from every
/// app on the Mac.
struct HotKeyBinding: Codable, Equatable, Hashable {
    /// A virtual key code, exactly as `NSEvent.keyCode` and
    /// `RegisterEventHotKey` both mean it: a position on the keyboard, not a
    /// character. The same code is `Z` on a QWERTY layout and `W` on AZERTY,
    /// which is why the display string has to ask the current layout rather
    /// than store what was typed.
    let keyCode: UInt16
    let modifiers: HotKeyModifiers

    init(keyCode: UInt16, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

extension HotKeyBinding {
    /// What goes in the preference. JSON rather than a bespoke string because
    /// the failure this has to survive is a *stored* value that no longer
    /// parses, and a decoder that throws is easier to be sure about than a
    /// splitter that returns something plausible for nonsense.
    ///
    /// `.sortedKeys` because the key order is otherwise not stable — not even
    /// within one process, measured — and one binding must have exactly one
    /// stored form. Nothing in the app compares two of these as strings, so the
    /// instability was invisible in production and showed up only where a
    /// stored value was checked against a freshly encoded one; but a preference
    /// that rewrites itself into a different spelling of the same value is
    /// worth not shipping either.
    var storedForm: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// **Unparseable is unset, never "some binding".** The tempting fallback —
    /// substitute a sensible default combination — would arm a global shortcut
    /// the user never chose, on a surface with no feedback, which is the worst
    /// outcome available here. Compare `DefaultWakeModePreference.mode(rawValue:)`,
    /// which *does* fall back: an unrecognised wake mode still has to produce a
    /// session, whereas an unrecognised shortcut can simply not exist.
    init?(storedForm: String) {
        guard let data = storedForm.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data),
              HotKeyModifiers.all.isSuperset(of: decoded.modifiers)
        else { return nil }
        self = decoded
    }
}

/// Why a binding can never work, or `nil` if it can — the `processNameProblem`
/// and `subnetProblem` of this feature, and it lives out here for the same two
/// reasons: the rule has one statement, and that statement is testable without
/// a UI.
///
/// `nil` for an unset binding is the same rule those two follow for an empty
/// field: nothing to say about a shortcut nobody has chosen. Unset is
/// incomplete, not wrong.
func hotKeyBindingProblem(_ binding: HotKeyBinding?) -> String? {
    guard let binding else { return nil }

    if binding.modifiers.isEmpty {
        return "A shortcut needs at least one modifier key — ⌘, ⌥, ⌃ or ⇧. "
            + "Without one it would take that key away from every app on this Mac."
    }
    if hotKeyModifierKeyCodes.contains(binding.keyCode) {
        return "Pick a key that isn't a modifier. A shortcut has to end in an ordinary key."
    }
    return nil
}

/// The virtual key codes of the modifier keys themselves — `kVK_RightCommand`
/// through `kVK_Function`.
///
/// The recorder cannot produce one of these (macOS sends `flagsChanged` for a
/// modifier press, never `keyDown`), so this guards the *stored* value: a
/// hand-edited preference, or a later version of this app that records
/// differently. `RegisterEventHotKey` accepts ⌘-as-the-key quite happily and
/// then never fires.
private let hotKeyModifierKeyCodes: Set<UInt16> = [
    UInt16(kVK_RightCommand), UInt16(kVK_Command), UInt16(kVK_Shift),
    UInt16(kVK_CapsLock), UInt16(kVK_Option), UInt16(kVK_Control),
    UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl),
    UInt16(kVK_Function),
]

// MARK: - Reading a binding back

/// `⌃⌥⇧⌘F20` — the modifiers in macOS's glyph order, then the key.
func hotKeyDisplayString(_ binding: HotKeyBinding) -> String {
    binding.modifiers.glyphs + hotKeyKeyLabel(binding.keyCode)
}

/// What one key is called.
///
/// Two sources, in this order, and the order matters. The fixed table first,
/// because a key with no character (F1, an arrow, Escape) translates to a
/// control character that renders as nothing at all — an invisible label reads
/// as an unset shortcut. Then the **current keyboard layout**, because a
/// virtual key code is a position rather than a character: 0x06 is `Z` on
/// QWERTY and `W` on AZERTY, and a binding must read back as the key the user
/// actually pressed on the keyboard they actually have.
///
/// Never empty. The last resort names the raw code, because a row showing `⌘`
/// with nothing after it looks unset while being set — the same
/// looks-fine-does-nothing shape this feature is full of.
func hotKeyKeyLabel(_ keyCode: UInt16) -> String {
    if let named = hotKeyNamedKeys[keyCode] { return named }
    if let translated = hotKeyLayoutCharacter(keyCode) { return translated }
    return "Key \(keyCode)"
}

/// The keys whose names cannot come from the layout, with the glyphs macOS
/// itself uses in menus. Function keys are spelled out rather than glyphed
/// because there is no glyph for them and "F13" is what is printed on the key.
private let hotKeyNamedKeys: [UInt16: String] = [
    UInt16(kVK_Return): "↩",
    UInt16(kVK_Tab): "⇥",
    UInt16(kVK_Space): "Space",
    UInt16(kVK_Delete): "⌫",
    UInt16(kVK_Escape): "⎋",
    UInt16(kVK_CapsLock): "⇪",
    UInt16(kVK_ANSI_KeypadClear): "⌧",
    UInt16(kVK_ANSI_KeypadEnter): "⌤",
    UInt16(kVK_Help): "Help",
    UInt16(kVK_Home): "↖",
    UInt16(kVK_PageUp): "⇞",
    UInt16(kVK_ForwardDelete): "⌦",
    UInt16(kVK_End): "↘",
    UInt16(kVK_PageDown): "⇟",
    UInt16(kVK_LeftArrow): "←",
    UInt16(kVK_RightArrow): "→",
    UInt16(kVK_DownArrow): "↓",
    UInt16(kVK_UpArrow): "↑",
    UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
    UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
    UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
    UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
    UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
    UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
]

/// The character this key produces on the layout in front of the user right
/// now, uppercased, or `nil` when it produces nothing printable.
///
/// `kUCKeyActionDisplay` with `kUCKeyTranslateNoDeadKeysBit` is the
/// combination that asks "what is printed on this key" rather than "what would
/// typing it produce", so a dead key (´ on a French layout) names itself
/// instead of silently composing with whatever comes next.
///
/// The printability check is not defensive padding. Every key code with no
/// character still translates — to a control character, usually 0x10 — and a
/// label made of one of those is a label that draws as nothing.
private func hotKeyLayoutCharacter(_ keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
        .takeRetainedValue(),
        let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

    var deadKeyState: UInt32 = 0
    var characters = [UniChar](repeating: 0, count: 8)
    var length = 0
    let status: OSStatus = layoutData.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return OSStatus(paramErr) }
        return UCKeyTranslate(
            base.assumingMemoryBound(to: UCKeyboardLayout.self),
            keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
            characters.count, &length, &characters)
    }
    guard status == noErr, length > 0 else { return nil }

    let text = String(utf16CodeUnits: characters, count: length)
    guard let scalar = text.unicodeScalars.first,
          !CharacterSet.controlCharacters.contains(scalar),
          !CharacterSet.whitespacesAndNewlines.contains(scalar)
    else { return nil }
    return text.uppercased()
}

// MARK: - The actions a shortcut can take

/// **Two actions, not one toggle**, and the argument is the point of this
/// comment rather than a note on it.
///
/// A toggle is only safe when its current state is visible at the moment you
/// press it, and the entire point of a *global* hot key is that you are not
/// looking at the menu bar — you are in another app, quite possibly
/// full-screen. A toggle pressed against a wrong assumption does the opposite
/// of what was wanted, and this is the one surface in the product that gives no
/// feedback either way, so the mistake is silent as well as wrong. Two verbs
/// are idempotent in the direction people mean them: press start twice and you
/// have started twice, which is harmless; press stop twice and the second does
/// nothing.
///
/// **Both map onto something the menu already does.** A hot key must never be
/// able to do something the menu cannot, because the menu is where the
/// consequence is visible.
enum HotKeyAction: String, CaseIterable, Identifiable {
    /// The menu's leading "Keep awake…" row: the stored default kind, with the
    /// stored power request. `MenuDefaultStart` is the single definition of
    /// what that is, so this and the menu cannot drift.
    case startDefaultSession

    /// `stopAllSessions(all: false)` — the menu's "Stop all mine".
    ///
    /// **The name says what it does, which is narrower than the obvious name,
    /// and the narrowing is deliberate.** `stopAllSessions(all: false)` scopes
    /// through `SessionIsolation.sessionsToStop`, which filters
    /// `$0.owner == caller`; the caller here is the app, so the set is exactly
    /// `app-<uid>`. This user's own trigger session is owned by `agent-<uid>`
    /// and their own CLI session by `cli-<uid>`, and **neither is stopped**.
    ///
    /// So an earlier draft's `.stopMySessions` would have been a lie in the
    /// commonest case — a trigger session is frequently the only thing keeping
    /// the Mac awake, that being what triggers are *for* — on the one surface
    /// with no visual feedback, where "nothing happened" and "it worked" are
    /// indistinguishable. And the menu now labels those very sessions as the
    /// user's own, so the contradiction would be one the app creates itself.
    ///
    /// The alternative fix, `stopAllSessions(all: true)`, is rejected outright:
    /// that is `keepy-uppy off --all`, it ends **other users'** sessions, and a
    /// cross-user escalation behind an unlabelled global keystroke is the worst
    /// possible home for one. Widening the app's own isolation scope is a
    /// daemon and spec decision and is not smuggled in here.
    case stopAppSessions

    var id: String { rawValue }

    /// The Settings row, which is also the only place the scope is ever stated.
    var label: String {
        switch self {
        case .startDefaultSession: return "Start the menu's default session"
        case .stopAppSessions: return "Stop sessions started from the menu"
        }
    }

    /// Named here, once, for the reason `DefaultWakeModePreference.key` is: the
    /// pane that writes it and the centre that reads it are different files that
    /// never call each other, and a typo in either is not a compile error — it
    /// is a recorder that appears to work above a shortcut that never registers.
    var preferenceKey: String {
        switch self {
        case .startDefaultSession: return "hotKeyStartDefaultSession"
        case .stopAppSessions: return "hotKeyStopAppSessions"
        }
    }

    /// The id carried in Carbon's `EventHotKeyID`, and the only thing the event
    /// handler gets to identify a keypress by.
    ///
    /// Explicit per case rather than an index into `allCases`: reordering the
    /// enum would otherwise repoint a live registration at the other action,
    /// silently, and the only symptom would be a shortcut that stops sessions
    /// when it was asked to start one. Never 0, because that is what an
    /// uninitialised `EventHotKeyID` carries.
    var hotKeyID: UInt32 {
        switch self {
        case .startDefaultSession: return 1
        case .stopAppSessions: return 2
        }
    }

    init?(hotKeyID: UInt32) {
        guard let match = HotKeyAction.allCases.first(where: { $0.hotKeyID == hotKeyID })
        else { return nil }
        self = match
    }
}

// MARK: - What the menu would start

/// The whole of "what the menu's leading Start row would start", in one place
/// both the menu and the hot key build.
///
/// **This exists because the hot key and the menu row must not drift, and the
/// way they drift is an axis being added to one of them.** There were two such
/// values when this feature was first sketched and there are three now
/// (`defaultSessionKind`, `DefaultWakeModePreference`,
/// `DefaultKeepDisksAwakePreference`) — the third arrived with the disk axis
/// and would have been missed by a shortcut that hard-coded "the same two
/// values the menu reads". A fourth has to be added here, once, and both call
/// sites get it because both construct this type.
///
/// Two initialisers because the two call sites genuinely differ.
/// `MenuContent` holds live `@AppStorage` properties — it must, so the menu
/// redraws when Settings changes — and passes their current values in.
/// `HotKeyCenter` has no view to observe from and reads the suite at the
/// instant the key is pressed, which is also the only moment its answer
/// matters. `MenuDefaultStartTests` welds the two together by checking they
/// agree on the same three values.
struct MenuDefaultStart: Equatable {
    let kind: DefaultSessionKind
    let power: PowerRequest

    /// From three raw values, each falling back exactly as the menu's own
    /// readers do.
    init(kindRawValue: String, wakeModeRawValue: String, keepsDisksAwake: Bool) {
        self.kind = DefaultSessionKind(rawValue: kindRawValue) ?? .indefinite
        self.power = PowerRequest(
            wakeMode: DefaultWakeModePreference.mode(rawValue: wakeModeRawValue),
            keepsDisksAwake: keepsDisksAwake)
    }

    /// From the stored preferences, read now.
    init(readingFrom defaults: UserDefaults) {
        self.init(
            kindRawValue: defaults.string(forKey: "defaultSessionKind") ?? "",
            wakeModeRawValue: defaults.string(forKey: DefaultWakeModePreference.key) ?? "",
            keepsDisksAwake: defaults.object(forKey: DefaultKeepDisksAwakePreference.key) as? Bool
                ?? DefaultKeepDisksAwakePreference.fallback)
    }

    /// The relative intent turned absolute at the instant it is used, never
    /// stored — the rule `DefaultSessionKind` states in full.
    func sessionKind(now: Date) -> SessionKind { kind.sessionKind(now: now) }
}

// MARK: - macOS's own shortcuts

/// One entry from `CopySymbolicHotKeys` — a shortcut macOS itself owns, such as
/// Spotlight or a screenshot.
///
/// **These are not `RegisterEventHotKey` registrations**, which is the whole
/// problem: the window server consumes the key upstream, so registering the
/// same combination returns `noErr`, the app believes it succeeded, and the
/// shortcut simply never fires. `kEventHotKeyExclusive` cannot see them —
/// measured in `HotKeyRegistrationTests`, where ⌘Space registers cleanly.
///
/// `carbonModifiers` is stored raw rather than converted on the way in, because
/// **it is not purely `EventModifiers`**. Measured on macOS 26.5: of the 230
/// entries this API returns, 110 carry bit 0x20000, which no SDK header names
/// and which appears only on function and arrow keys. Keeping the raw value
/// lets `systemShortcutTakes` skip those entries on a rule that can be stated
/// (see there) instead of quietly reinterpreting a bit nobody has identified.
struct SystemShortcut: Equatable {
    let keyCode: UInt16
    let carbonModifiers: UInt32
    let isEnabled: Bool
}

/// Whether macOS already owns this combination, so far as it can be known.
///
/// **Conservative on purpose, in the one direction that matters.** An entry is
/// only considered when its modifiers are entirely within the four this app can
/// record; an entry carrying the unnamed 0x20000 bit describes a combination no
/// binding here can equal, because `RegisterEventHotKey` takes a 16-bit
/// `EventModifiers` with no room for it. Matching on the low bits alone would
/// report ⌃⇧↑ as taken by Mission Control's ⌃↑ entry — a warning about a
/// shortcut that works, which is worse than the silence it replaced, because a
/// warning people learn to ignore is a warning that stops working for the cases
/// it is right about.
///
/// Disabled entries are skipped for the same reason: a shortcut the user turned
/// off in System Settings is not a conflict.
///
/// This does **not** make every silent conflict detectable, and the Settings
/// copy must not imply it does. Another app holding the key — through an event
/// tap, a non-exclusive registration, or its own frontmost-only shortcut — is
/// invisible from here, and there is no API that enumerates those.
func systemShortcutTakes(_ binding: HotKeyBinding?, among shortcuts: [SystemShortcut]) -> Bool {
    guard let binding else { return false }
    let wanted = binding.modifiers.carbonFlags
    return shortcuts.contains { shortcut in
        guard shortcut.isEnabled else { return false }
        // Every bit it carries must be one this app could have produced.
        guard shortcut.carbonModifiers & ~HotKeyModifiers.all.carbonFlags == 0 else { return false }
        return shortcut.keyCode == binding.keyCode && shortcut.carbonModifiers == wanted
    }
}

// MARK: - The development-only override

/// Bindings named by the launch environment, for driving this feature during
/// development.
///
/// **This is the only way to arm a hot key without writing a preference, and
/// that is the entire reason it exists.** `PreferencesSuite.name` is the
/// production domain outside XCTest; the installed app reads it live through
/// `@AppStorage`; and a stored binding outlives the process that wrote it — so
/// a "temporary default" set from a development build would arm an arbitrary
/// global shortcut in the user's shipping app and leave it armed after the
/// development build quit. (The header's promise that the system unregisters at
/// termination does not help: it ends the *registration*, not the stored
/// *binding*.) An environment variable is read once, by one process, and dies
/// with it.
///
/// Format: `KEEPY_UPPY_DEBUG_HOTKEY_START_DEFAULT_SESSION=control,option,shift,command:90`.
/// Anything that does not parse exactly is ignored rather than guessed at,
/// because the guess would be a global shortcut nobody typed.
func hotKeyDebugBindings(in environment: [String: String]) -> [HotKeyAction: HotKeyBinding] {
    var bindings: [HotKeyAction: HotKeyBinding] = [:]
    for action in HotKeyAction.allCases {
        guard let specification = environment[action.debugEnvironmentVariable],
              let binding = hotKeyBinding(fromDebugSpecification: specification)
        else { continue }
        bindings[action] = binding
    }
    return bindings
}

private func hotKeyBinding(fromDebugSpecification specification: String) -> HotKeyBinding? {
    let parts = specification.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    var modifiers = HotKeyModifiers()
    let names = parts[0].split(separator: ",", omittingEmptySubsequences: false)
    guard !names.isEmpty else { return nil }
    for name in names {
        switch name {
        case "control": modifiers.insert(.control)
        case "option": modifiers.insert(.option)
        case "shift": modifiers.insert(.shift)
        case "command": modifiers.insert(.command)
        default: return nil
        }
    }

    // Bounded to the virtual key-code range rather than to `UInt16`: a value
    // outside it is a typo, and `RegisterEventHotKey` would accept it.
    guard let code = UInt16(parts[1]), code <= 0xFF else { return nil }
    return HotKeyBinding(keyCode: code, modifiers: modifiers)
}

extension HotKeyAction {
    /// Deliberately not derived from `preferenceKey`. These two strings must
    /// never be confusable: one is read from an environment nobody persists,
    /// the other names a value written to disk in the user's own preferences.
    var debugEnvironmentVariable: String {
        switch self {
        case .startDefaultSession: return "KEEPY_UPPY_DEBUG_HOTKEY_START_DEFAULT_SESSION"
        case .stopAppSessions: return "KEEPY_UPPY_DEBUG_HOTKEY_STOP_APP_SESSIONS"
        }
    }
}
