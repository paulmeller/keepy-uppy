import XCTest
// Named only by `NotificationAuthorizationTests` at the bottom of this file,
// which checks the mapping from the framework's own status enum. Nothing else
// here touches UserNotifications, and nothing here constructs a notification
// centre — see `SessionNotifierTests` for why that is load-bearing rather than
// tidy.
import UserNotifications
@testable import KeepyUppy

/// The policy behind the two notifications this app can honestly raise, which
/// is the whole feature: everything impure is one `post(title:body:)` call
/// behind a protocol, and everything decidable is
/// `SessionNotificationTracker`, tested here.
///
/// Every rule below is one the agent's equivalent had to learn the hard way.
/// `Shared/SessionCompletion.swift` records both defects that taught it — a
/// stale snapshot re-diffing an already-reported ending, and a tracker with no
/// uid filter running one user's script for another user's session — and this
/// tracker inherits both fixes rather than rediscovering them.
final class SessionNotificationTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var t1: Date { t0.addingTimeInterval(3) }
    private var t2: Date { t0.addingTimeInterval(6) }
    private var t3: Date { t0.addingTimeInterval(12) }

    private let me: UInt32 = 501
    private let otherUser: UInt32 = 502

    /// `role` and `origin` are both named at every call site that cares,
    /// because the trigger event rests on the *pair* — see
    /// `testASessionClaimingToBeATriggerFromANonAgentClientIsNotAnnounced`.
    private func session(id: UUID = UUID(), ownerUID: UInt32 = 501,
                         role: ClientRole = .app,
                         origin: SessionOrigin = .manual) -> Session {
        Session(id: id, kind: .indefinite, owner: role.clientID(forUserID: ownerUID),
                ownerUID: ownerUID, persistence: .detached, origin: origin,
                startedAt: t0, triggerID: origin == .trigger ? UUID() : nil,
                wakeMode: .clamshell, keepsDisksAwake: false)
    }

    private func triggerSession(ownerUID: UInt32 = 501) -> Session {
        session(ownerUID: ownerUID, role: .agent, origin: .trigger)
    }

    private func tracker() -> SessionNotificationTracker {
        SessionNotificationTracker(ownerUID: me)
    }

    // MARK: - When not to fire

    /// The very first snapshot has no predecessor. Without this, launching the
    /// app announces the end of every session that ended while it was closed —
    /// the exact bug `SessionCompletionTracker` documents at startup — and
    /// announces every live trigger session as if it had just started.
    func testTheFirstSnapshotReportsNothing() {
        var tracker = self.tracker()
        XCTAssertFalse(tracker.hasSnapshot)
        XCTAssertEqual(tracker.record(current: [session(), triggerSession()], now: t0), [])
        XCTAssertTrue(tracker.hasSnapshot)
    }

    /// A daemon restart empties the table. Diffing across it would announce
    /// every live session at once. `forgetSnapshot()` on disconnect, the same
    /// trade as the agent's: a genuine ending during the outage is missed, and
    /// that is better than N false ones in one tick.
    func testALostConnectionDropsTheBaselineRatherThanAnnouncingEverything() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(), session()], now: t0)
        tracker.forgetSnapshot()
        XCTAssertFalse(tracker.hasSnapshot)
        XCTAssertEqual(tracker.record(current: [], now: t1), [])
    }

    /// ...and having forgotten, it re-primes and resumes reporting normally.
    func testForgettingThenRePrimingResumesNormalReporting() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0)
        tracker.forgetSnapshot()
        let fresh = session()
        XCTAssertEqual(tracker.record(current: [fresh], now: t1), [])
        XCTAssertEqual(tracker.record(current: [], now: t2), [.stoppedBeingKeptAwake])
    }

    /// Another user's session is not this app's business to narrate — the same
    /// uid filter `SessionCompletionTracker(ownerUID: getuid())` applies, and
    /// for the same reason: one agent and one app per user, one unfiltered
    /// table.
    func testAnotherUsersSessionEndingSaysNothing() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(ownerUID: otherUser)], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [])
    }

    /// It is "nothing of yours is keeping this Mac awake", not "a session
    /// ended". With two of yours running and one ending, nothing has stopped.
    func testEndingOneOfTwoSessionsSaysNothing() {
        var tracker = self.tracker()
        let staying = session()
        _ = tracker.record(current: [session(), staying], now: t0)
        XCTAssertEqual(tracker.record(current: [staying], now: t1), [])
    }

    func testEndingTheLastSessionSaysSo() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [.stoppedBeingKeptAwake])
    }

    /// ...and another user's live session does not suppress your notification,
    /// because the claim is about YOUR sessions. The copy is written so that
    /// this is not a lie about the machine — see
    /// `SessionNotificationCopyTests`, and the union-sensitivity argument
    /// `menuLidCaveat` and `wakeModeSettingsExplanation` are both built on.
    func testAnotherUsersLiveSessionDoesNotSuppressYours() {
        var tracker = self.tracker()
        let theirs = session(ownerUID: otherUser)
        _ = tracker.record(current: [session(), theirs], now: t0)
        XCTAssertEqual(tracker.record(current: [theirs], now: t1), [.stoppedBeingKeptAwake])
    }

    /// A session that ends and is replaced in the same tick has not stopped
    /// keeping the Mac awake, so there is nothing to say — the transition is
    /// what is announced, never the individual ending.
    func testASessionReplacedInTheSameTickSaysNothingAboutStopping() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0)
        XCTAssertEqual(tracker.record(current: [session()], now: t1), [])
    }

    /// An empty table that stays empty is not an event. Without the
    /// `previous.isEmpty` half of the transition test, every poll of an idle
    /// Mac would announce that it had stopped being kept awake.
    func testStayingIdleIsNotAnEvent() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [])
    }

    // MARK: - The trigger event

    func testATriggerStartedSessionIsAnnouncedWhenItAppears() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [triggerSession()], now: t1),
                       [.triggerStartedSession])
    }

    func testASessionYouStartedYourselfIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [session()], now: t1), [])
    }

    func testATriggerSessionOfAnotherUsersIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [triggerSession(ownerUID: otherUser)], now: t1), [])
    }

    /// `origin` is CLIENT-CHOSEN — `Session.authorized(id:owner:ownerUID:startedAt:)`
    /// lists it among the fields the daemon passes through untouched — so
    /// "a trigger started this" rests on the server-stamped `owner` as well.
    /// Same conjunction, same reason, as `menuSessionGroup`.
    func testASessionClaimingToBeATriggerFromANonAgentClientIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [session(role: .cli, origin: .trigger)], now: t1), [])
        _ = tracker.record(current: [], now: t2)
        XCTAssertEqual(tracker.record(current: [session(role: .agent, origin: .manual)],
                                      now: t2.addingTimeInterval(3)), [])
        // ...and this app's own session claiming it, which is the one shape a
        // *genuine* Keepy Uppy could produce: `DaemonConnection.startSession`
        // takes the origin as a parameter. The menu row for such a session may
        // honestly say "started automatically" — it is this app describing its
        // own session — but a banner announcing "one of your rules started a
        // session" would be wrong, because no rule did.
        _ = tracker.record(current: [], now: t3)
        XCTAssertEqual(tracker.record(current: [session(role: .app, origin: .trigger)],
                                      now: t3.addingTimeInterval(3)), [])
    }

    /// The weld. The banner and the menu row must not become two rules: the
    /// tracker fires exactly when the session is one this user's own trigger
    /// rule started, and that is now a single predicate rather than a
    /// conjunction written out here and again in `SessionDisplay.swift`.
    func testTheAnnouncedSessionsAreExactlyTheOnesTheMenuCallsAutomatic() {
        for candidate in [session(role: .agent, origin: .trigger),
                          session(role: .agent, origin: .manual),
                          session(role: .app, origin: .trigger),
                          session(role: .cli, origin: .trigger),
                          session(ownerUID: otherUser, role: .agent, origin: .trigger)] {
            var tracker = self.tracker()
            _ = tracker.record(current: [], now: t0)
            let announced = tracker.record(current: [candidate], now: t1)
                .contains(.triggerStartedSession)
            XCTAssertEqual(announced, candidate.startedByTrigger(forUserID: me),
                           "the banner and the menu disagree about \(candidate.owner)")
        }
    }

    /// The event carries no payload, so two trigger sessions appearing in one
    /// tick have exactly one thing to say. Two identical banners for one tick
    /// is the per-session noise this event set was chosen to avoid.
    func testTwoTriggerSessionsInOneTickAnnounceOnce() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0)
        XCTAssertEqual(tracker.record(current: [triggerSession(), triggerSession()], now: t1),
                       [.triggerStartedSession])
    }

    // MARK: - Suppressing the user's own click

    /// The commonest way for the last session to end is the user clicking Stop
    /// in this app's own menu. Announcing that is a banner explaining a click
    /// back to the person who made it — the same noise argument that rejected
    /// per-session notifications, which an earlier draft of this plan applied
    /// and then reproduced at machine granularity.
    func testASessionThisAppStoppedIsNotAnnounced() {
        var tracker = self.tracker()
        let stopped = session()
        _ = tracker.record(current: [stopped], now: t0)
        tracker.appWillStop(sessionIDs: [stopped.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [])
    }

    /// The menu's sweep row (`menuStopAllLabel`) stops several at once, and
    /// `stopAllSessions(all:)` replies with a count rather than with ids — so
    /// the call site snapshots the ids first, and every one of them is covered.
    func testStoppingSeveralAtOnceFromThisAppIsNotAnnounced() {
        var tracker = self.tracker()
        let a = session()
        let b = session()
        _ = tracker.record(current: [a, b], now: t0)
        tracker.appWillStop(sessionIDs: [a.id, b.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [])
    }

    /// ...but a stop this app did NOT initiate is exactly the event worth
    /// having. `keepy-uppy off` in a Terminal, an expiry, a condition ending, a
    /// safety guard: from here they are indistinguishable, and all four are
    /// things that happened without the user touching this app.
    func testASessionStoppedFromTheCommandLineIsAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(role: .cli)], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [.stoppedBeingKeptAwake])
    }

    /// A tick in which the user stopped one session and another ended by
    /// itself still has news in it: something happened that nobody asked for.
    /// Suppression asks "was every ending mine?", not "was any ending mine?".
    func testAnEndingNobodyAskedForIsAnnouncedEvenAlongsideOneThisAppDid() {
        var tracker = self.tracker()
        let clicked = session()
        let expired = session(role: .cli)
        _ = tracker.record(current: [clicked, expired], now: t0)
        tracker.appWillStop(sessionIDs: [clicked.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1), [.stoppedBeingKeptAwake])
    }

    /// The suppression must not leak into the next tick and swallow a real
    /// ending: it is consumed by the one ending it was recorded for.
    func testSuppressionAppliesOnlyToTheEndingItWasFor() {
        var tracker = self.tracker()
        let clicked = session()
        let other = session()
        _ = tracker.record(current: [clicked, other], now: t0)
        tracker.appWillStop(sessionIDs: [clicked.id], now: t0)
        // The clicked session goes; one of the user's is still live, so there
        // is nothing to announce either way.
        XCTAssertEqual(tracker.record(current: [other], now: t1), [])
        // The other one ends on its own a tick later, and that is news.
        XCTAssertEqual(tracker.record(current: [], now: t2), [.stoppedBeingKeptAwake])
    }

    /// A stop the daemon refused, or one that never took effect, must not
    /// suppress the session's real ending hours later. The mark is bounded, at
    /// a window comfortably wider than the 3s poll and the 5s call timeout it
    /// is racing and far narrower than any session.
    func testAStopThatNeverHappenedStopsSuppressingAfterItsWindow() {
        var tracker = self.tracker()
        let stubborn = session()
        _ = tracker.record(current: [stubborn], now: t0)
        tracker.appWillStop(sessionIDs: [stubborn.id], now: t0)
        // Still there, tick after tick.
        let window = SessionNotificationTracker.stopSuppressionWindow
        XCTAssertEqual(tracker.record(current: [stubborn], now: t0.addingTimeInterval(3)), [])
        XCTAssertEqual(
            tracker.record(current: [], now: t0.addingTimeInterval(window + 1)),
            [.stoppedBeingKeptAwake])
    }

    /// The window is wide enough to cover the round trip it exists for: a stop
    /// is requested, the XPC call is made, and the poll that observes the
    /// ending arrives well inside it.
    func testTheSuppressionWindowOutlastsThePollItRaces() {
        XCTAssertGreaterThan(SessionNotificationTracker.stopSuppressionWindow, 5,
                             "a stop can take a full DaemonConnection.callTimeout to be observed")
    }

    /// Losing the connection drops the marks with the baseline. There is
    /// nothing left for them to suppress — the next snapshot only re-primes —
    /// and a mark that outlived the world it was recorded in is a mark that
    /// suppresses the wrong ending.
    func testForgettingTheSnapshotAlsoForgetsWhatThisAppAskedToStop() {
        var tracker = self.tracker()
        let a = session()
        _ = tracker.record(current: [a], now: t0)
        tracker.appWillStop(sessionIDs: [a.id], now: t0)
        tracker.forgetSnapshot()
        // Reconnected, same session still live, and it later ends by itself.
        XCTAssertEqual(tracker.record(current: [a], now: t1), [])
        XCTAssertEqual(tracker.record(current: [], now: t2), [.stoppedBeingKeptAwake])
    }

    // MARK: - The honesty test

    /// Finding 1, as a TYPE-level guarantee. No process outside the daemon
    /// knows WHY a session ended — `SafetyReason` reaches no client, by any
    /// path — so a notification that names a reason is fabricating one, and the
    /// way to guarantee it cannot is for the event to have nowhere to put one.
    ///
    /// Asserted as shape rather than as strings, deliberately. The
    /// string-matching version of this test (`testNoNotificationTextNamesASafetyReason`)
    /// cannot work: `SafetyReason` is not `CaseIterable`, so it would hardcode
    /// three cases and go on passing when a fourth landed, and its raw values —
    /// `thermal`, `lowBattery`, `maxDuration` — are tokens no user-facing
    /// sentence contains, so it would pass vacuously today *and* pass on copy
    /// reading "Your Mac was overheating", which is precisely the fabrication
    /// it was written to catch.
    ///
    /// Two mechanisms hold this, one of which is the compiler:
    /// `SessionNotificationEvent`'s `CaseIterable` conformance is synthesized
    /// **only** for an enum whose cases carry no associated values, so
    /// `case stoppedBeingKeptAwake(reason: SafetyReason)` does not build. The
    /// `Mirror` check is the same fact asserted at runtime, so the guarantee is
    /// visible in a failure message and not only in a compile error.
    func testTheNotificationEventCarriesNoReasonPayload() {
        for event in SessionNotificationEvent.allCases {
            XCTAssertTrue(Mirror(reflecting: event).children.isEmpty,
                          "\(event) carries a payload — the only thing a notification could put "
                          + "in it is a reason this app cannot know")
        }
        XCTAssertEqual(SessionNotificationEvent.allCases.count, 2,
                       "two events were decided in Task 1 Step 4; a third needs its own argument")
    }
}

