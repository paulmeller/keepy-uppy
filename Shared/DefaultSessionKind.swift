import Foundation

/// The small, fixed set of quick-start choices shown in the menu,
/// configurable as a default in Settings' General tab, and stored as a
/// trigger rule's *intent*. Deliberately not arbitrary custom durations or
/// `--while-app` (the CLI already covers those, per spec §9's CLI/UI split)
/// — the menu is meant to cover the common case with one or two clicks, not
/// replicate every CLI flag.
///
/// This lives in `Shared/` rather than next to the rest of the app's
/// session-display helpers (`Sources/SessionDisplay.swift`) for two
/// reasons: `TriggerRule` (also `Shared/`, so it compiles into the app,
/// daemon, CLI and agent alike) stores one, and the agent materializes one
/// at trigger-fire time. It is a plain enum with no framework dependency
/// beyond Foundation, so it costs the daemon and CLI nothing — unlike
/// `Sources/SessionDisplay.swift`'s formatting helpers, which need AppKit
/// (`NSWorkspace`) and must therefore stay out of `Shared/`.
///
/// The relative→absolute conversion is a *method taking `now`*, never a
/// stored `Date`: a trigger rule persists the relative intent (".oneHour")
/// and computes the absolute deadline only at the instant it fires.
/// Freezing the deadline at rule-creation time instead would hand the
/// daemon an already-expired `SessionKind` whenever the rule fires more
/// than an hour after it was created, which the daemon's expiry sweep
/// deletes in the same call that admits it — leaving nothing for
/// `triggersToFire`'s live-session de-dup to match on, so the agent would
/// refire the same rule every tick, forever.
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
