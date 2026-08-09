import SwiftUI
import AppKit
import Foundation

// `DefaultSessionKind` used to live here. It moved to
// `Shared/DefaultSessionKind.swift` so `Shared/TriggerRule.swift` and the
// agent's evidence loop can both see it — see that file's comment. What
// remains below is app-UI-only formatting with an AppKit (`NSWorkspace`)
// dependency, which must NOT move into `Shared/`: `Shared/` compiles into
// the daemon and CLI, and neither may gain an AppKit dependency.

func remainingTimeText(for session: Session, now: Date) -> String {
    switch session.kind {
    case .indefinite:
        return "Indefinite"
    case .duration(let until), .untilTime(let until), .lease(let until):
        let seconds = max(0, until.timeIntervalSince(now))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        return "\(minutes)m left"
    case .whileAppRunning(let bundleID):
        let name = appDisplayName(bundleID: bundleID)
        return "While \(name) is running"
    case .whileExternalDisplay:
        return "While an external display is connected"
    case .whileOnACPower:
        return "While on AC power"
    case .whileCPUBusy:
        return "While the CPU is busy"
    case .whileProcessRunning(let processName):
        return "While \(processName) is running"
    }
}

func originText(for session: Session) -> String {
    session.origin == .trigger ? "Started automatically" : "Started manually"
}

/// Best-effort friendly name for a bundle id, falling back to the id
/// itself when the app isn't installed/discoverable — this is display
/// text only, never used for matching logic.
func appDisplayName(bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let bundle = Bundle(url: url),
          let name = bundle.infoDictionary?["CFBundleName"] as? String
    else { return bundleID }
    return name
}

// MARK: - Trigger rows

/// **A trigger starts a session; it does not bind that session's lifetime to
/// the condition.** `EvidenceLoopRunner` starts `rule.defaultKind`'s kind —
/// `.indefinite`, `.duration(...)` — and `sessionsToEnd` explicitly skips
/// exactly those kinds, so nothing ends the session when the condition stops
/// being true. Wording that implies otherwise ("while it's running") promises
/// a stop that will never come: plug a display in, unplug it, and an
/// indefinite session keeps the Mac awake forever. Every string here is
/// phrased as the *starting event* for that reason —
/// **except `.processRunning`, deliberately.** That condition is the one
/// exception to the rule above: `TriggerRule.sessionKind(firing:now:)`
/// ignores `defaultKind` for it and always starts `.whileProcessRunning`,
/// which `sessionsToEnd` *does* end when the process exits. So this is the
/// only condition allowed to say "while" — because it's the only one that's
/// actually true.
func triggerConditionTitle(_ condition: TriggerCondition) -> String {
    switch condition {
    case .appLaunched(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) launches"
    case .externalDisplayConnected: return "When an external display connects"
    case .acPowerConnected: return "When power is connected"
    case .processRunning(let processName): return "While \(processName) is running"
    }
}

/// The second line of a trigger row: what starting it actually does.
/// `.processRunning` is again the deliberate exception documented on
/// `triggerConditionTitle` above — `defaultKind` is stored on the rule but
/// ignored when it fires, so describing it here would be describing a
/// duration that will never take effect.
func triggerEffectSubtitle(_ rule: TriggerRule) -> String {
    if case .processRunning(let processName) = rule.condition {
        return "Keeps this Mac awake until \(processName) exits"
    }
    return "Starts a session that keeps this Mac awake \(rule.defaultKind.durationPhrase)"
}

extension DefaultSessionKind {
    /// Reads as a continuation of a sentence, which `label` ("Indefinitely",
    /// "For 1 Hour") does not once dropped mid-phrase.
    var durationPhrase: String {
        switch self {
        case .indefinite: return "indefinitely"
        case .oneHour: return "for 1 hour"
        case .fourHours: return "for 4 hours"
        case .eightHours: return "for 8 hours"
        }
    }
}

// MARK: - Safety pane copy

func thermalSensitivityTitle(_ level: ThermalSensitivity) -> String {
    switch level {
    case .off: return "Never stop"
    case .cautious: return "Cautious"
    case .balanced: return "Balanced"
    case .permissive: return "Permissive"
    }
}

/// Written in terms of what the user will observe. The underlying levels
/// ("fair", "serious") are `SafetyEngine` jargon and mean nothing outside it.
func thermalSensitivityExplanation(_ level: ThermalSensitivity) -> String {
    switch level {
    case .off:
        return "Sessions keep running no matter how hot this Mac gets. Nothing here will stop them."
    case .cautious:
        return "Stops sessions as soon as this Mac gets warm and the fans pick up. Safest with the lid closed, and the most likely to interrupt a long build."
    case .balanced:
        return "Stops sessions once this Mac is genuinely throttling — hot enough that work has already slowed down. Recommended."
    case .permissive:
        return "Stops sessions only at critical temperature. Lets this Mac run hot for as long as it can before giving up."
    }
}