/// The words themselves. Two events, two sentences, and one claim neither of
/// them is allowed to make.
final class SessionNotificationCopyTests: XCTestCase {
    /// Over `allCases`, so a third event cannot ship with a blank banner.
    func testEveryEventHasATitleAndABodyOfItsOwn() {
        var titles: Set<String> = []
        for event in SessionNotificationEvent.allCases {
            let copy = sessionNotificationCopy(for: event)
            XCTAssertFalse(copy.title.isEmpty, "\(event) has no title")
            XCTAssertFalse(copy.body.isEmpty, "\(event) has no body")
            XCTAssertNotEqual(copy.title, copy.body, "\(event) says the same thing twice")
            titles.insert(copy.title)
        }
        XCTAssertEqual(titles.count, SessionNotificationEvent.allCases.count,
                       "two events sharing a title is one event the user cannot tell apart")
    }

    /// **The union-sensitivity rule, in the surface that states it most
    /// baldly.** `listSessions` is unfiltered and a Mac can have more than one
    /// person logged in, so "this Mac is no longer being kept awake" is a
    /// *negative* claim about the machine and is false the moment another
    /// account holds a session. The tracker deliberately still fires in that
    /// case (`testAnotherUsersLiveSessionDoesNotSuppressYours`), which is
    /// exactly why the sentence has to be scoped to the user's own sessions —
    /// the same discipline as `menuLidCaveat` and `WakeMode.lidCloseCaveat`.
    func testTheStopNotificationIsScopedToYourSessionsRatherThanToTheMac() {
        let copy = sessionNotificationCopy(for: .stoppedBeingKeptAwake)
        let text = (copy.title + " " + copy.body).lowercased()
        XCTAssertTrue(text.contains("you"),
                      "the claim is about your sessions, and has to say so: \(text)")
        for machineClaim in ["this mac will sleep", "this mac can sleep now",
                             "nothing is keeping this mac awake"] where text.contains(machineClaim) {
            XCTFail("another account's session may still be holding the Mac awake: \(text)")
        }
    }

