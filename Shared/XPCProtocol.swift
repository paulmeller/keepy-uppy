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
    ///
    /// **One exception since Plan 8 Task 5**, and the only place on this
    /// protocol where a client may act on a session it does not own: the
    /// menu-bar app may stop a session started by *this same user's* own
    /// trigger rules. The five-clause conjunction, the argument for it, and the
    /// five things it deliberately does **not** widen — no other user, caller,
    /// owner, verb or sweep — are all in `SessionIsolation.authorize`.
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

    /// Ends every session daemon-wide **and** forces the sleep setting back
    /// off, as the last thing this daemon is asked to do before a client
    /// unregisters it (`keepy-uppy reset`). Replies with how many sessions were
    /// ended, and whether this Mac can sleep again.
    ///
    /// It exists because unregistering evicts the only process that can clear
    /// `SleepDisabled`, and that setting outlives both the process and the next
    /// reboot — see `DaemonRemoval` for the ordering rule this reply feeds, and
    /// for why a caller must not unregister when the second value is `false`.
    ///
    /// Deliberately not owner-scoped, and not a fourth isolation gap. It is
    /// `stopAllSessions(all: true)` — already an explicit, logged escalation
    /// open to every admitted client — plus the one write that makes the
    /// escalation safe to follow with an eviction. Both act only in the
    /// *weakening* direction: the most a caller can achieve with this is to let
    /// this Mac sleep.
    func prepareForRemoval(reply: @escaping (Int, Bool) -> Void)

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

    /// The daemon's own version, written by `bundleVersionText` — short version
    /// and build number, the same way the app writes its own.
    ///
    /// **Declared in v2 and called by nobody until Plan 7 Task 10**, which is
    /// the mild version of the problem `SessionKind.Family` exists to prevent:
    /// a protocol verb with no caller is a promise nothing keeps. Its one caller
    /// is `DaemonConnection.version()`, behind the CLI & Advanced tab's
    /// Diagnostics section.
    ///
    /// It is read-only in the strongest sense available here — it takes no
    /// argument, touches no session, and cannot change what this Mac does.
    func version(reply: @escaping (String) -> Void)

    /// Replies with a JSON-encoded `[SafetyStopRecord]`: the sessions a safety
    /// guard has ended recently, daemon-wide, each with the reason it ended
    /// for. `Shared/SafetyStopLog.swift` owns the shape and both bounds.
    ///
    /// The same `(Data?, String?)` shape `listSessions` already uses, and for
    /// its reason: whitelisting a Swift enum with associated values for
    /// `NSSecureCoding` is far more ceremony than encoding a `Codable` struct,
    /// and — the part that matters more here — an additive field on
    /// `SafetyStopRecord` later stays cheap, because `JSONDecoder` ignores a key
    /// it does not declare in either direction.
    ///
    /// **Read-only in the strongest sense available here** — the same sentence
    /// `version(reply:)` earns, and this verb earns it for the same three
    /// reasons: it takes no argument, it touches no session, and it cannot
    /// change what this Mac does. It reports on sessions that are *already
    /// gone*, which is a stronger statement than `listSessions` can make.
    ///
    /// ## The privacy decision, made explicitly: the reply is **unfiltered**
    ///
    /// Exactly as `listSessions` is, and the client filters to its own uid
    /// (which is why `SafetyStopRecord` carries `ownerUID` at all). Three
    /// reasons, in weight order:
    ///
    /// 1. **The reason is a machine-wide fact, not a personal one.** Thermal
    ///    state and battery level are properties of the Mac, and `maxDuration`
    ///    keys off the age of the oldest session *anywhere* — so the reason
    ///    another account's session ended is, quite literally, the same fact as
    ///    the reason yours did. A safety stop is one `.stopAll`; there is one
    ///    reason per episode, not one per user.
    /// 2. **It publishes nothing about another user that is not already
    ///    published.** Every session on this Mac is already visible to every
    ///    admitted client through `listSessions`, by deliberate design (spec §9:
    ///    the UI must be able to show why the Mac is awake regardless of who
    ///    started it). A record names a session id and a uid that were readable
    ///    a moment ago, plus a machine-wide fact.
    /// 3. **Filtering here would be the daemon deciding what a menu bar may
    ///    say.** That policy belongs where the sentence is written, next to the
    ///    uid scoping every other claim in this app is already built on.
    ///
    /// The two verbs must not disagree about this question, so if this is ever
    /// filtered daemon-side, `listSessions`' comment above has to change in the
    /// same commit.
    ///
    /// ## Callers: never polled, and gated before the first send
    ///
    /// This is the first verb added to this protocol since the daemon-skew
    /// hazard was measured (`Tests/UnimplementedVerbProbeTests.swift`): sending
    /// a verb an older daemon does not implement **invalidates the connection
    /// server-side**, which in the real daemon runs
    /// `DaemonRuntime.clientDisconnected` and ends every `clientBound` session
    /// the caller owns. So this verb is sent only by
    /// `DaemonConnection.recentSafetyStops()`, only when the app has an ending
    /// it is about to explain, never on any timer, and only after
    /// `DaemonCapability` has cleared the daemon. See that type and that method.
    func recentSafetyStops(reply: @escaping (Data?, String?) -> Void)
}

