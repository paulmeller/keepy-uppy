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
/// phrased as the *starting event* for that reason.
func triggerConditionTitle(_ condition: TriggerCondition) -> String {
    switch condition {
    case .appLaunched(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) launches"
    case .externalDisplayConnected: return "When an external display connects"
    case .acPowerConnected: return "When power is connected"
    }
}

/// The second line of a trigger row: what starting it actually does.
func triggerEffectSubtitle(_ rule: TriggerRule) -> String {
    "Starts a session that keeps this Mac awake \(rule.defaultKind.durationPhrase)"
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