    /// The positive claim, which the union can only strengthen, so the trigger
    /// event may make it flatly: a session of this user's has just started, so
    /// this Mac is being kept awake, whatever anybody else is doing.
    func testTheTriggerNotificationSaysWhatJustStartedHappening() {
        let copy = sessionNotificationCopy(for: .triggerStartedSession)
        XCTAssertTrue(copy.title.lowercased().contains("trigger"), copy.title)
        XCTAssertTrue((copy.title + " " + copy.body).lowercased().contains("awake"),
                      "what a session does is the reason anyone cares that one started")
    }

    /// Neither sentence may imply the app knows why anything happened, and the
    /// vocabulary of causes is what that would look like in prose. This is the
    /// string-level companion to the type-level guarantee — it is written over
    /// words a *human* sentence would actually use, which is what the
    /// `SafetyReason` raw values are not.
    func testNoNotificationExplainsWhyAnythingHappened() {
        let causes = ["because", "overheat", "too hot", "battery", "expired", "timed out",
                      "safety", "temperature", "thermal"]
        for event in SessionNotificationEvent.allCases {
            let copy = sessionNotificationCopy(for: event)
            let text = (copy.title + " " + copy.body).lowercased()
            for cause in causes where text.contains(cause) {
                XCTFail("\(event) names a cause: nothing outside the daemon knows one — \(text)")
            }
        }
    }
}

