import Foundation

enum TriggerCondition: Codable, Equatable {
    case appLaunched(bundleID: String)
    case externalDisplayConnected
    case acPowerConnected
}

struct TriggerRule: Codable, Equatable, Identifiable {
    let id: UUID
    var condition: TriggerCondition
    var sessionKind: SessionKind
    var enabled: Bool
}

/// Off by default (spec §8): an app that starts keeping the Mac awake
/// unasked is a bug, not a feature. Shared with the future UI (plan 3),
/// which is the only thing that will ever populate this beyond the
/// empty default.
///
/// `UserDefaults(suiteName:)` returns `nil` when `suiteName` equals the
/// *calling process's own* bundle identifier (an Apple-documented special
/// case, not a bug in this code) — and that is exactly the app target's
/// bundle identifier here (`au.com.workwireless.keepy-uppy`, see
/// `project.yml`). So from the app process (where the future Triggers
/// Settings tab this store exists for will actually run),
/// `UserDefaults(suiteName: suiteName)` is nil and `.standard` is the
/// correct fallback: for this exact degenerate case `.standard` resolves
/// to the identical underlying preferences file suite-named lookup would
/// have used, so the daemon (bundle id `...helper`, unaffected by this
/// case) and CLI still read back whatever the app wrote. Mirrors
/// `SafetyConfigStore`'s identical fix, confirmed empirically there via
/// `SafetyConfigStoreTests`, which runs inside the app process as the
/// test host and would silently no-op on save/load without this fallback.
enum TriggerStore {
    private static let suiteName = "au.com.workwireless.keepy-uppy"
    private static let key = "triggerRules"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func load() -> [TriggerRule] {
        guard let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([TriggerRule].self, from: data)
        else { return [] }
        return rules
    }

    static func save(_ rules: [TriggerRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Pure: which enabled rules have a true condition right now, excluding
/// any rule already represented by a live session (so a still-true
/// condition doesn't refire every tick — the daemon's admission path
/// would reject duplicates anyway via suppression/caps, but there is no
/// reason to hammer it).
func triggersToFire(
    _ rules: [TriggerRule],
    activeSessions: [Session],
    appRunning: AppRunningObserving,
    display: DisplayObserving,
    onACPower: Bool
) -> [TriggerRule] {
    let activeTriggerIDs = Set(activeSessions.compactMap(\.triggerID))
    return rules.filter { rule in
        guard rule.enabled, !activeTriggerIDs.contains(rule.id) else { return false }
        switch rule.condition {
        case .appLaunched(let bundleID):
            return appRunning.isRunning(bundleID: bundleID)
        case .externalDisplayConnected:
            return display.hasExternalDisplay()
        case .acPowerConnected:
            return onACPower
        }
    }
}