// MARK: - How a version is written

/// **One formatter, so the daemon's reply and the app's own row cannot be
/// written differently** — which would render every healthy install as a
/// version mismatch, on the one pane a user opens because they already suspect
/// something is wrong.
///
/// It lives here rather than in `Sources/` because `Helper/` needs it too, and
/// beside `version(reply:)` because that is the wire it formats.
///
/// **The build number is in it, and that is the point.** All four targets in
/// `project.yml` ship `MARKETING_VERSION: "0.1.0"` and have since the first
/// commit, while `just bump` moves `CURRENT_PROJECT_VERSION` on every release —
/// so a version string built from the short version alone compares *equal* for
/// every pair of builds this project has ever produced, including the pair
/// Diagnostics exists to catch: an app updated in place, still talking to the
/// daemon the previous copy registered, until this Mac restarts.
func bundleVersionText(shortVersion: String?, build: String?) -> String {
    // "unknown" rather than an empty string: a blank where a version should be
    // reads as a rendering failure rather than as missing information, and an
    // empty string on one side of the comparison would report a mismatch that
    // isn't one.
    let short = (shortVersion?.isEmpty == false) ? shortVersion! : "unknown"
    guard let build, !build.isEmpty else { return short }
    return "\(short) (\(build))"
}

/// The two `Info.plist` keys, read off a bundle. Split from the formatter above
/// so the formatting is testable without a bundle carrying the values under
/// test — `Bundle` has no initialiser that takes an info dictionary.
func bundleVersionText(of bundle: Bundle) -> String {
    bundleVersionText(shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                      build: bundle.infoDictionary?["CFBundleVersion"] as? String)
}

// MARK: - Which verbs this daemon can be asked for

