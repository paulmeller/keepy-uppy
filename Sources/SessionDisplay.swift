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
