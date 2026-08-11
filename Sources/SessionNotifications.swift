import Foundation

// Everything in this file is pure app-side policy: what is worth telling the
// user, when, and in what words. The one impure thing — actually raising a
// banner — is `NotificationPosting` in `Sources/NotificationService.swift`,
// behind a protocol, so none of this needs UserNotifications to be tested.
//
// It is in `Sources/` and not `Shared/` deliberately. `Shared/` compiles into
// the root daemon and the CLI, neither of which has any business holding a
// notification policy (or user-facing prose), and the daemon in particular is
// a process this project keeps deliberately incapable — see
// `Agent/SessionCompletionNotifier.swift`'s comment for the same argument
// about exec and network capability.

// MARK: - The events

/// What the app is allowed to tell the user: two facts it can actually
/// establish, and **structurally nothing else**.
///
/// No case carries an associated value, and that is the feature rather than a
/// simplification. No process outside the daemon knows *why* a session ended.
/// `SafetyReason` (`Shared/SafetyEngine.swift`) never crosses XPC — Plan 7's
/// research grepped the whole tree and found eight references, all inside that
/// one file, with the single point of observability being an `os_log` line in
/// `Helper/DaemonRuntime.swift`'s `case .stopAll` arm. A client sees the
/// consequence (the sessions are gone from the next `listSessions`) and never
/// the cause. `Shared/SessionCompletion.swift`'s own doc comment has said so
/// since the agent's completion actions were written: "Doesn't distinguish
/// *why* a session ended (condition met, manual stop, safety guard, expiry,
/// agent restart)."
///
/// So a notification naming a reason would be **fabricating** one, and the
/// guarantee against that is the **type**, not a string search over the copy.
/// An earlier draft of this task specified a test asserting that no
/// notification string contains a `SafetyReason`. That test cannot work, on two
/// counts: `SafetyReason` is not `CaseIterable`, so it must hardcode three
/// cases and would go on passing when a fourth landed; and its raw values are
/// `thermal` / `lowBattery` / `maxDuration`, tokens no user-facing sentence
/// contains — so it passes vacuously today *and* would pass on copy reading
/// "Your Mac was overheating", which is precisely the fabrication it was
/// written to catch.
///
/// `CaseIterable` is what makes the guarantee structural: Swift synthesizes
/// that conformance **only** for an enum whose cases all carry no associated
/// values, so `case stoppedBeingKeptAwake(reason: SafetyReason)` does not
/// compile here. There is nowhere to put a reason, and
/// `sessionNotificationCopy(for:)` takes the event and nothing else, so there
/// is nowhere for one to arrive from either.
///
/// (A reason-carrying channel is a *daemon* change and is deliberately
/// deferred: `listSessions` replies with a JSON `[Session]` and an ended
/// session is not in that array, so there is nowhere in the existing shape to
/// hang one, and adding a parameter to an `@objc` protocol method changes the
/// selector and breaks older clients. It is roughly a new
/// `recentSafetyStops(reply:)` verb plus a bounded ring buffer in
/// `DaemonRuntime` — modest, but not this task's.)
enum SessionNotificationEvent: CaseIterable, Equatable {
    /// The last of *this user's* sessions has ended, and at least one of the
    /// endings was not something this app asked for.
    case stoppedBeingKeptAwake
    /// One of this user's own trigger rules started a session — the only thing
    /// in this product that happens with no user action at all, and currently
    /// invisible unless the menu happens to be open.
    case triggerStartedSession
}

/// A notification's two lines, as a value, so the copy is testable without
/// `UNMutableNotificationContent` and without a notification centre.
struct SessionNotificationCopy: Equatable {
    let title: String
    let body: String
}

/// The words, derived from the event and from nothing else.
///
/// **Every claim here is scoped to the user's own sessions**, which is the same
/// union-sensitivity discipline `menuLidCaveat`, `wakeModeSettingsExplanation`
/// and the CLI's `WakeMode.lidCloseCaveat` are all built on. `listSessions` is
/// unfiltered and a Mac can have more than one person logged in, so "this Mac
/// is no longer being kept awake" is a *negative* claim about the machine and
/// is false the moment another account holds a session — and the tracker
/// deliberately still fires in that case, because the event is about the user's
/// own sessions. A *positive* claim ("a session started, so this Mac is being
/// kept awake") is union-safe, because the daemon's reduction can only
/// strengthen it; that is why the trigger event may state it flatly and the
/// stop event may not.
func sessionNotificationCopy(for event: SessionNotificationEvent) -> SessionNotificationCopy {
    switch event {
    case .stoppedBeingKeptAwake:
        // Says what ended and stops. It does not say the Mac will now sleep
        // (another account may hold it awake), and it does not say why (nothing
        // outside the daemon knows).
        return SessionNotificationCopy(
            title: "Your last session has ended",
            body: "Nothing you started is keeping this Mac awake any more.")
    case .triggerStartedSession:
        return SessionNotificationCopy(
            title: "A trigger started a session",
            body: "One of your rules fired, and Keepy Uppy is keeping this Mac awake.")
    }
}