/// Reads the effective thresholds off `SafetyConfig` rather than restating
/// them, so the pane cannot drift from the engine that enforces them.
func batteryGuardFootnote(_ config: SafetyConfig) -> String {
    guard let open = config.effectiveBatteryCutoff(lidClosed: false) else {
        return "The battery guard is off. Sessions keep running on battery however low it gets."
    }
    let closed = config.effectiveBatteryCutoff(lidClosed: true) ?? open
    guard closed != open else {
        return "On battery, sessions stop at \(open)% so this Mac doesn't run flat while you're away."
    }
    return "On battery, sessions stop at \(open)% — or \(closed)% with the lid closed, where this Mac can't cool itself as well."
}

func maxSessionLengthLabel(_ config: SafetyConfig) -> String {
    let hours = Int((config.maxSessionDuration ?? 0) / 3600)
    return hours == 1 ? "1 hour" : "\(hours) hours"
}

// MARK: - Background service status

func serviceStatusTitle(_ state: OnboardingService.State) -> String {
    switch state {
    case .running: return "Running"
    case .needsApproval: return "Waiting for approval"
    case .notEnabled: return "Not enabled"
    }
}

/// Shape as well as colour: colour alone would carry the whole meaning for a
/// reader who can't distinguish green from orange.
func serviceStatusSymbol(_ state: OnboardingService.State) -> String {
    switch state {
    case .running: return "checkmark.circle.fill"
    case .needsApproval: return "exclamationmark.triangle.fill"
    case .notEnabled: return "xmark.circle.fill"
    }
}

func serviceStatusTint(_ state: OnboardingService.State) -> Color {
    switch state {
    case .running: return .green
    case .needsApproval: return .orange
    case .notEnabled: return .secondary
    }
}

func backgroundServicesFootnote(_ state: OnboardingService.State) -> String {
    switch state {
    case .running:
        // Both are always-on by design: the agent's plist sets RunAtLoad and
        // KeepAlive, and the daemon has no idle exit. Claiming they "stop when
        // no session is running" (as this footer briefly did) is simply false,
        // and misdescribes two processes a user may be deciding whether to
        // trust.
        return "These stay running in the background so a trigger can start a session while you're away. Sleep is only held off while a session is actually active."
    case .needsApproval:
        return "macOS needs you to approve these in System Settings → General → Login Items & Extensions before they can run."
    case .notEnabled:
        return "Keepy Uppy can't keep this Mac awake until these are enabled."
    }
}

// MARK: - Menu bar

/// The menu's first line: what is happening, in one glance, with no jargon.
///
/// It is a *label*, never a button. The previous menu made each session row
/// itself the stop button, with the verb buried at the end of
/// "Indefinite — Started manually — Stop" — so the one interactive thing in
/// the list read as a status line, and the two facts in front of the verb were
/// noise. Status and action are separate things now.
func menuStatusLine(mine: [Session], others: [Session], now: Date) -> String {
    let all = mine.count + others.count
    guard all > 0 else { return "Not keeping awake" }
    if all == 1, let only = (mine + others).first {
        return "Keeping awake — \(remainingTimeText(for: only, now: now).lowercased())"
    }
    if others.isEmpty { return "Keeping awake — \(all) sessions" }
    if mine.isEmpty { return "Keeping awake — \(all) sessions, none yours" }
    return "Keeping awake — \(all) sessions, \(mine.count) yours"
}

/// Verb first, so the row is visibly a thing you can do. With exactly one
/// session of your own there is nothing to disambiguate, so it says the plain
/// thing rather than quoting a description back at you.
///
/// The wake-mode tag is appended *here*, not composed by the view, for the
/// same structural reason `Session.renewed(until:)` lives next to the stored
/// properties: a row that has to remember to concatenate a suffix is a row
/// that will one day forget, and a forgotten mode tag is invisible — it looks
/// exactly like a lid-safe session. `menuAutomaticSuffix` stays separate
/// because it is genuinely optional trim; this is not.
///
/// The tagged single-session row names a **noun** — "Stop this session (lid
/// open only)", not "Stop keeping awake (lid open only)". A parenthetical after
/// a bare imperative attaches to the verb, so the latter can be read as "stop
/// only while the lid is open", which is a statement about the button rather
/// than about the session. The multi-session form below never had the problem,
/// because its parenthetical follows a quoted description. The untagged label
/// is left exactly as it was: it is the overwhelmingly common case, it has no
/// parenthetical to misparse, and "annotate the exception, not the rule" means
/// a user who never opens Settings sees the menu unchanged.
func menuStopLabel(for session: Session, isOnlyOneOfMine: Bool, now: Date) -> String {
    let tag = menuWakeModeSuffix(session.wakeMode)
    guard !isOnlyOneOfMine else {
        return (tag.isEmpty ? "Stop keeping awake" : "Stop this session") + tag
    }
    return "Stop “\(remainingTimeText(for: session, now: now).lowercased())”" + tag
}

