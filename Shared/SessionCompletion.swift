import Foundation

/// Pure: which sessions present in `previous` are absent from `current`,
/// i.e. ended since the last poll. Doesn't distinguish *why* a session
/// ended (condition met, manual stop, safety guard, expiry, agent
/// restart) — the daemon has no push mechanism, so this is what "session
/// ended" reduces to for a client that only ever sees `listSessions()`
/// snapshots (`Agent/EvidenceLoopRunner.swift`'s tick).
func sessionsEndedSince(previous: [Session], current: [Session]) -> [Session] {
    let currentIDs = Set(current.map(\.id))
    return previous.filter { !currentIDs.contains($0.id) }
}

/// Pure: which sessions present in `current` were absent from `previous`,
/// i.e. started since the last poll. The three-line inverse of
/// `sessionsEndedSince`, and it lives **beside it** rather than in the one
/// file that needs it (`Sources/SessionNotifications.swift`, the app's
/// notification tracker) for a reason worth stating: two set-difference
/// implementations in two files is exactly how the two directions come to
/// disagree. One keyed on `id` and the other on whole-value equality would
/// make a renewed lease — same id, new deadline, rebuilt by
/// `Session.renewed(until:)` — look like a session ending and another
/// starting in the same tick.
///
/// Like its twin it says nothing about *why* a session appeared. The caller
/// decides which appearances mean anything; `Session.origin` and
/// `Session.owner` are what it decides with, and only the second of those is
/// server-stamped (see `Session.authorized(id:owner:ownerUID:startedAt:)`).
func sessionsStartedSince(previous: [Session], current: [Session]) -> [Session] {
    let previousIDs = Set(previous.map(\.id))
    return current.filter { !previousIDs.contains($0.id) }
}

/// The snapshot bookkeeping behind "which of *my* sessions ended since the
/// last poll", lifted out of `Agent/EvidenceLoopRunner.tick` so that it is
/// (a) testable and (b) a single mutating call, which is the point.
///
/// Two security-review defects live here, and both are about *ordering*:
///
/// 1. **Re-entrancy.** `tick()` is `async` and the 5s timer used to spawn an
///    unguarded `Task` for it, while `DaemonConnection.callTimeout` is also
///    5s — so one hung XPC call makes a tick outlive its own period. With
///    the read-diff-write spread across `tick`'s local state and `await`s in
///    between, a stalled tick wrote its *stale* snapshot over a newer one,
///    and the next tick then re-diffed an already-reported session as newly
///    ended and re-ran the user's script. Reproduced by the reviewer, twice
///    for one session. `EvidenceLoopRunner` now holds a non-reentrancy guard
///    so a slow tick degrades to "skipped this tick"; folding read, diff and
///    write-back into `recordAndReportEnded` below removes the interleaving
///    window that made the guard's absence exploitable in the first place,
///    so neither fix silently depends on the other.
/// 2. **Cross-user firing.** `HelperService.listSessions` returns the whole
///    session table unfiltered by uid, deliberately — the menu bar must be
///    able to say why the Mac is awake even when the reason is another
///    logged-in user. But there is one agent *per user*, each reading its
///    own `UserDefaults`, so diffing that unfiltered list meant user A's
///    agent ran A's script and POSTed to A's webhook when **B's** session
///    ended, carrying B's `kind` — i.e. B's app bundle ID or process name.
///    Filtering happens here, on the way in, so the retained snapshot is
///    already scoped: no later code path can reintroduce another user's
///    sessions by forgetting a filter.
struct SessionCompletionTracker {
    /// The uid this tracker is allowed to speak for — the agent's own
    /// (`getuid()`). Matched against `Session.ownerUID`, which the daemon
    /// stamps server-side from the authenticated XPC peer and never accepts
    /// from a client (see `HelperService.startSession`), so it is not
    /// something a caller can spoof to borrow another user's actions.
    let ownerUID: UInt32

    private var previous: [Session]?

    init(ownerUID: UInt32) { self.ownerUID = ownerUID }

    /// Whether a baseline exists to diff against. Only the tests care.
    var hasSnapshot: Bool { previous != nil }

    /// Drops the baseline, so the next call reports nothing and merely
    /// re-primes.
    ///
    /// Called when the XPC connection breaks, for the same reason the very
    /// first tick reports nothing: after a daemon restart every previously
    /// known session is absent from the new (empty) table at once, which
    /// would diff as "all of them just ended" and spawn N scripts and N
    /// POSTs in one tick, unbounded. A session that genuinely ends during
    /// the outage is missed — that is the deliberate trade, and it is the
    /// same one already made at startup: firing a user's script for
    /// something that did not just happen is worse than not firing it.
    mutating func forgetSnapshot() { previous = nil }

    /// Folds one `listSessions` snapshot in and reports which of this uid's
    /// sessions disappeared since the previous one.
    ///
    /// Deliberately one call rather than a getter plus a setter: read, diff
    /// and write-back cannot be separated by an `await` if the caller has no
    /// way to separate them.
    mutating func recordAndReportEnded(current: [Session]) -> [Session] {
        let mine = current.filter { $0.ownerUID == ownerUID }
        defer { previous = mine }
        guard let previous else { return [] }
        return sessionsEndedSince(previous: previous, current: mine)
    }
}

/// What to do when a session ends. Both fields are optional and independent
/// — a user may want only a script, only a webhook, or both.
struct SessionCompletionConfig: Codable, Equatable {
    var scriptPath: String?
    var webhookURL: String?
}

/// Mirrors `TriggerStore`'s load/save pattern exactly (same shared
/// `UserDefaults` suite, same JSON-blob-under-one-key shape) — see that
/// type's comment for why the suite is named once in `PreferencesSuite`
/// rather than hardcoded here.
///
/// Deliberately readable by every process that shares the suite, not just
/// the Agent: `keepy-uppy finished` (CLI/main.swift) reads this directly,
/// with no daemon or XPC involved, so that a coding-assistant CLI's own
/// completion hook can fire the configured action immediately, at real
/// task-completion precision, without waiting for the Agent's 5s poll.
enum SessionCompletionStore {
    private static let key = "sessionCompletionConfig"

    private static var defaults: UserDefaults { PreferencesSuite.defaults }

    static func load() -> SessionCompletionConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(SessionCompletionConfig.self, from: data)
        else { return SessionCompletionConfig() }
        return config
    }

    static func save(_ config: SessionCompletionConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}

/// What actually ended, passed to the (impure, per-target) notifier.
/// `tool`/`sessionID`/`kind` are all optional because `keepy-uppy finished`
/// can fire this with no associated Keepy Uppy session at all — a coding
/// tool's own completion hook fires whether or not a keep-awake session was
/// ever running for it.
struct SessionCompletionEvent {
    var tool: String?
    var sessionID: String?
    var kind: String?
    var endedAt: Date
}