/// The two toggles' storage. Same discipline as `DefaultWakeModePreference`:
/// a distinct key each, named once, with the fallback named once beside it.
final class SessionNotificationPreferenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    func testEachToggleHasItsOwnKey() {
        XCTAssertNotEqual(SessionNotificationPreference.stopKey,
                          SessionNotificationPreference.triggerStartKey,
                          "two toggles sharing a key is two controls fighting over one value")
        for other in [DefaultSessionKindPreference.key, DefaultWakeModePreference.key,
                      DefaultKeepDisksAwakePreference.key, TriggerStore.key] {
            XCTAssertNotEqual(SessionNotificationPreference.stopKey, other)
            XCTAssertNotEqual(SessionNotificationPreference.triggerStartKey, other)
        }
    }

    /// **Off is not a taste, it is the mechanism.** Authorization is requested
    /// from exactly one place — a toggle being switched on — so a user who
    /// never turns one on is never asked for anything, and a test suite reading
    /// an empty suite can never construct the live conformer.
    func testBothFallBackToOff() {
        XCTAssertFalse(SessionNotificationPreference.fallback)
        let loaded = SessionNotificationPreference.load()
        XCTAssertFalse(loaded.onStop)
        XCTAssertFalse(loaded.onTriggerStart)
        XCTAssertFalse(loaded.wantsAnything)
    }

    func testEachToggleIsReadBackFromItsOwnKey() {
        PreferencesSuite.defaults.set(true, forKey: SessionNotificationPreference.stopKey)
        var loaded = SessionNotificationPreference.load()
        XCTAssertTrue(loaded.onStop)
        XCTAssertFalse(loaded.onTriggerStart)

        PreferencesSuite.defaults.set(true, forKey: SessionNotificationPreference.triggerStartKey)
        loaded = SessionNotificationPreference.load()
        XCTAssertTrue(loaded.onStop)
        XCTAssertTrue(loaded.onTriggerStart)
    }

    /// A stored value that is not a boolean falls back to off rather than to
    /// anything else.
    ///
    /// `DefaultKeepDisksAwakePreference` deliberately has no test like this and
    /// says so: `UserDefaults.bool(forKey:)` answers `false` for an absent key
    /// and for a non-boolean alike, so manufacturing one would be a test of
    /// `UserDefaults`. This is different, and the difference is
    /// `SessionNotificationPreference.load()` — the coercion is **this
    /// project's**, `object(forKey:) as? Bool ?? fallback`, so what is pinned
    /// here is which way that `??` falls. Off, in both directions: absence must
    /// not manufacture a notification nobody asked for, and — the reason this
    /// matters more here than anywhere else in the pane — a stored value that
    /// read as "on" would make the app ask a user for a notification grant they
    /// never requested.
    func testAnUnusableStoredValueFallsBackToOff() {
        for junk in ["banana", "true", "1"] {
            PreferencesSuite.defaults.set(junk, forKey: SessionNotificationPreference.stopKey)
            PreferencesSuite.defaults.set(junk,
                                          forKey: SessionNotificationPreference.triggerStartKey)
            let loaded = SessionNotificationPreference.load()
            XCTAssertFalse(loaded.onStop, "stored \"\(junk)\" must fall back")
            XCTAssertFalse(loaded.onTriggerStart, "stored \"\(junk)\" must fall back")
        }
    }

    /// Which toggle governs which event, exhaustively — so the pair cannot be
    /// wired up crossed, which is a Settings pane where turning one thing on
    /// silently enables the other.
    func testEachEventIsGovernedByItsOwnToggle() {
        let stopOnly = SessionNotificationPreferences(onStop: true, onTriggerStart: false)
        XCTAssertTrue(stopOnly.wants(.stoppedBeingKeptAwake))
        XCTAssertFalse(stopOnly.wants(.triggerStartedSession))

        let triggerOnly = SessionNotificationPreferences(onStop: false, onTriggerStart: true)
        XCTAssertFalse(triggerOnly.wants(.stoppedBeingKeptAwake))
        XCTAssertTrue(triggerOnly.wants(.triggerStartedSession))

        let neither = SessionNotificationPreferences(onStop: false, onTriggerStart: false)
        for event in SessionNotificationEvent.allCases {
            XCTAssertFalse(neither.wants(event), "\(event) fires with every toggle off")
        }
    }
}