/// **Whether a daemon is new enough to be sent a verb that did not always
/// exist — decided before the verb is ever sent, from a verb that always did.**
///
/// ## Why this has to exist at all
///
/// Plan 8 Task 1 measured what a client observes when it sends a verb the
/// daemon does not implement (`Tests/UnimplementedVerbProbeTests.swift`, over a
/// fully isolated anonymous listener). It is not a per-message error: the
/// **server side of the connection is invalidated**, which in the real daemon
/// runs `HelperListenerDelegate`'s teardown → `DaemonRuntime.clientDisconnected`
/// → `SessionTable.removeAll(ownedBy:)`, ending every `clientBound` session that
/// identity owns. The client then heals silently on its next message, so
/// nothing stops it happening again. One ungated call costs a user their
/// sessions; a *polled* one costs them their sessions every poll, forever.
///
/// This is not hypothetical on this project. The daemon is a root LaunchDaemon
/// that keeps running across app updates — nothing short of the bundle path
/// vanishing or a reboot replaces it — so "old daemon, new client" is the
/// ordinary state after an in-place upgrade.
///
/// ## Why `version(reply:)` is the only usable probe
///
/// It is the one verb that has existed since v2 and is implemented by every
/// daemon this project has ever shipped, so asking it can never be the thing
/// that tears a connection down. Every other candidate probe would have to be
/// the very verb whose presence is in question.
///
/// ## Why its answer describes the daemon's own vintage — measured
///
/// `HelperService.version` replies `bundleVersionText(of: .main)`, and
/// `Bundle.main` for the helper resolves to the enclosing **`.app`**, not to the
/// helper binary (Task 1, Step 3b) — so on its face the reply looks like it
/// would report whatever version is on disk *now*, including a newer app that
/// replaced the one the running daemon came from. It does not, and the
/// difference was measured rather than assumed, with a throwaway tool inside a
/// synthetic bundle whose `Info.plist` was rewritten underneath it:
///
/// * a process that touches `Bundle.main` **before** the swap goes on reporting
///   the values from when it first touched it (`0.1.0 / 3` while the file on
///   disk read `9.9.9 / 999`);
/// * a process that touches it for the first time only **after** the swap
///   reports the new values.
///
/// The daemon is firmly in the first case: `Helper/main.swift`'s very first act
/// is `DaemonRuntime()`, whose `bundlePath` parameter defaults to
/// `Bundle.main.bundlePath`. So the info dictionary is snapshotted at daemon
/// start, and `version()` reports the vintage of the bundle the running daemon
/// was launched from.
///
/// **That is a real coupling and it is worth naming**: if `DaemonRuntime` ever
/// stopped evaluating `Bundle.main` during startup, this gate would silently
/// invert — an old daemon would begin reporting the *new* app's version, pass
/// the check, and be sent a verb it does not implement. Anything that moves
/// that call has to move a `Bundle.main` touch to daemon startup with it.
///
/// ## Why a build number, and why 4
///
/// `MARKETING_VERSION` is `0.1.0` on all four targets of every build this
/// project has ever produced, so the short version alone compares equal between
/// *any* two builds and cannot gate anything. `CURRENT_PROJECT_VERSION` is what
/// `just bump` moves, and Task 1's R1.4 requires the release introducing a new
/// verb to bump — which is why `project.yml` moves in the same commit as this
/// constant and as the verb itself. All three have to travel together or the
/// gate is a guess.
///
/// It is **4, not 3**, and the reason is a defect found while writing this: the
/// installed app on this machine reports `CFBundleVersion` **3** while tracked
/// `project.yml` said **2**, so a release's bump was never committed and `just
/// bump` (which takes its input from `project.yml`) would have re-minted 3 —
/// a number that has already shipped, on a daemon with none of this. Gating at
/// `>= 3` would therefore have cleared the very daemon serving this user right
/// now. 4 is strictly greater than every build number that has ever existed
/// here, so "reports at least 4" means "was built from this commit or later",
/// which is the only statement that actually implies the verb exists.
///
/// ## And why it is still not sufficient on its own
///
/// A build number orders releases; it does not identify source. Two local
/// builds made without a bump share a number, so on a developer's machine this
/// gate can clear a daemon that predates the verb. That is why it is the
/// *second* of `DaemonConnection.recentSafetyStops()`'s gates and not the only
/// one — the load-bearing one is structural, and is documented there.
enum DaemonCapability {
    /// The build number in which `HelperProtocol.recentSafetyStops(reply:)`
    /// first existed. Moves only when the verb does.
    static let recentSafetyStopsBuild = 4

    /// The build number out of a string written by `bundleVersionText`, or
    /// `nil` if there is not one — which is what a daemon predating Plan 7
    /// Task 10 replies, since its `version` was
    /// `CFBundleShortVersionString ?? "0"` and composed no build number at all.
    ///
    /// Deliberately strict about the shape it accepts rather than scanning for
    /// any digits anywhere: `"0.1.0"` must not yield `1`.
    static func buildNumber(inVersionText text: String) -> Int? {
        guard let open = text.lastIndex(of: "("), text.hasSuffix(")") else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return Int(inner)
    }

    /// Whether a daemon that replied `versionReply` to `version(reply:)` can be
    /// sent `recentSafetyStops`.
    ///
    /// **Every uncertain answer is "no".** A `nil` reply (the call failed, so
    /// nothing is known), an unparseable one, and a lower build all mean the
    /// verb is absent — Task 1's R1.4(b), and the only safe direction to be
    /// wrong in: being wrong towards "absent" costs a sentence the app would
    /// have liked to say, and being wrong towards "present" costs the user
    /// their running sessions.
    static func supportsRecentSafetyStops(versionReply: String?) -> Bool {
        guard let versionReply, let build = buildNumber(inVersionText: versionReply) else {
            return false
        }
        return build >= recentSafetyStopsBuild
    }
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

    /// Which verb is being authorised — because as of Plan 8 Task 5 the two
    /// are no longer the same question.
    ///
    /// One function still answers both, so the ownership rule cannot be
    /// implemented twice and half-changed; the asymmetry is confined to the
    /// amendment below, which names `.stop` explicitly.
    enum Action: Equatable {
        /// `HelperProtocol.stopSession` — the only verb the amendment widens.
        case stop
        /// `HelperProtocol.renewLease` — ownership, and nothing else, forever.
        case renew
    }

