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

/// What the app is allowed to tell the user: facts it can actually establish,
/// and **structurally nothing else**.
///
/// No case carries an associated value, and that is the feature rather than a
/// simplification. Until Plan 8 Task 6 no process outside the daemon knew *why*
/// a session ended at all: `SafetyReason` (`Shared/SafetyEngine.swift`) crossed
/// no boundary, a client saw the consequence (the sessions are gone from the
/// next `listSessions`) and never the cause, and
/// `Shared/SessionCompletion.swift`'s own doc comment had said so since the
/// agent's completion actions were written: "Doesn't distinguish *why* a
/// session ended (condition met, manual stop, safety guard, expiry, agent
/// restart)."
///
/// So a notification naming a reason **this app does not have** would be
/// fabricating one, and the guarantee against that is the **type**, not a
/// string search over the copy. An earlier draft specified a test asserting
/// that no notification string contains a `SafetyReason`. That test cannot
/// work: its raw values are `thermal` / `lowBattery` / `maxDuration`, tokens no
/// user-facing sentence contains — so it passes vacuously *and* would pass on
/// copy reading "Your Mac was overheating", which is precisely the fabrication
/// it was written to catch.
///
/// `CaseIterable` is what makes the guarantee structural: Swift synthesizes
/// that conformance **only** for an enum whose cases all carry no associated
/// values, so `case stoppedBeingKeptAwake(reason: SafetyReason)` does not
/// compile here. There is nowhere to put a reason, and
/// `sessionNotificationCopy(for:)` takes the event and nothing else, so there
/// is nowhere for one to arrive from either.
///
/// ## What Plan 8 Task 6 changed, and what it did not
///
/// The daemon now keeps a bounded log of guard-ended sessions
/// (`Shared/SafetyStopLog.swift`) and answers `recentSafetyStops`, so for
/// **some** endings the app can attribute a cause — to the exact session ids it
/// just watched disappear, never to "something recent". Plan 7's own execution
/// report recorded the shape this had to take in advance: *"when it lands, the
/// honest change is a THIRD event, not a payload bolted onto this one."*
///
/// So: payload-free cases, one per `SafetyReason`. The alternative — one
/// `.stoppedBySafetyGuard(SafetyReason)` case — would have meant dropping
/// `CaseIterable`, hand-writing `allCases`, and losing the guarantee this
/// comment rests on, to save two cases. What buys back the safety of writing
/// three by hand is `safetyReason(named:)` below: a **bijection** checked over
/// `allCases` in both directions, so a fourth `SafetyReason` fails a test
/// rather than quietly having no banner.
///
/// **The reason cases never accompany `.stoppedBeingKeptAwake`; they replace
/// it.** A safety stop is a `.stopAll`, so the snapshot that gains a reason is
/// the same snapshot that trips the reason-free event, and emitting both is two
/// banners for one event. `attributedStopEvent` is the single place that
/// chooses between them.
enum SessionNotificationEvent: CaseIterable, Equatable {
    /// The last of *this user's* sessions has ended, and at least one of the
    /// endings was not something this app asked for.
    ///
    /// Also the **fallback for every way a reason can be unavailable** — an
    /// older daemon that does not implement the verb, a record that aged out or
    /// was evicted, or an ending no guard was behind at all. All three land on
    /// this one sentence deliberately: it states no cause and implies none,
    /// where copy like "it ended on its own" or "no guard fired" would convert
    /// "I don't know" into "nothing happened".
    case stoppedBeingKeptAwake
    /// One of this user's own trigger rules started a session — the only thing
    /// in this product that happens with no user action at all, and currently
    /// invisible unless the menu happens to be open.
    case triggerStartedSession
    /// A thermal guard ended them: this Mac was too hot.
    case stoppedByThermalGuard
    /// The battery guard ended them: too little charge left.
    case stoppedByLowBattery
    /// The maximum-session-length backstop ended them.
    case stoppedByMaxDuration
}

// MARK: - The weld between a reason and the event that names it

