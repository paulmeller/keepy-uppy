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
    ///
    /// Read `TriggerRule`'s own doc comment before designing that field. A
    /// field added the ordinary way is *dropped* by any older build that
    /// touches the file — decoded cleanly, ignored, and written back without
    /// it — so the rule silently reverts to whichever lifetime this table
    /// gives it, and the newer build then obeys the reverted rule. The store's
    /// skip-and-preserve machinery does not catch that, because nothing
    /// failed. Making the change undecodable to older builds is what routes it
    /// through the machinery that does.
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

/// One saved trigger.
///
/// **Adding a field here is a downgrade hazard, and it is the next thing
/// somebody is going to do.** `Codable` is synthesized for this type, and a
/// synthesized `init(from:)` *ignores* keys it does not recognise. So a rule
/// written by a newer build that carries an extra field decodes here cleanly:
/// it is `.readable`, not `.unreadable`, it is not counted by
/// `unreadableCount`, the pane shows it, the agent fires it — and the next
/// `save()` re-encodes it from these four properties and writes it back
/// **without the field**. Same for a new key inside a known condition's
/// payload. Pinned by `testARuleWithAnUnknownFieldIsAcceptedAndLosesTheField`.
///
/// That is a worse failure than the one `StoredTriggerRule` was built to fix,
/// because it looks like success. Losing an unknown *condition* costs the rule
/// and says so; losing an unknown *field* changes what a rule means and says
/// nothing — and the newer build then reads the mutated rule back and obeys it.
///
/// It is not hypothetical: `TriggerConditionKind.bindsSessionLifetime` records
/// that Plan 7 ("for 4 hours" vs "while it holds", per rule) needs exactly such
/// a field. If it is added the way `Session.swift` adds its optional fields —
/// `decodeIfPresent(...) ?? default`, which is right *there* because those
/// fields are only ever written and read by one process pair — an older build
/// will silently rewrite every rule that uses it back to the default.
///
/// **Design the field so an older build fails to decode it.** That is the one
/// move that turns this into the failure this file already handles well: the
/// rule becomes `.unreadable`, is preserved verbatim, is hidden rather than
/// misinterpreted, and is counted in the pane's notice. Two ways to get it,
/// both cheap at design time and neither available afterwards:
/// carry the new meaning inside `condition` under a new wire name (an unknown
/// case already throws), or add the field as a *required* `decode(...)` and
/// accept that rules written by the new build are opaque to old ones — which
/// is the honest description of what they are.
///
/// Round-tripping unknown keys per rule — a `[String: JSONValue]` bag captured
/// in a hand-written `init(from:)` and re-emitted by `encode(to:)` — was
/// considered and rejected. It fixes the wrong half: the bytes would survive,
/// but the older build still cannot *honour* the field, so it goes on
/// displaying and firing the rule under the old meaning while the file says
/// otherwise. It also buys nothing for the builds that will actually meet Plan
/// 7's files — v1 is already shipped and has no such bag — and it costs this
/// type its synthesized `Codable`, replacing it with an encoder that must be
/// hand-updated for every future field, which is the same class of silent
/// omission. Making the change undecodable costs nothing and fails safe.
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
///
/// **It does not hold every JSON value, and the two gaps are measured, not
/// assumed.** This type used to be documented as total ("holds any JSON at
/// all"); it is not, and `init(from:)` below is `throws` precisely because it
/// isn't.
///
/// 1. **A number Foundation's parser accepts but `Double` cannot represent.**
///    `1e309`, `1e999`, `-1e999` and friends: `JSONDecoder` parses them
///    happily, `Int` overflows, `Double` refuses (the default
///    `nonConformingFloatDecodingStrategy` is `.throw`), and `String`, array
///    and object all decline — so the `dataCorruptedError` at the bottom of
///    `init(from:)` fires. `1e308` is fine; the boundary is
///    `Double.greatestFiniteMagnitude`. Adding a `.double(.infinity)` case
///    would not help: `JSONEncoder` refuses to *write* a non-finite double
///    (verified — it throws `EncodingError`), so such a value cannot be
///    round-tripped through Foundation's Swift JSON writer by any route.
///    `TriggerStore` documents what this costs.
/// 2. **An integer literal outside `Int64` but inside `Double`'s range.**
///    `9223372036854775808` decodes as `.double` and is written back as
///    `9.223372036854776e+18` — a different number, silently. That is exactly
///    the failure the `Int` case above exists to prevent, one range further
///    out, and closing it needs arbitrary-precision decimal handling that
///    nothing in this project has a use for. Named here so the `Int` case is
///    not read as a guarantee it does not give.
///
/// Deep nesting is *not* one of these gaps, despite looking like one.
/// `JSONDecoder` refuses a document nested deeper than 512 levels at the top
/// level — `codingPath` is empty and the message is "The given data was not
/// valid JSON" — so it never reaches this type at all, and it lands in
/// `TriggerStore.loadStored()`'s already-documented "not a rule store at all"
/// branch. Measured: total depth 512 decodes, 513 does not.
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
        // Not "not a value JSON can express" — JSON expresses `1e999` fine,
        // and saying otherwise sends whoever reads this message looking for a
        // malformed file instead of for the gap listed above.
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "JSON this type cannot model (see JSONValue's limits)")
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
/// There is no hand-written element loop here, and that is what makes the
/// skipping work. `loadStored()` asks `JSONDecoder` for `[StoredTriggerRule]`
/// and Foundation's synthesized `Array` decoder drives the unkeyed container;
/// this type only ever decodes *one* element, from a decoder handed to it.
/// Writing the loop by hand is the thing to avoid: it has to advance the
/// container past an element it just refused, and `UnkeyedDecodingContainer`
/// only advances on success, so the obvious
/// `while !container.isAtEnd { if let rule = try? container.decode(...) }`
/// spins forever on the first bad element.
///
/// **`init(from:)` is not total, and the safety of the loop does not come from
/// pretending it is.** It `throws`, and `try JSONValue(from: decoder)` really
/// does throw — for the one value listed under `JSONValue`'s limits. What
/// Foundation's array decoder does with that throw is propagate it, which fails
/// the *whole* decode: one element holding `1e999` therefore still costs the
/// entire file, exactly as an unknown condition used to. This doc previously
/// claimed decoding could not throw, which made that hole invisible; the cost
/// is now stated on `TriggerStore.storedPayloadIsUndecodable`, which is also
/// where the case stops being silent.
enum StoredTriggerRule: Codable, Equatable {
    case readable(TriggerRule)
    /// Written by another build, and kept exactly as it arrived.
    ///
    /// Only an element whose decode *fails* lands here — not "any field this
    /// build cannot decode", which is what this said and which is materially
    /// wrong in the direction that matters. A rule carrying an extra field
    /// this build has never heard of decodes **cleanly** as `.readable`:
    /// `Codable`'s synthesized `init(from:)` ignores unknown keys, so the rule
    /// is not counted as unreadable, is shown and acted on normally, and the
    /// unknown field is dropped by the next `save()`. Same for a new key inside
    /// a known condition's payload. See `TriggerRule` for why that is the
    /// hazard Plan 7 has to design around rather than a curiosity.
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
    /// `[]` here means "no rules to show", and it means it for two different
    /// reasons — see `storedPayloadIsUndecodable` for the one where it is not
    /// the whole truth.
    static func loadStored() -> [StoredTriggerRule] { decodeStored().elements }

