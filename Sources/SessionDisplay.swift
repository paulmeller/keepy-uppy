import AppKit
import Foundation

/// The small, fixed set of quick-start choices shown in the menu and
/// configurable as a default in Settings' General tab. Deliberately not
/// arbitrary custom durations or `--while-app` (the CLI already covers
/// those, per spec §9's CLI/UI split) — the menu is meant to cover the
/// common case with one or two clicks, not replicate every CLI flag.
enum DefaultSessionKind: String, CaseIterable, Codable, Identifiable {
    case indefinite, oneHour, fourHours, eightHours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .indefinite: return "Indefinitely"
        case .oneHour: return "For 1 Hour"
        case .fourHours: return "For 4 Hours"
        case .eightHours: return "For 8 Hours"
        }
    }

    func sessionKind(now: Date) -> SessionKind {
        switch self {
        case .indefinite: return .indefinite
        case .oneHour: return .duration(until: now.addingTimeInterval(3600))
        case .fourHours: return .duration(until: now.addingTimeInterval(4 * 3600))
        case .eightHours: return .duration(until: now.addingTimeInterval(8 * 3600))
        }
    }
}

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
