import Foundation

// MARK: - Mach services: one per client role
//
// `Helper/main.swift` stands up one dedicated `NSXPCListener` per service
// below, and each listener pins a code-signing requirement admitting exactly
// ONE bundle identifier (`Shared/SigningRequirement.swift`). So a peer's role
// is a property of *which service accepted it* — established atomically by
// the OS at accept time — not something derived after the fact from an
// inherently racy peer pid lookup (the TOCTOU issue the old
// `PeerIdentity.isAgent(_:)` had), and never something the client asserts
// about itself.
//
// This started as two services (a general one admitting any of the three
// client identifiers, plus an agent-only one). It is three now because
// `ClientID` is derived from the role as well (`Shared/ClientIdentity.swift`):
// one service per role is what makes that identity both stable and
// unforgeable. It is also *strictly tighter* than the two-service shape —
// every service now admits exactly one binary, where one of them used to
// admit three.

/// Mach service reserved for the menu-bar app only. Keeps its original,
/// unsuffixed name because it is the service name already baked into
/// registered launchd jobs and shipped app bundles; only its pinned
/// requirement narrowed, from "any of the three clients" to
/// `SigningRequirement.appRequirement` (the app's identifier alone).
let helperMachServiceName = "au.com.workwireless.keepy-uppy.helper"

/// Mach service reserved for the agent only; every connection accepted here
/// is the agent by construction (`SigningRequirement.agentRequirement`).
let agentMachServiceName = "au.com.workwireless.keepy-uppy.helper.agent"

/// Mach service reserved for the CLI only; every connection accepted here is
/// the `keepy-uppy` binary by construction
/// (`SigningRequirement.cliRequirement`).
let cliMachServiceName = "au.com.workwireless.keepy-uppy.helper.cli"

/// The launchd plist filenames embedded in the app bundle and named to
/// `SMAppService`. Centralised for the same reason the Mach service names
/// above are: they were bare literals in six places across the CLI and the
/// onboarding service, where a typo registers nothing and still reports
/// success.
let helperPlistName = "au.com.workwireless.keepy-uppy.helper.plist"
let agentPlistName = "au.com.workwireless.keepy-uppy.agent.plist"

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
    /// start. The daemon sets `id`, `owner`, `ownerUID`, and `startedAt`
    /// itself from the caller's authenticated identity and its own clock —
    /// never trusting those fields from the client — so `kind`,
    /// `persistence`, `origin`, `triggerID`, and `wakeMode` are the fields
    /// the payload actually controls. Replies with the started session's id,
    /// or an error. See `HelperService.startSession` for why each field is in
    /// the category it is in.
    ///
    /// `wakeMode` needed no change to this protocol, which is the point of
    /// sending a JSON `Session` rather than a fixed argument list: a new
    /// client-chosen field is a new key in a payload both ends already
    /// encode and decode, so a client and daemon of different vintages stay
    /// compatible in both directions (`Session.init(from:)` defaults an
    /// absent `wakeMode` to `.clamshell`, and an unrecognised extra key is
    /// ignored by `JSONDecoder`).
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
    /// Replies with how many sessions were actually ended (and an error
    /// string on failure). The count exists so a caller can distinguish
    /// "stopped three" from "matched nothing" — a bare success reply is
    /// what let a scoping mismatch masquerade as a working `off`.
    func stopAllSessions(all: Bool, reply: @escaping (Int, String?) -> Void)

    /// Replies with a JSON-encoded `[Session]` — every session daemon-wide,
    /// regardless of owner. This is intentional, not a fourth isolation gap:
    /// the UI must be able to show *why* the Mac is awake regardless of
    /// which client started it (spec §9).
    func listSessions(reply: @escaping (Data?, String?) -> Void)

    /// Renews a lease session's expiry. Ownership-checked the same way as
    /// `stopSession`.
    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void)

    /// Agent-only (spec §4): the daemon derives the caller's role
    /// structurally, from which Mach service (`helperMachServiceName` /
    /// `agentMachServiceName` / `cliMachServiceName`) the connection came in
    /// on, and rejects this from anything else, logging the rejection.
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
    ///
    /// The `all: false` scoping is only useful if "the caller" means the same
    /// thing across separate invocations. It did not: the daemon used to mint
    /// a fresh random `ClientID` per accepted connection, so every
    /// `keepy-uppy` process was a different owner than the one that started
    /// the session and `off` matched nothing while reporting success. See
    /// `ClientRole.clientID(forUserID:)` (Shared/ClientIdentity.swift) for the
    /// stable, server-derived identity that makes this filter meaningful.
    static func sessionsToStop(all: Bool, requestedBy caller: ClientID, among sessions: [Session]) -> [UUID] {
        if all {
            return sessions.map(\.id)
        }
        return sessions.filter { $0.owner == caller }.map(\.id)
    }
}
