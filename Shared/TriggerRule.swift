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
enum TriggerStore {
    private static let suiteName = "au.com.workwireless.keepy-uppy"
    private static let key = "triggerRules"

    static func load() -> [TriggerRule] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([TriggerRule].self, from: data)
        else { return [] }
        return rules
    }

    static func save(_ rules: [TriggerRule]) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(rules)
        else { return }
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
