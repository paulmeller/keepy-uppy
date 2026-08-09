import Foundation

enum TriggerCondition: Codable, Equatable {
    case appLaunched(bundleID: String)
    case externalDisplayConnected
    case acPowerConnected
    /// Matches a plain executable name (see `ProcessRunningObserving`), for
    /// CLI tools with no bundle ID — coding-assistant CLIs like `claude` or
    /// `codex` are the motivating case. The one condition that currently binds
    /// its session's lifetime (`TriggerConditionKind.bindsSessionLifetime`).
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

/// The *kind* of a `TriggerCondition`, without its associated value.
///
/// It exists so that one list drives everything: the Add sheet's picker, the
/// copy tests, and the lifetime-binding rule below. `TriggerCondition` cannot be
/// `CaseIterable` (its cases carry values) and the Settings UI therefore grew a
/// hand-maintained parallel enum, which is a condition-nobody-can-create waiting
/// to happen — the same shape as the `WakeMode` reachability hole Plan 4 closed.
///
/// The two enums are welded together in both directions, by the compiler rather
/// than by a test: a new `TriggerCondition` case makes `TriggerCondition.kind`
/// below non-exhaustive, and a new `TriggerConditionKind` case makes
/// `sampleCondition` non-exhaustive. Neither can be added alone.
///
/// `sampleCondition` is a representative value of each kind — the bridge from
/// "every kind there is" to "a condition to try it with", which is what lets
/// every surface be checked over `allCases` instead of over a hand-written list
/// that a fifth condition would silently not appear in. It is deliberately
/// *not* used to build the rule the Add sheet saves: that comes from what the
/// user actually typed.
enum TriggerConditionKind: String, CaseIterable, Identifiable {
    case appLaunched, externalDisplayConnected, acPowerConnected, processRunning

    var id: String { rawValue }

    /// Whether a session started by this condition ends when the condition
    /// does, rather than after `TriggerRule.defaultKind`'s duration.
    ///
    /// **Three of the four answer `false`, and that is a decision about
    /// existing users, not an oversight.** `.externalDisplayConnected` and
    /// `.acPowerConnected` both *have* a lifetime `SessionKind`
    /// (`.whileExternalDisplay`, `.whileOnACPower`) and deliberately do not
    /// bind to it: rules people have already saved mean "start a 4-hour session
    /// when the display connects", and quietly turning those into "…and end it
    /// when I unplug" would change behaviour under them. `.processRunning`
    /// binds because a duration was never meaningful for it.
    ///
    /// It is an exhaustive `switch` and not `self == .processRunning` for the
    /// reason `ObserverSet` gives no member a default: a new condition must
    /// *state* its answer, and the six Plan 5 is about to add are exactly the
    /// ones where "while I'm on this Wi-Fi network" is a plausible reading. A
    /// one-line expression would hand each of them `false` without their author
    /// ever meeting the question, which is the silent-default trap this project
    /// has been bitten by four times. One line per condition, and the choice is
    /// argued in the task that adds it.
    ///
    /// Offering *both* per rule ("for 4 hours" vs "while it holds") is a real
    /// improvement and is a Plan 7 UI decision — it needs a new stored field on
    /// `TriggerRule`, which is exactly the defaulted-field trap above. Do not
    /// smuggle it in here.
    var bindsSessionLifetime: Bool {
        switch self {
        case .appLaunched, .externalDisplayConnected, .acPowerConnected: return false
        case .processRunning: return true
        }
    }

    /// A representative condition of this kind. Associated values are stand-ins
    /// chosen to be recognisable in a failure message, never matched against
    /// anything live.
    var sampleCondition: TriggerCondition {
        switch self {
        case .appLaunched: return .appLaunched(bundleID: "com.apple.dt.Xcode")
        case .externalDisplayConnected: return .externalDisplayConnected
        case .acPowerConnected: return .acPowerConnected
        case .processRunning: return .processRunning(processName: "claude")
        }
    }
}

extension TriggerCondition {
    /// This condition's kind, dropping its associated value.
    var kind: TriggerConditionKind {
        switch self {
        case .appLaunched: return .appLaunched
        case .externalDisplayConnected: return .externalDisplayConnected
        case .acPowerConnected: return .acPowerConnected
        case .processRunning: return .processRunning
        }
    }

    /// The `SessionKind` this condition binds its session's lifetime to, or
    /// `nil` when the session it starts is governed by `TriggerRule.defaultKind`
    /// instead.
    ///
    /// Non-nil for exactly the kinds `bindsSessionLifetime` names — the two are
    /// separate statements because only this one can see the associated value a
    /// bound `SessionKind` needs, and `TriggerRuleTests` pins them against each
    /// other over `allCases`. This is the single place the carve-out lives;
    /// `sessionKind(firing:now:)`, `triggerEffectSubtitle` and the Add sheet all
    /// read it rather than re-matching `.processRunning`, which is what they
    /// each used to do.
    var boundSessionKind: SessionKind? {
        switch self {
        case .appLaunched, .externalDisplayConnected, .acPowerConnected:
            return nil
        case .processRunning(let processName):
            return .whileProcessRunning(processName: processName)
        }
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

/// The `SessionKind` a firing rule actually starts: whatever the condition
/// binds its session's lifetime to, and otherwise `defaultKind` materialized
/// at this instant.
///
/// A condition that binds ignores `defaultKind` entirely. It is still stored on
/// the rule (the Settings UI needs somewhere to persist it, and the schema
/// didn't need to change), but for `.processRunning` — the only binding
/// condition today — ending the session when the process exits, not after some
/// picked duration, is the entire reason to use a process trigger over a plain
/// `--for`. The Add sheet hides the duration picker for exactly these
/// conditions rather than showing one it would discard.
///
/// This used to match `.processRunning` here, and again in two places in
/// `Sources/SessionDisplay.swift`, and a fourth time in the Add sheet. All four
/// now read `TriggerCondition.boundSessionKind`, so a fifth condition that
/// binds is described correctly everywhere by adding one line to one table.
func sessionKind(firing rule: TriggerRule, now: Date) -> SessionKind {
    rule.condition.boundSessionKind ?? rule.defaultKind.sessionKind(now: now)
}
