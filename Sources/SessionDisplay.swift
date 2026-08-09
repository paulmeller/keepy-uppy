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
    case .whileCPUBusy(let threshold):
        // The threshold is named because it is now the user's to pick
        // (`keepy-uppy on --while-cpu-busy 30`). "While the CPU is busy" was
        // written when nothing could choose one, and it renders two sessions
        // with different thresholds as the same row, in the one surface whose
        // job is to say why this Mac is awake.
        //
        // A percentage rather than the stored fraction, matching what was typed
        // — `Int` interpolation carries no locale, so there is no separator to
        // vary. Rounded rather than truncated so a threshold that arrived from
        // somewhere other than the CLI still reads as the nearest whole
        // percentage rather than one below it.
        return "While the CPU is at least \(Int((threshold * 100).rounded()))% busy"
    case .whileProcessRunning(let processName):
        return "While \(processName) is running"
    case .whileVolumeMounted(let name):
        return "While \(name) is mounted"
    case .whileOnSubnet(let cidr):
        return "While on \(cidr)"
    }
}

/// **Currently unreachable from the app.** Nothing outside the tests calls
/// this: the menu rebuild replaced the row it used to render
/// ("Indefinite — Started manually — Stop") with `menuStopLabel`, and the
/// automatic case is served by `menuAutomaticSuffix` below — which has a
/// reachability problem of its own, documented there. Kept, not deleted,
/// because Plan 5 (trigger expansion) is expected to want exactly this string
/// back; the note is here so a reader does not take its existence as evidence
/// that anything shows it today.
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

/// The picker row in the Add sheet — the *kind* on its own, before anything has
/// been typed into it.
///
/// These strings used to be the raw values of a parallel enum,
/// `AddTriggerSheet.ConditionKind` — the same arrangement as the one that left
/// three `SessionKind` cases unreachable from every client. (That was
/// `CLICommand.OnOption` and `DefaultSessionKind`, a different pair of lists
/// entirely; this picker never caused it. The resemblance is the point, not a
/// shared history.) They are here
/// instead for the reason `wakeModeSettingsTitle` is: user-facing copy belongs
/// on this side of the boundary, and a raw value is a wire name that `Shared/`
/// compiles into the daemon and the CLI, neither of which should carry Settings
/// prose. The picker now loops `TriggerConditionKind.allCases`, so a new
/// condition appears in it automatically and fails to compile *here* until
/// somebody writes its label.
func triggerConditionKindLabel(_ kind: TriggerConditionKind) -> String {
    switch kind {
    case .appLaunched: return "An app launches"
    case .externalDisplayConnected: return "An external display connects"
    case .acPowerConnected: return "Power is connected"
    case .processRunning: return "A process is running"
    case .appFrontmost: return "An app comes to the front"
    case .volumeMounted: return "A volume is mounted"
    case .onSubnet: return "This Mac is on a network"
    }
}

/// **A trigger starts a session; it does not bind that session's lifetime to
/// the condition** — unless `TriggerCondition.boundSessionKind` says it does.
/// `EvidenceLoopRunner` starts `rule.defaultKind`'s kind — `.indefinite`,
/// `.duration(...)` — and `sessionsToEnd` explicitly skips exactly those kinds,
/// so nothing ends the session when the condition stops being true. Wording that
/// implies otherwise ("while it's running") promises a stop that will never
/// come: plug a display in, unplug it, and an indefinite session keeps the Mac
/// awake forever. Every string here is phrased as the *starting event* for that
/// reason — except for a condition that binds, where "while" is the literal
/// truth, because `sessionKind(firing:now:)` starts the bound kind and
/// `sessionsToEnd` really does end it.
///
/// `.processRunning`, `.volumeMounted` and `.onSubnet` are the three such
/// conditions today.
/// Which ones say "while" is pinned against `bindsSessionLifetime` in
/// `SessionDisplayTests`, not against a list of case names, so a seventh
/// condition cannot pick the wrong voice quietly.
func triggerConditionTitle(_ condition: TriggerCondition) -> String {
    switch condition {
    case .appLaunched(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) launches"
    case .externalDisplayConnected: return "When an external display connects"
    case .acPowerConnected: return "When power is connected"
    case .processRunning(let processName): return "While \(processName) is running"
    case .appFrontmost(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) comes to the front"
    case .volumeMounted(let name): return "While \(name) is mounted"
    case .onSubnet(let cidr): return "While this Mac is on \(cidr)"
    }
}

/// The second line of a trigger row: what starting it actually does.
///
/// A condition that binds its session's lifetime gets `triggerBoundEffectSubtitle`
/// instead of the duration phrase — `defaultKind` is stored on the rule but
/// ignored when it fires, so describing it here would be describing a duration
/// that will never take effect. The branch is keyed off `boundSessionKind`, the
/// same table `sessionKind(firing:now:)` reads, rather than off a second
/// `.processRunning` match as it was.
func triggerEffectSubtitle(_ rule: TriggerRule) -> String {
    if let bound = triggerBoundEffectSubtitle(rule.condition) { return bound }
    return "Starts a session that keeps this Mac awake \(rule.defaultKind.durationPhrase)"
}