/// The event that names `reason`. Total, and an exhaustive `switch` on
/// purpose: a fourth `SafetyReason` cannot be added without somebody deciding
/// what it says to a user.
func sessionNotificationEvent(for reason: SafetyReason) -> SessionNotificationEvent {
    switch reason {
    case .thermal: return .stoppedByThermalGuard
    case .lowBattery: return .stoppedByLowBattery
    case .maxDuration: return .stoppedByMaxDuration
    }
}

/// The reason an event names, or `nil` for the events that name none.
///
/// The other half of the weld, and the reason both halves exist rather than one
/// `switch`: together they are a bijection, checked over `allCases` in **both**
/// directions (`SessionNotificationBijectionTests`) — the same arrangement
/// `Tests/CLICommandTests.swift` puts between `SessionKind.Family` and the CLI's
/// flags, and `TriggerConditionKind` puts between its own pair. One direction
/// alone would let two reasons collapse onto one event, or let an event exist
/// that no reason can reach.
func safetyReason(named event: SessionNotificationEvent) -> SafetyReason? {
    switch event {
    case .stoppedBeingKeptAwake, .triggerStartedSession: return nil
    case .stoppedByThermalGuard: return .thermal
    case .stoppedByLowBattery: return .lowBattery
    case .stoppedByMaxDuration: return .maxDuration
    }
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

    // The three reason sentences. Each says everything the reason-free copy
    // says *and* which guard fired, so replacing that event with one of these
    // never costs the user information — which is what makes the substitution
    // safe to make silently.
    //
    // Each stays inside the same union-sensitivity rule: the claim is about
    // your sessions, never about what the Mac will now do. Another account may
    // still be holding it awake, and a thermal stop is machine-wide, so "this
    // Mac will now sleep" would be false in exactly the case the guard cares
    // about most.
    case .stoppedByThermalGuard:
        return SessionNotificationCopy(
            title: "Stopped: this Mac was too hot",
            body: "Keepy Uppy ended your sessions so it can cool down. "
                + "Nothing you started is keeping this Mac awake any more.")
    case .stoppedByLowBattery:
        return SessionNotificationCopy(
            title: "Stopped: the battery was running out",
            body: "Keepy Uppy ended your sessions to save what is left. "
                + "Nothing you started is keeping this Mac awake any more.")
    case .stoppedByMaxDuration:
        return SessionNotificationCopy(
            title: "Stopped: the time limit was reached",
            body: "Your sessions ran for as long as Keepy Uppy allows, so it ended them. "
                + "Nothing you started is keeping this Mac awake any more.")
    }
}

// MARK: - Attributing an ending, or honestly declining to