    /// A caller may act on (stop, renew) a session if they own it — **and, in
    /// exactly one further case, if the app is being asked to stop a session
    /// this same user's own trigger rules started.**
    ///
    /// - Parameters:
    ///   - caller: the peer's stable identity, `<role>-<uid>`.
    ///   - callerUID: the peer's authenticated uid, from
    ///     `NSXPCConnection.effectiveUserIdentifier`.
    ///   - callerRole: which of the daemon's three Mach services accepted the
    ///     peer. Both of these are server-side facts (`ClientRole`), never
    ///     anything the client says about itself — which is what makes the
    ///     amendment safe to write at all.
    static func authorize(sessionID: UUID, action: Action,
                          requestedBy caller: ClientID,
                          uid callerUID: UInt32,
                          role callerRole: ClientRole,
                          among sessions: [Session]) -> Authorization {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return .notFound }

        // The original rule, unchanged, and still answered first: you may act
        // on what you own. Every client, agent included (spec §4).
        if session.owner == caller { return .authorized }

        // ─────────────────────────────────────────────────────────────────────
        // THE AMENDMENT — spec §4's one exception, and the only place in this
        // daemon where a client may touch a session it does not own.
        //
        // Written as its own clause, deliberately not folded into the `==`
        // above, because a reader auditing this trust boundary must be able to
        // see the widening rather than reconstruct it from a compound
        // expression. It is a conjunction of five facts, three of them in
        // `Session.startedByTrigger(forUserID:)`:
        //
        //   1. the verb is **stop**;
        //   2. the caller arrived on the **app's** Mach service;
        //   3. the session's `ownerUID` is the caller's own uid;
        //   4. the session's owner is that uid's **agent** (unforgeable: only
        //      the agent can connect on the agent's service);
        //   5. the session's `origin` is `.trigger`.
        //
        // WHY. A trigger session is started on the user's behalf by a rule they
        // wrote, with no client of theirs in the loop, and the menu-bar app is
        // the only surface that can show it. Leaving it unstoppable there meant
        // the answer to "why is my Mac awake, and how do I stop it?" was
        // `keepy-uppy off --all` — a command that also ends *other users'*
        // sessions. The narrow exception is strictly safer than the escalation
        // it replaces.
        //
        // WHAT IT DOES NOT WIDEN. No user boundary (clause 3 is a uid
        // comparison, so another account's trigger session is untouchable). No
        // other caller (clause 2: the CLI and the agent get nothing new). No
        // other owner (clause 4: this user's `cli-<uid>` sessions stay theirs,
        // whatever their payload claims about `origin`). No other verb (clause
        // 1: `.renew` falls through to `.forbidden` below — the amendment ends
        // a session, it never extends one). And no sweep:
        // `sessionsToStop(all: false)` is untouched, so this remains a
        // per-session decision a person makes on a named row.
        // ─────────────────────────────────────────────────────────────────────
        if action == .stop, callerRole == .app, session.startedByTrigger(forUserID: callerUID) {
            return .authorized
        }

        return .forbidden
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
    ///
    /// ## This did **not** widen with `authorize`, and the choice was made
    ///
    /// Plan 8 Task 5 let the app stop its own user's trigger-started sessions.
    /// The obvious next step — sweeping them from `stopAllSessions(all: false)`
    /// too — was considered and rejected. Three reasons, in weight order:
    ///
    /// 1. **The sweep's whole safety argument is that it touches only what the
    ///    caller itself created.** The amendment is a decision a person makes
    ///    about a session they can see and have named; a sweep is a decision
    ///    about a set nobody enumerated. Those are different acts, and only the
    ///    first is what spec §4's exception describes.
    /// 2. **It would silently rewrite a keystroke somebody already recorded.**
    ///    `HotKeyAction.stopAppSessions` is a *global* shortcut, labelled "Stop
    ///    sessions started from the menu", pressed from inside another app with
    ///    no feedback of any kind. Widening this would make an existing binding
    ///    start ending trigger sessions with no way to re-consent — and a
    ///    trigger session is frequently the only thing keeping the Mac awake,
    ///    that being what triggers are for.
    /// 3. **One implementation of the amendment, not two.** It lives in
    ///    `authorize` alone, so there is a single clause to audit and a single
    ///    place for a future loosening to be noticed.
    ///
    /// The cost, stated rather than hidden: the menu now has per-row Stop
    /// buttons that its own sweep row does not cover. That row is therefore
    /// labelled for the set it really ends (`menuStopAllLabel`), instead of
    /// claiming "all mine" over a list where more is stoppable than it sweeps.
    static func sessionsToStop(all: Bool, requestedBy caller: ClientID, among sessions: [Session]) -> [UUID] {
        if all {
            return sessions.map(\.id)
        }
        return sessions.filter { $0.owner == caller }.map(\.id)
    }
}
