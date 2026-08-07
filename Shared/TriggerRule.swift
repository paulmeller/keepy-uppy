import Foundation

enum TriggerCondition: Codable, Equatable {
    case appLaunched(bundleID: String)
    case externalDisplayConnected
    case acPowerConnected
}

struct TriggerRule: Codable, Equatable, Identifiable {
    let id: UUID
    var condition: TriggerCondition
    /// The *relative* intent ("for one hour"), never an absolute deadline.
    /// A rule outlives the moment it was written by days or weeks; the only
    /// correct time to turn "for one hour" into a real `SessionKind` is the
    /// instant the rule actually fires, which is why this is a
    /// `DefaultSessionKind` and not a `SessionKind`. Storing an absolute
    /// `SessionKind` here (as this field originally did) meant a rule
    /// created on Monday and fired on Friday handed the daemon a deadline
    /// four days in the past: `SessionEngine.apply` calls `removeExpired`
    /// at the end of every event, so the session was deleted by the same
    /// call that admitted it, the daemon still replied `.started`, and
    /// because no live session carried the rule's `triggerID`,
    /// `triggersToFire` below never de-duped it — the agent refired the
    /// identical rule every 5s forever, each time a real XPC round-trip and
    /// a privileged power-assertion write. Materialize with
    /// `defaultKind.sessionKind(now:)` at fire time (agent) or display time
    /// (Settings UI).
    var defaultKind: DefaultSessionKind
    var enabled: Bool
}

/// Off by default (spec §8): an app that starts keeping the Mac awake
/// unasked is a bug, not a feature. Shared with the future UI (plan 3),
/// which is the only thing that will ever populate this beyond the
/// empty default.
///
/// Stored in `PreferencesSuite` — the one shared suite, also used by
/// `SafetyConfigStore` and the UI's `@AppStorage` call sites. That constant
/// is where the `.standard` fallback and the reason it is required are
/// documented; the suite name was hardcoded separately here until the final
/// whole-branch review (Item 5) consolidated it.
enum TriggerStore {
    private static let key = "triggerRules"

    private static var defaults: UserDefaults { PreferencesSuite.defaults }

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
