import Foundation
import os

/// `Shared/` compiles into all four targets and so cannot reach the daemon's
/// `helperLogger`, exactly as `powerLogger` explains. One line, on the one path
/// that rewrites a file holding rules this build cannot read.
let triggerLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "triggers")

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

/// Just enough of JSON's data model to hold a value verbatim and hand it back
/// unchanged.
///
/// It exists for one job: letting `TriggerStore` keep a rule that some *other*
/// build wrote and this one cannot decode. Nothing here interprets the value —
/// the point is precisely that this build has no idea what it means.
///
/// The `Int` case is not decoration. Holding every number as a `Double` writes
/// an identifier past 2^53 back as a *different* identifier, and leaves whole
/// numbers at the mercy of whatever the encoder does with `5.0`. A preservation
/// that quietly alters what it preserved is a slower version of the loss this
/// whole file is about.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Bool before Int, Int before Double. `JSONDecoder` is strict enough to
        // refuse `true` as an `Int` and `1` as a `Bool` on its own, but the
        // order says which reading wins rather than leaving it to that.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "not a value JSON can express")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One element of the stored trigger array: a rule this build understands, or
/// the untouched JSON of one it does not.
///
/// This type is the fix. `load()` used to decode `[TriggerRule]` inside a single
/// `try?`, so one element with a `condition` this build had never heard of threw
/// — and the `guard` turned that into `[]`, i.e. "you have no triggers". The
/// file was still on disk and still complete at that point; what made the loss
/// permanent was the next `save()`, which wrote the empty list over it. Plan 5
/// adds six conditions, so the version of this that matters is not exotic: run
/// the new build, then run an older one for any reason, and every rule you have
/// disappears from the pane at once.
///
/// Decoding cannot throw here, and that is deliberate — `init(from:)` falls back
/// to `JSONValue`, which holds any JSON at all. An element-wise loop that lets a
/// failure escape has to advance the unkeyed container past the element it just
/// refused, and `UnkeyedDecodingContainer` only advances on success: the obvious
/// `while !container.isAtEnd { if let rule = try? container.decode(...) }` spins
/// forever on the first bad element. A wrapper that always succeeds is how the
/// container keeps moving.
enum StoredTriggerRule: Codable, Equatable {
    case readable(TriggerRule)
    /// Written by another build, and kept exactly as it arrived. Not
    /// necessarily an unknown *condition* — any field this build cannot decode
    /// lands here, which is the right rule: the store's job is to preserve what
    /// it cannot use, not to guess why it cannot use it.
    case unreadable(JSONValue)

    var rule: TriggerRule? {
        switch self {
        case .readable(let rule): return rule
        case .unreadable: return nil
        }
    }

    init(from decoder: Decoder) throws {
        if let rule = try? TriggerRule(from: decoder) {
            self = .readable(rule)
            return
        }
        self = .unreadable(try JSONValue(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .readable(let rule): try rule.encode(to: encoder)
        case .unreadable(let json): try json.encode(to: encoder)
        }
    }
}

extension Array where Element == StoredTriggerRule {
    /// How many stored rules this build could not decode. The number the
    /// Triggers pane needs in order to say so out loud — a rule that is
    /// invisible and inert is a far milder failure than one that is deleted,
    /// but it is not one the user should have to discover for themselves.
    var unreadableCount: Int { lazy.filter { $0.rule == nil }.count }
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
    /// Internal rather than private so `TriggerRuleTests` can plant a payload
    /// under the exact key the store reads. A second copy of the literal in the
    /// tests could drift from this one, and a test that writes somewhere the
    /// store never looks proves nothing.
    static let key = "triggerRules"

    private static var defaults: UserDefaults { PreferencesSuite.defaults }

    /// The rules this build can act on. Anything else on disk is still on disk;
    /// it is simply not something this build can evaluate or display.
    ///
    /// Deliberately silent about what it skipped: `EvidenceLoopRunner` calls
    /// this every 5s tick, so a log line here would be a log line every 5s
    /// forever. `loadStored()` is where a caller that wants to *tell* somebody
    /// looks, and `save()` is where the one bounded log line lives.
    static func load() -> [TriggerRule] { loadStored().compactMap(\.rule) }

    /// The stored array as it actually is, element by element.
    ///
    /// The outer `try?` still returns `[]`, and that is a different judgement,
    /// not an oversight: an element that will not decode is somebody's rule from
    /// another build, whereas a payload that is not an array of *anything* is
    /// not a rule store at all, and there is nothing in it worth carrying
    /// forward.
    static func loadStored() -> [StoredTriggerRule] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([StoredTriggerRule].self, from: data)
        else { return [] }
        return stored
    }

    /// Writes `rules`, and re-emits every element this build could not read.
    ///
    /// The preserved elements are re-read from disk here rather than remembered
    /// from a previous `load()`, which is the whole design. A remembered set is
    /// state that a caller can fail to carry: a `save()` on a code path that
    /// never loaded, or that loaded before the other build wrote, would silently
    /// destroy the rules — the same shape as `Session`'s three defaulted fields,
    /// where the compiler is happy and the value quietly becomes somebody else's
    /// idea of harmless. Going and fetching them means no call site can omit
    /// them, because no call site passes them. `save(_:)` therefore keeps its
    /// `[TriggerRule]` signature and its two callers are unchanged.
    ///
    /// Preserved elements are appended after `rules`. Their original positions
    /// are not recoverable in any meaningful sense — the caller may have
    /// reordered, added to or deleted from the list it is handing back — and
    /// rule order carries no behaviour, only display order in the pane that
    /// cannot show these anyway.
    ///
    /// The read-then-write is not atomic. Only the Settings UI ever writes this
    /// key, from the main thread, so there is no second writer to race; the
    /// agent and daemon only ever read.
    static func save(_ rules: [TriggerRule]) {
        let preserved = loadStored().filter { $0.rule == nil }
        guard let data = try? JSONEncoder().encode(rules.map(StoredTriggerRule.readable) + preserved)
        else { return }
        if !preserved.isEmpty {
            triggerLogger.notice(
                "kept \(preserved.count, privacy: .public) trigger rule(s) this build cannot decode")
        }
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