/// **The whole point of the feature: the reason-carrying event when the app can
/// attribute the ending, and the reason-free one whenever it cannot.**
///
/// - Parameters:
///   - endedUnrequested: the ids that disappeared in this very tick without
///     this app asking. Matching on ids rather than on a time window is what
///     makes attribution *exact*: the daemon keeps records for five minutes, so
///     a window would happily explain a lease that expired by itself a minute
///     after a thermal stop, which is a fabricated cause with a real record
///     behind it.
///   - records: whatever `recentSafetyStops` replied. **`[]` means "no reason
///     available" and never "no guard fired"** — an older daemon, a failed
///     call, an evicted record and a genuinely ordinary ending all arrive here
///     as the same empty array, and all four must land on the same sentence.
///   - ownerUID: this user's. The reply is unfiltered by design, so the filter
///     is applied here, on the way in, exactly as `SessionNotificationTracker`
///     and `SessionCompletionTracker` both do.
///
/// Two conditions, and both are required:
///
/// 1. **Every** unrequested ending in the tick is explained. A tick in which a
///    guard ended one session while another expired by itself is not a tick the
///    app can describe as "a guard stopped your sessions" — it stopped one of
///    them. Partial attribution is the polite version of guessing.
/// 2. The explaining records name **one** reason. Two episodes inside one poll
///    is vanishingly unlikely and trivially handled: there is no honest way to
///    pick one of two causes, so it names neither.
func attributedStopEvent(endedUnrequested: [UUID],
                         records: [SafetyStopRecord],
                         ownerUID: UInt32) -> SessionNotificationEvent {
    let ids = Set(endedUnrequested)
    guard !ids.isEmpty else { return .stoppedBeingKeptAwake }

    let explaining = records.filter { $0.ownerUID == ownerUID && ids.contains($0.sessionID) }
    guard Set(explaining.map(\.sessionID)) == ids else { return .stoppedBeingKeptAwake }

    let reasons = Set(explaining.map(\.reason))
    guard reasons.count == 1, let reason = reasons.first else { return .stoppedBeingKeptAwake }
    return sessionNotificationEvent(for: reason)
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
    /// One key for all three reason events, not one each. "Which guard?" is a
    /// single question a user either wants answered or does not; three toggles
    /// would be three ways to be told the same thing, and would make
    /// `wants(_:)` a place where a fourth reason could be given somebody else's
    /// idea of a sensible default.
    static let safetyStopKey = "notifyWhenASafetyGuardStopsSessions"

    /// Named once, and used both as the `@AppStorage` starting value and as
    /// the answer for anyone who has never opened this pane.
    static let fallback = false

    static func load(from defaults: UserDefaults = PreferencesSuite.defaults)
        -> SessionNotificationPreferences {
        SessionNotificationPreferences(
            onStop: defaults.object(forKey: stopKey) as? Bool ?? fallback,
            onTriggerStart: defaults.object(forKey: triggerStartKey) as? Bool ?? fallback,
            onSafetyStop: defaults.object(forKey: safetyStopKey) as? Bool ?? fallback)
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
    /// "…and say which guard." A refinement of `onStop` rather than a rival to
    /// it: see `wants(_:)` for the four combinations and what each one means.
    let onSafetyStop: Bool

    init(onStop: Bool, onTriggerStart: Bool, onSafetyStop: Bool) {
        self.onStop = onStop
        self.onTriggerStart = onTriggerStart
        self.onSafetyStop = onSafetyStop
    }

    /// Exhaustive on purpose, like `SessionKind.wireDescription`: a further
    /// event has to be given a toggle by whoever adds it, rather than
    /// inheriting somebody else's idea of harmless from a `default`.
    ///
    /// **All three reason events answer to the one toggle**, which is what
    /// makes the four combinations readable:
    ///
    /// | stop | guard | what happens |
    /// | --- | --- | --- |
    /// | on | off | the plain sentence, always. The reason is never even asked
    ///   for, so a user who has not opted in never causes this app to send
    ///   `recentSafetyStops` at all. |
    /// | on | on | the reason when it is available, the plain sentence when it
    ///   is not. |
    /// | off | on | the reason when it is available, and silence when it is
    ///   not — which is the literal reading of "tell me when a guard stops my
    ///   sessions", and posting the plain sentence here would be posting the
    ///   notification they switched off. |
    /// | off | off | nothing, and no service is ever built. |
    func wants(_ event: SessionNotificationEvent) -> Bool {
        switch event {
        case .stoppedBeingKeptAwake: return onStop
        case .triggerStartedSession: return onTriggerStart
        case .stoppedByThermalGuard, .stoppedByLowBattery, .stoppedByMaxDuration:
            return onSafetyStop
        }
    }

    /// Whether anything at all is switched on — the gate that keeps the live
    /// `UNUserNotificationCenter` conformer from being constructed.
    var wantsAnything: Bool { onStop || onTriggerStart || onSafetyStop }
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
    mutating func record(current: [Session], now: Date) -> Outcome {
        let mine = current.filter { $0.ownerUID == ownerUID }
        defer { previous = mine }

        // Expire first, so a mark that has outlived its window cannot suppress
        // the ending arriving in this very snapshot.
        requestedStops = requestedStops.filter {
            now.timeIntervalSince($0.value) <= Self.stopSuppressionWindow
        }

        guard let previous else { return Outcome(events: [], endedUnrequested: []) }
        var events: [SessionNotificationEvent] = []

        // Marks are consumed by the ending they were recorded for, whether or
        // not this tick is the one that announces anything — that is what stops
        // a mark leaking into a later tick and swallowing a real ending.
        var unrequestedEndings: [UUID] = []
        for ended in sessionsEndedSince(previous: previous, current: mine)
        where requestedStops.removeValue(forKey: ended.id) == nil {
            unrequestedEndings.append(ended.id)
        }

        // The **transition**, not the ending: with two of yours running and one
        // ending, nothing has stopped. And "was every ending mine?" rather than
        // "was any ending mine?" — a tick in which the user stopped one session
        // while another ended by itself still contains something nobody asked
        // for, and that is the whole value of this event.
        if !previous.isEmpty, mine.isEmpty, !unrequestedEndings.isEmpty {
            events.append(.stoppedBeingKeptAwake)
        }

        // At most one, however many appeared. The event carries no payload, so
        // two rules firing in one tick have exactly one thing to say, and two
        // identical banners is the per-session noise this event set exists to
        // avoid.
        if sessionsStartedSince(previous: previous, current: mine).contains(where: isAutomatic) {
            events.append(.triggerStartedSession)
        }

        return Outcome(events: events, endedUnrequested: unrequestedEndings)
    }

    /// One tick's answer: what is worth saying, **and** which endings the
    /// saying is about.
    ///
    /// The ids are here rather than inferred by the caller because only this
    /// type can know them — it owns the baseline, and it owns which endings
    /// this app asked for. Returning them is what lets the reason be attached
    /// to *these* endings and to nothing else; `attributedStopEvent` is where
    /// they are consumed.
    ///
    /// A single value rather than a getter beside the existing return, for
    /// `recordAndReportEnded`'s reason: read, diff and write-back cannot be
    /// prised apart by an `await` if the caller has no way to prise them apart,
    /// and a second call before the getter was read would silently answer about
    /// a different tick.
    struct Outcome: Equatable {
        let events: [SessionNotificationEvent]
        /// Ids that disappeared in this tick without this app asking. Populated
        /// whenever there were any — including ticks that announce nothing,
        /// because one of two sessions ending is an unrequested ending that no
        /// event describes. Only meaningful to a caller alongside
        /// `.stoppedBeingKeptAwake`.
        let endedUnrequested: [UUID]
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
    /// trigger started this" rest on a fact the daemon established.
    ///
    /// This used to say all that and then write the conjunction out a second
    /// time, ending on "exactly what `menuSessionGroup` already does for the
    /// equivalent menu row" — which is an accurate description of two rules that
    /// agree, and of the day one of them is loosened alone. It now *asks* that
    /// rule instead: `Session.startedByTrigger(forUserID:)` is defined as the
    /// menu grouping, so the banner and the row cannot come to disagree about
    /// which sessions were automatic.
    ///
    /// The tracker's own uid filter (`record`'s `mine`) already applies the
    /// `ownerUID` half, so this is the same answer on the same input; asking the
    /// whole rule rather than the leftover half is what keeps it that way if the
    /// filter ever moves.
    private func isAutomatic(_ session: Session) -> Bool {
        session.startedByTrigger(forUserID: ownerUID)
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
    private let safetyStops: () async -> [SafetyStopRecord]

    /// The deferred half of the most recent stop transition — the round trip
    /// that asks why, and the post that follows it.
    ///
    /// Held rather than discarded so that a test can `await` it: the alternative
    /// is a test that yields a hopeful number of times, which passes on a quiet
    /// machine and fails on a loaded one. Nothing in production reads it, and
    /// nothing cancels it.
    ///
    /// There is at most one in flight in practice, because the transition it
    /// follows requires this user's session list to have just become empty and
    /// cannot recur until something starts and ends again.
    private(set) var reasonQuery: Task<Void, Never>?

    /// - Parameters:
    ///   - preferences: read per event rather than captured once, so a toggle
    ///     switched on in Settings takes effect on the next poll instead of on
    ///     the next launch.
    ///   - makeService: a **factory**, and called only when there is something
    ///     to post. That is the mechanism behind "the live conformer is never
    ///     constructed unless a toggle is on", and
    ///     `SessionNotifierTests.testWithEveryToggleOffNothingIsPostedAndNoServiceIsEverBuilt`
    ///     counts the calls so the claim is a test rather than a comment.
    ///   - safetyStops: asks the daemon why. **Deliberately has no default**,
    ///     unlike the two above, and the asymmetry is the point: their defaults
    ///     are the production behaviour, whereas any default this one could have
    ///     (`{ [] }`) is *the feature switched off*. A construction site that
    ///     forgot to wire it would compile, run, and quietly never explain
    ///     anything — which is the failure mode `Session.init`'s three defaulted
    ///     parameters produced three separate times.
    init(ownerUID: UInt32 = UInt32(getuid()),
         preferences: @escaping () -> SessionNotificationPreferences
            = { SessionNotificationPreference.load() },
         makeService: @escaping () -> NotificationPosting = { UserNotificationService() },
         safetyStops: @escaping () async -> [SafetyStopRecord]) {
        self.tracker = SessionNotificationTracker(ownerUID: ownerUID)
        self.preferences = preferences
        self.makeService = makeService
        self.safetyStops = safetyStops
    }

    /// One published `listSessions` snapshot.
    ///
    /// The tracker is fed **whether or not anything is switched on**, which is
    /// the rule `EvidenceLoopRunner` follows for the completion tracker and for
    /// the same reason: turning a toggle on mid-session must not hand it a
    /// baseline from whenever the app last happened to look, because the first
    /// diff against a stale baseline is the one that announces something that
    /// did not just happen.
    /// **Stays synchronous, and the reason is ordering.** The tracker's
    /// read-diff-write runs to completion before this method can suspend, so
    /// two snapshots arriving close together cannot be folded in out of order —
    /// which is the defect `SessionCompletionTracker` records having been
    /// reproduced in the agent, where a stalled tick wrote a stale snapshot over
    /// a newer one. Only the *reason* is deferred, and only when there is one to
    /// ask for.
    func record(sessions: [Session], now: Date = Date()) {
        let outcome = tracker.record(current: sessions, now: now)
        let wanted = preferences()

        // Anything that needs no reason is posted from this same synchronous
        // stretch. (In practice that is only `.triggerStartedSession`, and it
        // cannot co-occur with the stop event: one requires this user's list to
        // be empty and the other requires a new session in it.)
        post(outcome.events.filter { $0 != .stoppedBeingKeptAwake }, wanted: wanted)

        guard outcome.events.contains(.stoppedBeingKeptAwake) else { return }

        // **The only thing in this app that ever causes `recentSafetyStops` to
        // be sent, and the toggle is checked before anything is asked.** A user
        // who has not opted in never puts that verb on the wire at all — which
        // is a consent gate on top of the three in `SafetyStopVerbGate`, and
        // the cheapest of them.
        guard wanted.onSafetyStop else {
            return post([.stoppedBeingKeptAwake], wanted: wanted)
        }

        let ended = outcome.endedUnrequested
        let uid = tracker.ownerUID
        reasonQuery = Task { [weak self] in
            guard let self else { return }
            // `[]` on every failure path, and `attributedStopEvent` turns that
            // into the reason-free sentence. The app never learns *why it does
            // not know*, because there is nothing different to say in any of
            // those cases.
            let records = await self.safetyStops()
            let event = attributedStopEvent(endedUnrequested: ended, records: records,
                                            ownerUID: uid)
            // Re-read rather than reuse `wanted`: a round trip has happened, and
            // this is the same "read the preference per event" rule the
            // initialiser documents.
            self.post([event], wanted: self.preferences())
        }
    }

    /// Filters by preference and posts, building a service only if something
    /// survives the filter — which is the whole of "the live conformer is never
    /// constructed unless a toggle is on".
    private func post(_ events: [SessionNotificationEvent],
                      wanted: SessionNotificationPreferences) {
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