/// The seam, exercised end to end with a fake in place of
/// `UNUserNotificationCenter` — which is the only way this can be tested at
/// all: `xcodebuild test` hosts the test bundle inside this very app, so a
/// real `requestAuthorization` here would raise a real dialog on whoever ran
/// the suite and leave a real row in System Settings → Notifications.
@MainActor
final class SessionNotifierTests: XCTestCase {
    /// Records instead of posting, and — the part that matters — *counts how
    /// many times it was built*, so "the live conformer is never constructed
    /// unless a toggle is on" is a thing a test can fail on rather than a thing
    /// a comment claims.
    private final class FakeNotificationService: NotificationPosting {
        private(set) var posted: [SessionNotificationCopy] = []
        var state: NotificationAuthorization = .authorized

        func authorizationState() async -> NotificationAuthorization { state }
        func requestAuthorization() async -> NotificationAuthorization { state }
        func post(title: String, body: String) {
            posted.append(SessionNotificationCopy(title: title, body: body))
        }
    }

    private let me = UInt32(getuid())

    private func session(id: UUID = UUID(), role: ClientRole = .app,
                         origin: SessionOrigin = .manual) -> Session {
        Session(id: id, kind: .indefinite, owner: role.clientID(forUserID: me), ownerUID: me,
                persistence: .detached, origin: origin,
                startedAt: Date(timeIntervalSince1970: 1_000_000),
                triggerID: origin == .trigger ? UUID() : nil,
                wakeMode: .clamshell, keepsDisksAwake: false)
    }