// MARK: - The preference behind each event

/// The two toggles in Settings → General → Notifications, and the storage
/// behind them.
///
/// Takes the naming discipline from `DefaultWakeModePreference` and
/// `DefaultKeepDisksAwakePreference`: **a distinct key per toggle, each named
/// once**, because two files that never call each other agree on a string, and
/// a typo in either is not a compile error and not a crash — it is a Settings
/// pane that appears to work while the notifier goes on reading the old value.
///
/// Both fall back to **off**, the direction `DefaultKeepDisksAwakePreference`
/// takes and for its reason: absence must not manufacture something nobody
/// asked for. Here it buys something stronger than tidiness. Authorization is
/// requested from exactly one place — a toggle being switched on — so a user
/// who never turns one on is never asked for anything, and a test suite reading
/// an empty suite can never reach the live conformer at all. `xcodebuild test`
/// hosts the test bundle *inside this app* (`PreferencesSuite.isRunningTests`
/// exists because of what that already cost once), so "off by default" is what
/// keeps a test run from raising a real system dialog.
enum SessionNotificationPreference {
    static let stopKey = "notifyWhenNothingIsKeepingAwake"
    static let triggerStartKey = "notifyWhenATriggerStartsASession"

    /// Named once, and used both as the `@AppStorage` starting value and as
    /// the answer for anyone who has never opened this pane.
    static let fallback = false

    static func load(from defaults: UserDefaults = PreferencesSuite.defaults)
        -> SessionNotificationPreferences {
        SessionNotificationPreferences(
            onStop: defaults.object(forKey: stopKey) as? Bool ?? fallback,
            onTriggerStart: defaults.object(forKey: triggerStartKey) as? Bool ?? fallback)
    }
}

/// Which events the user has asked to be told about.
///
/// **No field here has a default, and none may gain one.** `Session.init`
/// carries the same prohibition and the scar tissue behind it: three of its
/// parameters had defaults, and all three were silently substituted at a
/// construction site that forgot to pass one. A defaulted `onStop: Bool = false`
/// here would let a future call site build this from half a preference read and
/// answer "off" for the other half — which is a notification that never fires,
/// with a toggle in Settings insisting that it should.
struct SessionNotificationPreferences: Equatable {
    let onStop: Bool
    let onTriggerStart: Bool

    init(onStop: Bool, onTriggerStart: Bool) {
        self.onStop = onStop
        self.onTriggerStart = onTriggerStart
    }

    /// Exhaustive on purpose, like `SessionKind.wireDescription`: a third event
    /// has to be given a toggle by whoever adds it, rather than inheriting
    /// somebody else's idea of harmless from a `default`.
    func wants(_ event: SessionNotificationEvent) -> Bool {
        switch event {
        case .stoppedBeingKeptAwake: return onStop
        case .triggerStartedSession: return onTriggerStart
        }
    }

    /// Whether anything at all is switched on — the gate that keeps the live
    /// `UNUserNotificationCenter` conformer from being constructed.
    var wantsAnything: Bool { onStop || onTriggerStart }
}

// MARK: - The tracker

/// The app's snapshot bookkeeping: which of *this user's* sessions appeared and
/// disappeared between two `listSessions` snapshots, which of the disappearances
/// this app asked for, and therefore what is worth saying.
///
/// **Why this is not `SessionCompletionTracker`.** That type consumes its
/// snapshot inside `recordAndReportEnded`, and one snapshot cannot serve two
/// consumers with independent lifetimes — the agent's 5s tick and the app's 3s
/// poll are different clocks in different processes, and even inside one
/// process a second caller would silently steal the first's baseline. It also
/// reports only endings, and only as a list of sessions. This tracker is the
/// *app's*: it reports both directions, it reduces them to events rather than
/// to sessions, it knows which endings this app requested, and it lives in
/// `Sources/` because the daemon and CLI have no use for any of that.
///
/// **What it does inherit, deliberately and by copying the discipline rather
/// than the code:** the uid filter applied on the way *in*, so the retained
/// snapshot is already scoped and no later path can reintroduce another user's
/// sessions; no baseline on the very first snapshot; and dropping the baseline
/// on disconnect. All three are recorded in `SessionCompletionTracker`'s own
/// comment as defects that were found the hard way, and all three would
/// reproduce here at banner granularity.
struct SessionNotificationTracker {
    /// The uid this tracker speaks for — the app's own (`getuid()`). Matched
    /// against `Session.ownerUID`, which the daemon stamps server-side from the
    /// authenticated XPC peer and never accepts from a client, so it is not
    /// something another client can spoof.
    ///
    /// Note this is **not** the `mine` split the menu uses. That one compares
    /// `owner == app-<uid>`, i.e. this client only, which would ignore exactly
    /// the sessions worth announcing: this user's own CLI and trigger sessions.
    let ownerUID: UInt32