/// What a lifetime-binding condition's row says instead of a duration, or `nil`
/// for a condition that has a duration to report.
///
/// Exhaustive, so a new condition must decide; and `SessionDisplayTests` pins
/// which branch it lands in against `bindsSessionLifetime`, so "binds but reads
/// as timed" and "timed but reads as bound" are both test failures rather than a
/// row that quietly misdescribes what the daemon will do.
func triggerBoundEffectSubtitle(_ condition: TriggerCondition) -> String? {
    switch condition {
    case .appLaunched, .externalDisplayConnected, .acPowerConnected, .appFrontmost:
        return nil
    case .processRunning(let processName):
        return "Keeps this Mac awake until \(processName) exits"
    case .volumeMounted(let name):
        return "Keeps this Mac awake until \(name) is unmounted"
    case .onSubnet(let cidr):
        return "Keeps this Mac awake until it leaves \(cidr)"
    }
}

/// The Add sheet's replacement for the duration picker: for a binding condition
/// there is no duration to pick, and a picker that was shown and then discarded
/// is worse than one that isn't there. This is the sentence that goes where it
/// would have been, so its absence is explained rather than merely noticed.
///
/// Distinct from `triggerBoundEffectSubtitle` because it is read while the sheet
/// is still being filled in — the process name is typically empty — where the row
/// subtitle only ever describes a saved rule.
func triggerBindingFootnote(_ condition: TriggerCondition) -> String? {
    switch condition {
    case .appLaunched, .externalDisplayConnected, .acPowerConnected, .appFrontmost:
        return nil
    case .processRunning(let processName):
        let subject = processName.isEmpty ? "the process" : processName
        return "Ends automatically when \(subject) exits — no duration to pick."
    case .volumeMounted(let name):
        let subject = name.isEmpty ? "the volume" : name
        return "Ends automatically when \(subject) is unmounted — no duration to pick."
    case .onSubnet(let cidr):
        let subject = cidr.isEmpty ? "that network" : cidr
        return "Ends automatically when this Mac leaves \(subject) — no duration to pick."
    }
}

/// What the Triggers pane says when the store holds rules this build cannot
/// decode, or `nil` when it holds none.
///
/// `TriggerStore` keeps such a rule and writes it back untouched, so nothing is
/// lost — but it cannot be shown in the list, cannot be edited, and will not
/// fire while this build is the one running. Without this line the user sees a
/// pane that is missing a trigger they wrote, or, if every rule they have came
/// from the newer build, the "No Triggers" empty state telling them they have
/// none. Preserving the rule silently would fix the data loss and leave the
/// alarming part intact.
///
/// It says *kept* explicitly. The obvious reading of a missing trigger is that
/// something deleted it, and the second-obvious response is to recreate it —
/// which on the older build means writing a duplicate that the newer one will
/// then show twice.
func unreadableTriggerNotice(count: Int) -> String? {
    guard count > 0 else { return nil }
    if count == 1 {
        return "1 trigger was created by a newer version of Keepy Uppy. It can't be shown here and won't run on this version, but it has been kept — no need to recreate it."
    }
    return "\(count) triggers were created by a newer version of Keepy Uppy. They can't be shown here and won't run on this version, but they have been kept — no need to recreate them."
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
///
/// **It never fires today, on two independent counts, and neither is a bug in
/// this function.** `MenuContent` appends it only to `mine` — sessions owned by
/// `app-<uid>` — while the only thing that produces `origin == .trigger` is the
/// agent, and the daemon stamps `owner` from the accepting listener's role, so
/// a trigger session is owned by `agent-<uid>` and lands in `others`. Those
/// rows render `menuForeignSessionLabel`, which has no suffix at all. So an
/// automatic session reads `Indefinite — started elsewhere`, exactly like the
/// CLI's or another user's.
///
/// Kept rather than deleted: a user being unable to tell an automatic session
/// from a foreign one is a real product gap, and closing it is Plan 5's
/// (trigger expansion), which will want this string. The note exists so the
/// next reader does not conclude from the code that the tag already works —
/// `SessionDisplayTests` covers the function, not its reachability.
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
/// trigger-started session is built by `Agent/EvidenceLoopRunner.swift` with an
/// explicit `wakeMode: .clamshell`, so it is lid-safe whatever is stored here.
/// Said as the positive fact about triggers, which stays true under the union.
///
/// "from now on" is not filler. A session's mode is fixed when it starts —
/// nothing here reaches a running one — and someone who switches this picker to
/// the lid-closed mode expecting their live `.system` session to follow will
/// shut the lid on a Mac that then sleeps. Two surfaces still tell the truth
/// (that session's own tag in the menu, and `menuLidCaveat`), so this clause is
/// a nudge rather than the guard; it is here because it costs three words and
/// the failure it heads off is the one that loses work.
let wakeModeSettingsScopeNote = "Sessions you start from the menu from now on use this. The command line picks a mode per session with its own flags, and an automatic trigger always keeps this Mac awake with the lid closed."