    private struct Harness {
        let notifier: SessionNotifier
        let service: FakeNotificationService
        /// How many times the notifier asked for a service. Zero is the
        /// assertion that matters with the toggles off.
        let builds: () -> Int
    }

    private func harness(_ preferences: SessionNotificationPreferences) -> Harness {
        let service = FakeNotificationService()
        let counter = Counter()
        let notifier = SessionNotifier(
            ownerUID: me,
            preferences: { preferences },
            makeService: {
                counter.value += 1
                return service
            })
        return Harness(notifier: notifier, service: service, builds: { counter.value })
    }

    private final class Counter { var value = 0 }

    private var everything: SessionNotificationPreferences {
        SessionNotificationPreferences(onStop: true, onTriggerStart: true)
    }

    private var nothing: SessionNotificationPreferences {
        SessionNotificationPreferences(onStop: false, onTriggerStart: false)
    }

    func testAnEndingIsPostedWithTheEventsOwnCopy() {
        let harness = self.harness(everything)
        let live = session()
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(harness.service.posted, [])
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    func testATriggerStartIsPostedWithTheEventsOwnCopy() {
        let harness = self.harness(everything)
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 1))
        harness.notifier.record(sessions: [session(role: .agent, origin: .trigger)],
                                now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .triggerStartedSession)])
    }

    /// **The guarantee the whole "never prompt" constraint rests on.** With
    /// both toggles off nothing is posted *and nothing is built* — so the
    /// `UNUserNotificationCenter` conformer is never constructed and cannot
    /// prompt, which is why an empty test suite is safe.
    func testWithEveryToggleOffNothingIsPostedAndNoServiceIsEverBuilt() {
        let harness = self.harness(nothing)
        let live = session()
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        harness.notifier.record(sessions: [session(role: .agent, origin: .trigger)],
                                now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(harness.service.posted, [])
        XCTAssertEqual(harness.builds(), 0,
                       "a service was constructed with every notification switched off")
    }

    /// One toggle on must not carry the other event with it.
    func testOnlyTheEnabledEventIsPosted() {
        let harness = self.harness(
            SessionNotificationPreferences(onStop: false, onTriggerStart: true))
        let live = session()
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted, [])
        harness.notifier.record(sessions: [session(role: .agent, origin: .trigger)],
                                now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .triggerStartedSession)])
    }

    /// The tracker is fed whether or not anything is switched on — the same
    /// rule `EvidenceLoopRunner` follows for the completion tracker, and for
    /// the same reason: turning a toggle on mid-session must not hand it a
    /// baseline from whenever the app last happened to look.
    ///
    /// Here the toggles are off for the two ticks that matter, so if the
    /// tracker had been skipped it would still have no baseline and the ending
    /// below would report nothing at all.
    func testTheBaselineIsKeptEvenWhileEveryToggleIsOff() {
        let service = FakeNotificationService()
        var preferences = SessionNotificationPreferences(onStop: false, onTriggerStart: false)
        let notifier = SessionNotifier(ownerUID: me, preferences: { preferences },
                                       makeService: { service })
        let live = session()
        notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        preferences = SessionNotificationPreferences(onStop: true, onTriggerStart: true)
        notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(service.posted, [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    /// The suppression, reached the way the menu reaches it.
    func testAStopThisAppAskedForPostsNothing() {
        let harness = self.harness(everything)
        let live = session()
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        harness.notifier.appWillStop(sessionIDs: [live.id], now: Date(timeIntervalSince1970: 2))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted, [])
        XCTAssertEqual(harness.builds(), 0, "nothing to post, so nothing to build")
    }

    func testALostConnectionDropsTheBaseline() {
        let harness = self.harness(everything)
        harness.notifier.record(sessions: [session(), session()],
                                now: Date(timeIntervalSince1970: 1))
        harness.notifier.forgetSnapshot()
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted, [])
    }
}