    /// Whether there is a payload on disk that this build could not decode at
    /// all — which `loadStored()` cannot tell you, because it answers `[]` for
    /// that and for "nothing was ever stored" alike.
    ///
    /// For one of those two, `[]` is a lie with consequences: the pane shows no
    /// triggers, the user edits something, and `save()` writes the empty list
    /// over a file that still held all of their rules. That is the destruction
    /// `StoredTriggerRule` exists to prevent, reappearing through the one gap
    /// element-wise skipping does not cover — a `JSONValue` that will not
    /// decode fails the whole array, not just its element (see
    /// `StoredTriggerRule`, and `JSONValue`'s limits for the only value that
    /// does it).
    ///
    /// Reachability is low and worth stating so nobody over-reads this:
    /// `JSONEncoder` refuses to write a non-finite double, so no Keepy Uppy
    /// build can produce such a file. A hand-edited plist or a non-Swift writer
    /// can. The remaining exposure is therefore small, but silent, and silent
    /// is the part this fixes: `save()` logs before it overwrites, and this
    /// property is the hook for a Triggers-pane notice. The pane does not read
    /// it yet — that notice says "lost", not "kept", so it is different copy
    /// from `unreadableTriggerNotice` and a UI decision rather than a
    /// mechanical one.
    static var storedPayloadIsUndecodable: Bool { decodeStored().undecodable }

    /// The stored array, plus the fact `loadStored()`'s return type cannot
    /// carry. One decode serves both, so `save()` does not pay for it twice.
    ///
    /// The outer failure still returns `[]`, and that is a different judgement,
    /// not an oversight: an element that will not decode is somebody's rule from
    /// another build, whereas a payload that is not an array of *anything* is
    /// not a rule store at all, and there is nothing in it worth carrying
    /// forward. `undecodable` does not distinguish those two — a truly corrupt
    /// payload and an array with one unmodellable number both set it — because
    /// nothing downstream would do anything different with the distinction.
    private static func decodeStored() -> (elements: [StoredTriggerRule], undecodable: Bool) {
        guard let data = defaults.data(forKey: key) else { return ([], false) }
        guard let stored = try? JSONDecoder().decode([StoredTriggerRule].self, from: data)
        else { return ([], true) }
        return (stored, false)
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
        let stored = decodeStored()
        let preserved = stored.elements.filter { $0.rule == nil }
        guard let data = try? JSONEncoder().encode(rules.map(StoredTriggerRule.readable) + preserved)
        else { return }
        if !preserved.isEmpty {
            triggerLogger.notice(
                "kept \(preserved.count, privacy: .public) trigger rule(s) this build cannot decode")
        }
        // The one loss element-wise skipping cannot prevent, said out loud at
        // the instant it becomes permanent. Bounded for the same reason the
        // line above is: only the Settings UI ever reaches `save()`, whereas
        // `load()` runs every 5s forever and is deliberately silent.
        if stored.undecodable {
            triggerLogger.error(
                "overwriting a stored trigger payload this build could not decode at all; any rules it held are being lost now, not merely hidden")
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
