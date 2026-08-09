import Foundation

enum TriggerCondition: Codable, Equatable {
    case appLaunched(bundleID: String)
    case externalDisplayConnected
    case acPowerConnected
    /// Matches a plain executable name (see `ProcessRunningObserving`), for
    /// CLI tools with no bundle ID — coding-assistant CLIs like `claude` or
    /// `codex` are the motivating case. The one condition
    /// `sessionKind(firing:now:)` below treats specially.
    case processRunning(processName: String)

    /// Why a `.processRunning` name can never match anything, or `nil` if it
    /// can. Lives here rather than inside the Add-trigger sheet so it is
    /// testable and so the rule has one statement.
    ///
    /// Note what is deliberately *not* here: a length limit. `p_comm` is a
    /// `MAXCOMLEN` array and truncates at 16 characters, so while the
    /// observer matched only `p_comm` a longer name silently could not match.
    /// It now also matches the executable path and `argv[0]`, neither of
    /// which is truncated — verified empirically against a 31-character
    /// binary name, which matches in full. Adding a limit that no longer
    /// exists would be worse than having none.
    static func processNameProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Spaces around the name are part of it, and will stop it matching."
        }
        if name.contains("/") {
            return "Enter just the name the tool runs as (\"claude\"), not a path — a path can never match."
        }
        return nil
    }
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

/// Pure: which enabled rules have a **confidently** true condition right now,
/// excluding any rule already represented by a live session (so a still-true
/// condition doesn't refire every tick — the daemon's admission path
/// would reject duplicates anyway via suppression/caps, but there is no
/// reason to hammer it).
///
/// The mirror image of `sessionsToEnd`'s rule: that one ends a session only
/// on `ConditionReading.absent`, this one starts a session only on
/// `.present`. `.undetermined` does neither. Starting a session on a reading
/// that failed is the milder of the two mistakes — it wastes power rather
/// than sleeping a Mac mid-build — but it is still a mistake, and a trigger
/// that fires because an observer broke is a trigger nobody can reason about.
///
/// `ObserverSet.acPower` is a reading rather than a `Bool` for the same reason:
/// `PowerControl.batteryState()` has a `.unknown` source for when IOKit
/// declines to answer, and collapsing that into "not on AC power" is exactly
/// the bug this contract exists to remove.
func triggersToFire(
    _ rules: [TriggerRule],
    activeSessions: [Session],
    observers: ObserverSet
) -> [TriggerRule] {
    let activeTriggerIDs = Set(activeSessions.compactMap(\.triggerID))
    return rules.filter { rule in
        guard rule.enabled, !activeTriggerIDs.contains(rule.id) else { return false }
        switch rule.condition {
        case .appLaunched(let bundleID):
            return observers.appRunning.isRunning(bundleID: bundleID).isConfidentlyPresent
        case .externalDisplayConnected:
            return observers.display.hasExternalDisplay().isConfidentlyPresent
        case .acPowerConnected:
            return observers.acPower.isConfidentlyPresent
        case .processRunning(let processName):
            return observers.processRunning.isRunning(processName: processName).isConfidentlyPresent
        }
    }
}

/// The `SessionKind` a firing rule actually starts. For every condition
/// except `.processRunning` this is exactly `rule.defaultKind.sessionKind(now:)`
/// — unchanged from before this function existed. `.processRunning` is the
/// one deliberate exception: `defaultKind` is stored on the rule (so the
/// Settings UI has somewhere to persist it, and so the schema didn't need to
/// change) but ignored here, because ending the session when the process
/// exits — not after some picked duration — is the entire reason to use a
/// process trigger over a plain `--for`. See `Sources/SessionDisplay.swift`'s
/// `triggerConditionTitle`/`triggerEffectSubtitle` for the matching UI-copy
/// exception, and `Tests/TriggerRuleTests.swift` for the regression coverage
/// pinning that the other three conditions are unaffected by this carve-out.
func sessionKind(firing rule: TriggerRule, now: Date) -> SessionKind {
    if case .processRunning(let processName) = rule.condition {
        return .whileProcessRunning(processName: processName)
    }
    return rule.defaultKind.sessionKind(now: now)
}
