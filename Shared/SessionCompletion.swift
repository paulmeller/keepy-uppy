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