    /// How long an "I asked for this to stop" mark stays valid.
    ///
    /// Bounded, and bounded *wide*: `DaemonConnection`'s poll is 3s and its
    /// per-call timeout is 5s, so a stop the app requested can legitimately
    /// take a call timeout plus a poll before the ending is observed. Ten
    /// seconds covers that with room and still bounds the damage from a stop
    /// the daemon refused — after the window the session's real ending is
    /// announced like anybody else's, rather than being swallowed hours later
    /// by a mark nobody remembers making.
    static let stopSuppressionWindow: TimeInterval = 10

    private var previous: [Session]?
    /// Session ids this app asked the daemon to stop, and when it asked. A
    /// dictionary rather than a set precisely so the window above can exist.
    private var requestedStops: [UUID: Date] = [:]

    init(ownerUID: UInt32) { self.ownerUID = ownerUID }

    /// Whether a baseline exists to diff against. Only the tests care.
    var hasSnapshot: Bool { previous != nil }

    /// Drops the baseline, so the next call reports nothing and merely
    /// re-primes.
    ///
    /// Called when the XPC connection breaks, for the same reason the very
    /// first snapshot reports nothing: after a daemon restart every previously
    /// known session is absent from the new (empty) table at once, which would
    /// diff as "all of them just ended" — one banner announcing that nothing is
    /// keeping the Mac awake, at the moment the daemon came back and everything
    /// was still running. A genuine ending during the outage is missed; that is
    /// the deliberate trade, and it is the agent's.
    ///
    /// It drops the pending stop marks too. Once the baseline is gone there is
    /// nothing left for them to suppress — the next snapshot only re-primes —
    /// and a mark that outlives the world it was recorded in is a mark that
    /// suppresses the wrong ending.
    mutating func forgetSnapshot() {
        previous = nil
        requestedStops = [:]
    }

    /// "This app just asked the daemon to stop these." Called at the menu's own
    /// stop buttons, *before* the XPC call, so no poll can observe the ending
    /// before the mark exists.
    ///
    /// The ids are snapshotted by the caller because `stopAllSessions(all:)`
    /// replies with a **count** and not with ids: after the call there is
    /// nothing left to name.
    ///
    /// This is the one thing the tracker cannot work out for itself, and it is
    /// why it is told rather than asked. Keeping it here — rather than in
    /// `DaemonConnection` — is what stops the XPC transport from acquiring a
    /// notification policy, and it keeps every decision in the one type that
    /// tests can reach.
    mutating func appWillStop(sessionIDs: [UUID], now: Date) {
        for id in sessionIDs { requestedStops[id] = now }
    }

    /// Folds one `listSessions` snapshot in and reports what is worth saying.
    ///
    /// Deliberately one call rather than a getter plus a setter, for
    /// `SessionCompletionTracker.recordAndReportEnded`'s reason: read, diff and
    /// write-back cannot be prised apart by an `await` if the caller has no way
    /// to prise them apart. That defect was reproduced in the agent — a stalled
    /// tick wrote a stale snapshot over a newer one and the next tick re-fired
    /// an already-reported ending — and this type is polled from a timer too.
    mutating func record(current: [Session], now: Date) -> [SessionNotificationEvent] {
        let mine = current.filter { $0.ownerUID == ownerUID }
        defer { previous = mine }

        // Expire first, so a mark that has outlived its window cannot suppress
        // the ending arriving in this very snapshot.
        requestedStops = requestedStops.filter {
            now.timeIntervalSince($0.value) <= Self.stopSuppressionWindow
        }

        guard let previous else { return [] }
        var events: [SessionNotificationEvent] = []

        // Marks are consumed by the ending they were recorded for, whether or
        // not this tick is the one that announces anything — that is what stops
        // a mark leaking into a later tick and swallowing a real ending.
        var unrequestedEndings = 0
        for ended in sessionsEndedSince(previous: previous, current: mine)
        where requestedStops.removeValue(forKey: ended.id) == nil {
            unrequestedEndings += 1
        }

        // The **transition**, not the ending: with two of yours running and one
        // ending, nothing has stopped. And "was every ending mine?" rather than
        // "was any ending mine?" — a tick in which the user stopped one session
        // while another ended by itself still contains something nobody asked
        // for, and that is the whole value of this event.
        if !previous.isEmpty, mine.isEmpty, unrequestedEndings > 0 {
            events.append(.stoppedBeingKeptAwake)
        }

        // At most one, however many appeared. The event carries no payload, so
        // two rules firing in one tick have exactly one thing to say, and two
        // identical banners is the per-session noise this event set exists to
        // avoid.
        if sessionsStartedSince(previous: previous, current: mine).contains(where: isAutomatic) {
            events.append(.triggerStartedSession)
        }

        return events
    }