/// Origin earns a mention only when it is surprising. "Started manually" on a
/// session you started by hand is noise; "started automatically" on one that
/// appeared by itself is the whole story.
func menuAutomaticSuffix(for session: Session) -> String {
    session.origin == .trigger ? " (started automatically)" : ""
}

/// Sessions belonging to the CLI, the agent, or another user. They are shown
/// — the menu's job is to answer "why is my Mac awake", whoever caused it —
/// but this app cannot stop them, and a button that silently does nothing is
/// worse than a line of text.
func menuForeignSessionLabel(for session: Session, now: Date) -> String {
    "\(remainingTimeText(for: session, now: now)) — started elsewhere"
        + menuWakeModeSuffix(session.wakeMode)
}

/// The stored default is what these rows will actually start, so a default
/// that is not `.clamshell` is named on the button that acts on it — the same
/// argument that put the CLI's caveat on stderr at the moment the flag is
/// typed, rather than in a README. It costs nothing in the overwhelmingly
/// common case, where the tag is empty.
func menuStartLabel(_ kind: DefaultSessionKind, wakeMode: WakeMode) -> String {
    "Keep awake \(kind.durationPhrase)" + menuWakeModeSuffix(wakeMode)
}

// MARK: - Wake mode

/// How a session's `WakeMode` reads in a menu row — `nil` for the mode that
/// needs no explanation.
///
/// **Annotate the exception, not the rule.** `.clamshell` is the default, the
/// strongest mode, and what every session started by this app, by a trigger,
/// or by an unflagged `keepy-uppy on` is. A badge on all of those would be a
/// badge on nearly every row of a menu that was rebuilt this week precisely
/// because each row carried too much.
///
/// What the tag says is the **lid**, not the display, and that is not a
/// stylistic choice. `.clamshell` and `.system` are *identical* in what they
/// do to the screen — neither takes `preventIdleDisplaySleep`
/// (`PowerPlan.reduce`) — so a tag reading "display may sleep" on a `.system`
/// session would imply a difference from the default that does not exist. The
/// only thing `.system` gives up relative to the default is surviving a lid
/// close, and `.systemAndDisplay` gives up the same thing and additionally
/// holds the screen on.
///
/// It is a statement about **this session**, never about the machine: the
/// daemon unions every live session's mode, so a concurrent `.clamshell`
/// session keeps the Mac awake lid-shut regardless. The machine-wide fact has
/// its own line — `menuLidCaveat(for:)` — computed from the union.
func menuWakeModeTag(_ mode: WakeMode) -> String? {
    switch mode {
    case .clamshell: return nil
    case .system: return "lid open only"
    case .systemAndDisplay: return "screen on, lid open only"
    }
}

/// `menuWakeModeTag` as something a row can concatenate unconditionally.
func menuWakeModeSuffix(_ mode: WakeMode) -> String {
    guard let tag = menuWakeModeTag(mode) else { return "" }
    return " (\(tag))"
}

/// The one machine-wide claim the menu is allowed to make, and the one surface
/// that can honestly make it.
///
/// `keepy-uppy on` knows only the session it is starting, so its caveat had to
/// be scoped to that session or be false whenever a second session was live.
/// The menu holds the **whole** list — every client's, every user's — so it can
/// answer the question that actually matters ("if I shut the lid now, does this
/// stop?") by running the daemon's own reduction over the same input the daemon
/// uses. Deriving it from `PowerPlan.reduce` rather than from any one session,
/// or from a hand-written "are they all non-clamshell" test, is what keeps the
/// menu and the mechanism from drifting.
///
/// `nil` when nothing is being kept awake (there is no guarantee to qualify)
/// and when the plan does hold the lid (the expected case, which says nothing).
func menuLidCaveat(for sessions: [Session]) -> String? {
    guard !sessions.isEmpty else { return nil }
    guard !PowerPlan.reduce(sessions.map(\.wakeMode)).sleepDisabled else { return nil }
    return "Closing the lid will still let this Mac sleep."
}