/// The live conformer's refusal, which is the belt to the preference gate's
/// braces.
///
/// This is the one test that touches `UserNotificationService` itself, and it
/// passes precisely because that type declines to call UserNotifications when
/// it detects XCTest. Without the refusal this test would raise a real system
/// dialog on whoever ran the suite — which is the failure it exists to make
/// impossible.
@MainActor
final class UserNotificationServiceRefusalTests: XCTestCase {
    func testItRefusesToTouchUserNotificationsUnderTest() async {
        XCTAssertTrue(PreferencesSuite.isRunningTests,
                      "this whole guard is keyed on detecting the test runner")
        let service = UserNotificationService()
        let state = await service.authorizationState()
        XCTAssertEqual(state, .notDetermined,
                       "under test it must answer without asking the system anything")
        // The call that would otherwise raise a dialog. It returns, and no
        // dialog appears, because the guard is checked before the framework.
        let afterRequest = await service.requestAuthorization()
        XCTAssertEqual(afterRequest, .notDetermined)
        // And a post that would otherwise land in the real Notification Center.
        service.post(title: "should never be delivered", body: "not during a test run")
    }
}

/// The grant, as this app models it.
final class NotificationAuthorizationTests: XCTestCase {
    /// `.ephemeral` is deliberately absent and `.unknown` is deliberately
    /// present. The SDK header on this machine is explicit —
    /// `UNAuthorizationStatusEphemeral API_AVAILABLE(ios(14.0))
    /// API_UNAVAILABLE(macos, watchos, tvos)`, "Only available to app clips" —
    /// so a macOS `switch` cannot name it and copy for it could never be read.
    /// `.unknown` is where `@unknown default` lands, which covers `.ephemeral`
    /// if it is ever brought to macOS *and* any sixth status a later OS adds,
    /// rather than one of the two.
    func testTheStatesAreTheOnesMacOSCanActuallyReport() {
        XCTAssertEqual(Set(NotificationAuthorization.allCases),
                       [.notDetermined, .denied, .authorized, .provisional, .unknown])
    }

    /// Mapped from the framework's own enum rather than from its raw values, so
    /// the mapping is an exhaustive `switch` the compiler checks rather than a
    /// second list of integers that has to agree with a header.
    func testEveryStatusMacOSDefinesMapsToItsOwnState() {
        XCTAssertEqual(NotificationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthorization(.denied), .denied)
        XCTAssertEqual(NotificationAuthorization(.authorized), .authorized)
        XCTAssertEqual(NotificationAuthorization(.provisional), .provisional)
    }
}
