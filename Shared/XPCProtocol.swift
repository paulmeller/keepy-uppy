import Foundation

/// Mach service name shared by helper, app, and CLI.
let helperMachServiceName = "au.com.workwireless.keepy-uppy.helper"

/// The session-oriented XPC surface (v2 Task 10): the protocol the agent,
/// CLI, and UI are all written against.
///
/// Sessions cross the boundary as JSON-encoded `Data` rather than as
/// `NSSecureCoding` objects: whitelisting a Swift enum with associated
/// values for `NSSecureCoding` is far more ceremony than encoding a
/// `Codable` struct, and `Session` round-trips through `JSONEncoder` /
/// `JSONDecoder` cleanly, associated values included.
@objc protocol HelperProtocol {
    /// `sessionJSON` is a JSON-encoded `Session` describing the session to
    /// start. The daemon sets `id`, `owner`, and `startedAt` itself from the
    /// caller's authenticated identity and its own clock — never trusting
    /// those fields from the client — so `kind`, `persistence`, and `origin`
    /// are the only fields the payload actually controls. Replies with the
    /// started session's id, or an error.
    func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void)

    /// Ends a single session. Rejected unless the caller owns it (Task 10
    /// isolation fix: `DaemonRuntime.stopSession` used to accept a bare
    /// UUID and end any session regardless of owner). The rejection is
    /// logged and the session is left untouched.
    func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)

    /// Ends sessions. Defaults to ending only the caller's own; pass
    /// `all: true` to end every client's sessions, matching the CLI's
    /// documented `off [--all | --session ID]` surface. (Task 10 isolation
    /// fix: this used to unconditionally end every client's sessions,
    /// including a `detached` session someone else started.)
    func stopAllSessions(all: Bool, reply: @escaping (Bool, String?) -> Void)

    /// Replies with a JSON-encoded `[Session]` — every session daemon-wide,
    /// regardless of owner. This is intentional, not a fourth isolation gap:
    /// the UI must be able to show *why* the Mac is awake regardless of
    /// which client started it (spec §9).
    func listSessions(reply: @escaping (Data?, String?) -> Void)

    /// Renews a lease session's expiry. Ownership-checked the same way as
    /// `stopSession`.
    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void)

    /// Agent-only (spec §4): the daemon derives the caller's role from the
    /// peer's code-signing identity and rejects this from anything else,
    /// logging the rejection.
    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)
    /// Agent-only. Registers this connection as the user-session observer, so
    /// its disappearance ends sessions whose evidence it was providing.
    func registerAsAgent(reply: @escaping (Bool, String?) -> Void)

    func currentState(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)
}

// MARK: - Cross-client isolation (Task 10)

/// Pure isolation logic for session-mutating XPC calls. Kept separate from
/// `HelperService`'s XPC callbacks and from `DaemonRuntime`'s dispatch queue
/// specifically so cross-client isolation is unit-testable directly, with no
/// XPC connection and no running daemon required — spec §4: "every client is
/// equally entitled to start and stop **its own** sessions."
enum SessionIsolation {
    /// The result of checking whether a caller may act on a specific
    /// session. `notFound` is distinguished from `forbidden` so the two can
    /// be reported (and logged) differently: one is a routine "already
    /// gone", the other is a rejected cross-client access attempt worth an
    /// error-level log entry.
    enum Authorization: Equatable {
        case authorized
        case notFound
        case forbidden
    }

    /// A caller may act on (stop, renew) a session only if they own it.
    static func authorize(sessionID: UUID, requestedBy caller: ClientID, among sessions: [Session]) -> Authorization {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return .notFound }
        return session.owner == caller ? .authorized : .forbidden
    }

    /// The ids `stopAllSessions` should end for a given caller: everyone's,
    /// if `all` is true — an explicit, logged escalation — otherwise only
    /// the caller's own, so `off` with no flags can never end a `detached`
    /// session someone else started.
    static func sessionsToStop(all: Bool, requestedBy caller: ClientID, among sessions: [Session]) -> [UUID] {
        if all {
            return sessions.map(\.id)
        }
        return sessions.filter { $0.owner == caller }.map(\.id)
    }
}