// MARK: - The stored default wake mode

/// The preference Settings writes and the menu reads, arranged exactly like
/// `DefaultSessionKind`'s: a raw value in `PreferencesSuite`, read back with a
/// fallback rather than a failure.
///
/// It is named here, once, for the reason `PreferencesSuite` itself is: two
/// files that never call each other agree on a string, and a typo in either is
/// not a compile error and not a crash — it is a Settings pane that appears to
/// work while the menu goes on reading the old value. `DefaultSessionKind`'s
/// key is still a literal in both files; that is the shape this deliberately
/// does not copy.
///
/// The fallback is `.clamshell` on exactly the CLI's reasoning: absence must
/// mean the strongest mode, because every other choice silently weakens the
/// sessions of everyone who never opened Settings.
enum DefaultWakeModePreference {
    static let key = "defaultWakeMode"

    /// Used both as the `@AppStorage` starting value and as the landing place
    /// for a value this build does not recognise.
    static let fallback = WakeMode.clamshell
    static var defaultRawValue: String { fallback.rawValue }

    static func mode(rawValue: String) -> WakeMode {
        WakeMode(rawValue: rawValue) ?? fallback
    }
}

/// The order the Settings picker offers the modes in — default first, as the
/// menu's start list also leads with the stored default. `WakeMode.allCases`
/// is declaration order, which puts the default last; pinning the display
/// order here rather than reordering the enum keeps a presentation decision
/// out of `Shared/`, where the daemon and CLI compile.
let wakeModeSettingsOrder: [WakeMode] = [.clamshell, .system, .systemAndDisplay]

/// The picker row. Named for what the user gets, not for the mechanism: the
/// raw values are camelCase wire strings, and "assertion" and "SleepDisabled"
/// are implementation vocabulary that mean nothing in a Settings window.
func wakeModeSettingsTitle(_ mode: WakeMode) -> String {
    switch mode {
    case .clamshell: return "Even with the lid closed"
    case .system: return "Only with the lid open"
    case .systemAndDisplay: return "Only with the lid open, screen on"
    }
}

/// The section footer, which changes with the selection — the same shape as
/// `thermalSensitivityExplanation`, for the same reason: a picker of three
/// short phrases can distinguish the options but cannot explain their
/// consequences.
///
/// Note which direction each sentence points. "Keeps this Mac awake even after
/// you shut the lid" is a *positive* claim about a `.clamshell` session and is
/// unconditionally true, because the daemon's union can only ever strengthen
/// it. "This Mac will sleep" would be a *negative* claim, and negatives are
/// union-sensitive — false the moment any other client holds a clamshell
/// session. So every negative below is scoped to "a session in this mode",
/// exactly as `WakeMode.lidCloseCaveat` is in the CLI.
func wakeModeSettingsExplanation(_ mode: WakeMode) -> String {
    switch mode {
    case .clamshell:
        return "The default, and the only mode that survives a lid close: a session in this mode keeps this Mac awake after you shut the lid. The screen is still free to sleep on its own — a closed lid turns it off anyway."
    case .system:
        return "Holds off idle sleep while the lid is open and leaves the screen free to sleep, which is usually what a long unattended job wants. A session in this mode does not survive a lid close; only the default does."
    case .systemAndDisplay:
        return "Keeps the screen lit as well as holding off idle sleep, for a dashboard or a progress window you want to be able to glance at. A session in this mode does not survive a lid close; only the default does."
    }
}

/// Whose sessions this actually governs, and **when**. Three of the four
/// clients ignore it: `keepy-uppy on` chooses per invocation with a flag, and a
/// trigger-started session is built by `Agent/EvidenceLoopRunner.swift` with no
/// `wakeMode:` at all, so it is `.clamshell` whatever is stored here. Said as
/// the positive fact about triggers, which stays true under the union.
///
/// "from now on" is not filler. A session's mode is fixed when it starts —
/// nothing here reaches a running one — and someone who switches this picker to
/// the lid-closed mode expecting their live `.system` session to follow will
/// shut the lid on a Mac that then sleeps. Two surfaces still tell the truth
/// (that session's own tag in the menu, and `menuLidCaveat`), so this clause is
/// a nudge rather than the guard; it is here because it costs three words and
/// the failure it heads off is the one that loses work.
let wakeModeSettingsScopeNote = "Sessions you start from the menu from now on use this. The command line picks a mode per session with its own flags, and an automatic trigger always keeps this Mac awake with the lid closed."