    /// A session this user's own trigger rule started.
    ///
    /// **Both halves are required, and only one of them is trustworthy.**
    /// `origin` is CLIENT-CHOSEN — `Session.authorized(id:owner:ownerUID:startedAt:)`
    /// lists it among the fields the daemon passes through untouched — so
    /// `origin == .trigger` is a session's self-description. `owner` is
    /// server-stamped from the listener that accepted the connection
    /// (`ClientRole.clientID(forUserID:)`), and only the agent can connect on
    /// the agent's Mach service. Requiring the conjunction is what makes "a
    /// trigger started this" rest on a fact the daemon established, and it is
    /// exactly what `menuSessionGroup` already does for the equivalent menu row.
    private func isAutomatic(_ session: Session) -> Bool {
        session.origin == .trigger
            && session.owner == ClientRole.agent.clientID(forUserID: ownerUID)
    }
}

// MARK: - The coordinator

/// Everything decidable about a notification, in one testable object: the
/// tracker, the preference gate, and the decision to build a notification
/// service at all.
///
/// `AppDelegate` constructs this and forwards `daemon.$sessions` and
/// `daemon.$isConnected` into it, and does nothing else — which is the shape
/// the task asked for, with the forwarding target being something tests can
/// reach rather than a pile of closures in an app delegate that they cannot.
/// `DaemonConnection` is untouched: it publishes everything needed already, and
/// a notification concern inside the XPC client would be policy in the
/// transport.
@MainActor
final class SessionNotifier {
    private var tracker: SessionNotificationTracker
    private let preferences: () -> SessionNotificationPreferences
    private let makeService: () -> NotificationPosting

    /// - Parameters:
    ///   - preferences: read per event rather than captured once, so a toggle
    ///     switched on in Settings takes effect on the next poll instead of on
    ///     the next launch.
    ///   - makeService: a **factory**, and called only when there is something
    ///     to post. That is the mechanism behind "the live conformer is never
    ///     constructed unless a toggle is on", and
    ///     `SessionNotifierTests.testWithEveryToggleOffNothingIsPostedAndNoServiceIsEverBuilt`
    ///     counts the calls so the claim is a test rather than a comment.
    init(ownerUID: UInt32 = UInt32(getuid()),
         preferences: @escaping () -> SessionNotificationPreferences
            = { SessionNotificationPreference.load() },
         makeService: @escaping () -> NotificationPosting = { UserNotificationService() }) {
        self.tracker = SessionNotificationTracker(ownerUID: ownerUID)
        self.preferences = preferences
        self.makeService = makeService
    }

    /// One published `listSessions` snapshot.
    ///
    /// The tracker is fed **whether or not anything is switched on**, which is
    /// the rule `EvidenceLoopRunner` follows for the completion tracker and for
    /// the same reason: turning a toggle on mid-session must not hand it a
    /// baseline from whenever the app last happened to look, because the first
    /// diff against a stale baseline is the one that announces something that
    /// did not just happen.
    func record(sessions: [Session], now: Date = Date()) {
        let events = tracker.record(current: sessions, now: now)
        let wanted = preferences()
        let toPost = events.filter(wanted.wants)
        guard !toPost.isEmpty else { return }
        let service = makeService()
        for event in toPost {
            let copy = sessionNotificationCopy(for: event)
            service.post(title: copy.title, body: copy.body)
        }
    }

    /// The connection broke. See `SessionNotificationTracker.forgetSnapshot()`.
    func forgetSnapshot() { tracker.forgetSnapshot() }

    /// This app is about to ask the daemon to stop these sessions.
    func appWillStop(sessionIDs: [UUID], now: Date = Date()) {
        tracker.appWillStop(sessionIDs: sessionIDs, now: now)
    }
}
