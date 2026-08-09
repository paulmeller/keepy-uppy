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
func menuStopLabel(for session: Session, isOnlyOneOfMine: Bool, now: Date) -> String {
    guard !isOnlyOneOfMine else { return "Stop keeping awake" }
    return "Stop “\(remainingTimeText(for: session, now: now).lowercased())”"
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
}

func menuStartLabel(_ kind: DefaultSessionKind) -> String {
    "Keep awake \(kind.durationPhrase)"
}
