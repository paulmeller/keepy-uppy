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
        XCTAssertEqual(tracker.record(current: [session(), triggerSession()], now: t0).events, [])
        XCTAssertTrue(tracker.hasSnapshot)
    }

    /// A daemon restart empties the table. Diffing across it would announce
    /// every live session at once. `forgetSnapshot()` on disconnect, the same
    /// trade as the agent's: a genuine ending during the outage is missed, and
    /// that is better than N false ones in one tick.
    func testALostConnectionDropsTheBaselineRatherThanAnnouncingEverything() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(), session()], now: t0).events
        tracker.forgetSnapshot()
        XCTAssertFalse(tracker.hasSnapshot)
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [])
    }

    /// ...and having forgotten, it re-primes and resumes reporting normally.
    func testForgettingThenRePrimingResumesNormalReporting() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0).events
        tracker.forgetSnapshot()
        let fresh = session()
        XCTAssertEqual(tracker.record(current: [fresh], now: t1).events, [])
        XCTAssertEqual(tracker.record(current: [], now: t2).events, [.stoppedBeingKeptAwake])
    }

    /// Another user's session is not this app's business to narrate — the same
    /// uid filter `SessionCompletionTracker(ownerUID: getuid())` applies, and
    /// for the same reason: one agent and one app per user, one unfiltered
    /// table.
    func testAnotherUsersSessionEndingSaysNothing() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(ownerUID: otherUser)], now: t0).events
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [])
    }

    /// It is "nothing of yours is keeping this Mac awake", not "a session
    /// ended". With two of yours running and one ending, nothing has stopped.
    func testEndingOneOfTwoSessionsSaysNothing() {
        var tracker = self.tracker()
        let staying = session()
        _ = tracker.record(current: [session(), staying], now: t0).events
        XCTAssertEqual(tracker.record(current: [staying], now: t1).events, [])
    }

    func testEndingTheLastSessionSaysSo() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0).events
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [.stoppedBeingKeptAwake])
    }

    /// ...and another user's live session does not suppress your notification,
    /// because the claim is about YOUR sessions. The copy is written so that
    /// this is not a lie about the machine — see
    /// `SessionNotificationCopyTests`, and the union-sensitivity argument
    /// `menuLidCaveat` and `wakeModeSettingsExplanation` are both built on.
    func testAnotherUsersLiveSessionDoesNotSuppressYours() {
        var tracker = self.tracker()
        let theirs = session(ownerUID: otherUser)
        _ = tracker.record(current: [session(), theirs], now: t0).events
        XCTAssertEqual(tracker.record(current: [theirs], now: t1).events, [.stoppedBeingKeptAwake])
    }

    /// A session that ends and is replaced in the same tick has not stopped
    /// keeping the Mac awake, so there is nothing to say — the transition is
    /// what is announced, never the individual ending.
    func testASessionReplacedInTheSameTickSaysNothingAboutStopping() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session()], now: t0).events
        XCTAssertEqual(tracker.record(current: [session()], now: t1).events, [])
    }

    /// An empty table that stays empty is not an event. Without the
    /// `previous.isEmpty` half of the transition test, every poll of an idle
    /// Mac would announce that it had stopped being kept awake.
    func testStayingIdleIsNotAnEvent() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [])
    }

    // MARK: - The trigger event

    func testATriggerStartedSessionIsAnnouncedWhenItAppears() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [triggerSession()], now: t1).events,
                       [.triggerStartedSession])
    }

    func testASessionYouStartedYourselfIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [session()], now: t1).events, [])
    }

    func testATriggerSessionOfAnotherUsersIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [triggerSession(ownerUID: otherUser)], now: t1).events, [])
    }

    /// `origin` is CLIENT-CHOSEN — `Session.authorized(id:owner:ownerUID:startedAt:)`
    /// lists it among the fields the daemon passes through untouched — so
    /// "a trigger started this" rests on the server-stamped `owner` as well.
    /// Same conjunction, same reason, as `menuSessionGroup`.
    func testASessionClaimingToBeATriggerFromANonAgentClientIsNotAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [session(role: .cli, origin: .trigger)], now: t1).events, [])
        _ = tracker.record(current: [], now: t2).events
        XCTAssertEqual(tracker.record(current: [session(role: .agent, origin: .manual)],
                                      now: t2.addingTimeInterval(3)).events, [])
        // ...and this app's own session claiming it, which is the one shape a
        // *genuine* Keepy Uppy could produce: `DaemonConnection.startSession`
        // takes the origin as a parameter. The menu row for such a session may
        // honestly say "started automatically" — it is this app describing its
        // own session — but a banner announcing "one of your rules started a
        // session" would be wrong, because no rule did.
        _ = tracker.record(current: [], now: t3).events
        XCTAssertEqual(tracker.record(current: [session(role: .app, origin: .trigger)],
                                      now: t3.addingTimeInterval(3)).events, [])
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
            _ = tracker.record(current: [], now: t0).events
            let announced = tracker.record(current: [candidate], now: t1).events
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
        _ = tracker.record(current: [], now: t0).events
        XCTAssertEqual(tracker.record(current: [triggerSession(), triggerSession()], now: t1).events,
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
        _ = tracker.record(current: [stopped], now: t0).events
        tracker.appWillStop(sessionIDs: [stopped.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [])
    }

    /// The menu's sweep row (`menuStopAllLabel`) stops several at once, and
    /// `stopAllSessions(all:)` replies with a count rather than with ids — so
    /// the call site snapshots the ids first, and every one of them is covered.
    func testStoppingSeveralAtOnceFromThisAppIsNotAnnounced() {
        var tracker = self.tracker()
        let a = session()
        let b = session()
        _ = tracker.record(current: [a, b], now: t0).events
        tracker.appWillStop(sessionIDs: [a.id, b.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [])
    }

    /// ...but a stop this app did NOT initiate is exactly the event worth
    /// having. `keepy-uppy off` in a Terminal, an expiry, a condition ending, a
    /// safety guard: from here they are indistinguishable, and all four are
    /// things that happened without the user touching this app.
    func testASessionStoppedFromTheCommandLineIsAnnounced() {
        var tracker = self.tracker()
        _ = tracker.record(current: [session(role: .cli)], now: t0).events
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [.stoppedBeingKeptAwake])
    }

    /// A tick in which the user stopped one session and another ended by
    /// itself still has news in it: something happened that nobody asked for.
    /// Suppression asks "was every ending mine?", not "was any ending mine?".
    func testAnEndingNobodyAskedForIsAnnouncedEvenAlongsideOneThisAppDid() {
        var tracker = self.tracker()
        let clicked = session()
        let expired = session(role: .cli)
        _ = tracker.record(current: [clicked, expired], now: t0).events
        tracker.appWillStop(sessionIDs: [clicked.id], now: t0)
        XCTAssertEqual(tracker.record(current: [], now: t1).events, [.stoppedBeingKeptAwake])
    }

    /// The suppression must not leak into the next tick and swallow a real
    /// ending: it is consumed by the one ending it was recorded for.
    func testSuppressionAppliesOnlyToTheEndingItWasFor() {
        var tracker = self.tracker()
        let clicked = session()
        let other = session()
        _ = tracker.record(current: [clicked, other], now: t0).events
        tracker.appWillStop(sessionIDs: [clicked.id], now: t0)
        // The clicked session goes; one of the user's is still live, so there
        // is nothing to announce either way.
        XCTAssertEqual(tracker.record(current: [other], now: t1).events, [])
        // The other one ends on its own a tick later, and that is news.
        XCTAssertEqual(tracker.record(current: [], now: t2).events, [.stoppedBeingKeptAwake])
    }

    /// A stop the daemon refused, or one that never took effect, must not
    /// suppress the session's real ending hours later. The mark is bounded, at
    /// a window comfortably wider than the 3s poll and the 5s call timeout it
    /// is racing and far narrower than any session.
    func testAStopThatNeverHappenedStopsSuppressingAfterItsWindow() {
        var tracker = self.tracker()
        let stubborn = session()
        _ = tracker.record(current: [stubborn], now: t0).events
        tracker.appWillStop(sessionIDs: [stubborn.id], now: t0)
        // Still there, tick after tick.
        let window = SessionNotificationTracker.stopSuppressionWindow
        XCTAssertEqual(tracker.record(current: [stubborn], now: t0.addingTimeInterval(3)).events, [])
        XCTAssertEqual(
            tracker.record(current: [], now: t0.addingTimeInterval(window + 1)).events,
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
        _ = tracker.record(current: [a], now: t0).events
        tracker.appWillStop(sessionIDs: [a.id], now: t0)
        tracker.forgetSnapshot()
        // Reconnected, same session still live, and it later ends by itself.
        XCTAssertEqual(tracker.record(current: [a], now: t1).events, [])
        XCTAssertEqual(tracker.record(current: [], now: t2).events, [.stoppedBeingKeptAwake])
    }

    // MARK: - The honesty test

    /// The TYPE-level guarantee, and it survived Plan 8 Task 6 intact — which
    /// was the constraint that decided the shape of the reason events.
    ///
    /// A notification may name only a reason the app was *given*, and the way to
    /// guarantee that is for the event to have nowhere to put one it invented.
    /// `SessionNotificationEvent`'s `CaseIterable` conformance is synthesized
    /// **only** for an enum whose cases all carry no associated values, so
    /// `case stoppedBySafetyGuard(SafetyReason)` does not build here — which is
    /// why there are three payload-free cases instead of one carrying a reason.
    /// The `Mirror` check is the same fact asserted at runtime, so the guarantee
    /// is visible in a failure message and not only in a compile error.
    ///
    /// The count is deliberately not pinned to a number any more: it is pinned
    /// to `SafetyReason.allCases`, so adding a reason without an event fails
    /// here, and adding an event nobody can reach fails the bijection test.
    func testTheNotificationEventCarriesNoReasonPayload() {
        for event in SessionNotificationEvent.allCases {
            XCTAssertTrue(Mirror(reflecting: event).children.isEmpty,
                          "\(event) carries a payload — a reason a notification could put in it "
                          + "is a reason nobody gave this app")
        }
        XCTAssertEqual(SessionNotificationEvent.allCases.count,
                       2 + SafetyReason.allCases.count,
                       "the two reason-free events, plus exactly one per safety reason")
    }
}

/// **The weld.** `SafetyReason` and the reason-carrying events are two
/// spellings of one list, and this is what keeps them that way — the same
/// arrangement `Tests/CLICommandTests.swift` puts between `SessionKind.Family`
/// and the CLI's flags.
final class SessionNotificationBijectionTests: XCTestCase {
    /// Forwards: every reason reaches an event, and back again unchanged.
    func testEveryReasonMapsToAnEventAndBack() {
        for reason in SafetyReason.allCases {
            let event = sessionNotificationEvent(for: reason)
            XCTAssertEqual(safetyReason(named: event), reason,
                           "\(reason) does not survive the round trip through its event")
        }
    }

    /// Backwards: every event that names a reason is reached by exactly one,
    /// and every event that names none is reached by no reason at all. This is
    /// the direction that catches an event nobody can produce.
    func testEveryReasonCarryingEventIsReachedByExactlyOneReason() {
        let reached = SafetyReason.allCases.map(sessionNotificationEvent(for:))
        XCTAssertEqual(Set(reached).count, SafetyReason.allCases.count,
                       "two reasons collapsed onto one event")

        for event in SessionNotificationEvent.allCases {
            guard let reason = safetyReason(named: event) else {
                XCTAssertFalse(reached.contains(event),
                               "\(event) claims to name no reason but a reason maps to it")
                continue
            }
            XCTAssertEqual(reached.filter { $0 == event }.count, 1,
                           "\(event) is reached by \(reason) and by something else")
        }
    }

    /// The reason-free events are exactly the two that existed before, named
    /// rather than counted — so a future event that quietly names no reason has
    /// to be added here on purpose.
    func testExactlyTwoEventsNameNoReason() {
        let reasonFree = SessionNotificationEvent.allCases.filter { safetyReason(named: $0) == nil }
        XCTAssertEqual(Set(reasonFree), [.stoppedBeingKeptAwake, .triggerStartedSession])
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

    /// **An event that carries no reason may not sound like it has one.**
    ///
    /// The string-level companion to the type-level guarantee, written over
    /// words a *human* sentence would actually use — which is what the
    /// `SafetyReason` raw values are not, and why the earlier draft of this
    /// test was vacuous.
    ///
    /// It is now scoped by `safetyReason(named:)` rather than run over every
    /// case, and that scoping is the honest half of the change: the reason
    /// events are *supposed* to name a cause, and the test immediately below
    /// requires them to. Together the pair say the whole rule — name a cause
    /// exactly when you were given one.
    func testAnEventWithNoReasonNamesNoCause() {
        let causes = ["because", "overheat", "too hot", "battery", "expired", "timed out",
                      "safety", "temperature", "thermal", "guard", "on its own", "by itself",
                      "nothing went wrong"]
        for event in SessionNotificationEvent.allCases where safetyReason(named: event) == nil {
            let copy = sessionNotificationCopy(for: event)
            let text = (copy.title + " " + copy.body).lowercased()
            for cause in causes where text.contains(cause) {
                XCTFail("\(event) names a cause it was never given — \(text)")
            }
        }
    }

    /// The distinctive word each reason's copy must contain, and — read across
    /// the three — must not borrow from another reason. Deliberately one tight
    /// token each rather than a list of near-synonyms: a generous list makes
    /// the cross-check below toothless, which is how a copy edit that swapped
    /// two banners would pass.
    private func distinctiveWord(for reason: SafetyReason) -> String {
        switch reason {
        case .thermal: return "hot"
        case .lowBattery: return "battery"
        case .maxDuration: return "time limit"
        }
    }

    /// **An event that carries a reason must say which**, in words, and must
    /// not say somebody else's. Over `allCases`, so a fourth reason cannot ship
    /// with a banner that names the wrong guard or none.
    func testEveryReasonEventNamesItsOwnGuardAndNoOther() {
        for reason in SafetyReason.allCases {
            let copy = sessionNotificationCopy(for: sessionNotificationEvent(for: reason))
            let text = (copy.title + " " + copy.body).lowercased()
            XCTAssertTrue(text.contains(distinctiveWord(for: reason)),
                          "\(reason)'s banner does not say which guard fired — \(text)")
            for other in SafetyReason.allCases where other != reason {
                XCTAssertFalse(text.contains(distinctiveWord(for: other)),
                               "\(reason)'s banner also names \(other) — \(text)")
            }
        }
    }

    /// Every stop sentence — reason-carrying or not — stays scoped to the
    /// user's own sessions. A thermal stop is machine-wide, so the temptation
    /// to say "this Mac will now sleep" is strongest exactly where it is most
    /// likely to be false: another account's session may still be holding it.
    func testEveryStopSentenceIsScopedToYourSessions() {
        let stopEvents = SessionNotificationEvent.allCases.filter { $0 != .triggerStartedSession }
        for event in stopEvents {
            let copy = sessionNotificationCopy(for: event)
            let text = (copy.title + " " + copy.body).lowercased()
            XCTAssertTrue(text.contains("you"), "\(event) does not scope its claim: \(text)")
            for machineClaim in ["this mac will sleep", "this mac can sleep now",
                                 "nothing is keeping this mac awake"] where text.contains(machineClaim) {
                XCTFail("\(event): another account may still hold this Mac awake — \(text)")
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

    /// Pairwise over all three, and against every other key in the suite —
    /// extended rather than duplicated, so a fourth toggle joins one loop.
    func testEachToggleHasItsOwnKey() {
        let mine = [SessionNotificationPreference.stopKey,
                    SessionNotificationPreference.triggerStartKey,
                    SessionNotificationPreference.safetyStopKey]
        for (index, key) in mine.enumerated() {
            for other in mine[(index + 1)...] {
                XCTAssertNotEqual(key, other,
                                  "two toggles sharing a key is two controls fighting over "
                                  + "one value")
            }
            for other in [DefaultSessionKindPreference.key, DefaultWakeModePreference.key,
                          DefaultKeepDisksAwakePreference.key, TriggerStore.key] {
                XCTAssertNotEqual(key, other)
            }
        }
    }

    /// **Off is not a taste, it is the mechanism.** Authorization is requested
    /// from exactly one place — a toggle being switched on — so a user who
    /// never turns one on is never asked for anything, and a test suite reading
    /// an empty suite can never construct the live conformer.
    func testAllThreeFallBackToOff() {
        XCTAssertFalse(SessionNotificationPreference.fallback)
        let loaded = SessionNotificationPreference.load()
        XCTAssertFalse(loaded.onStop)
        XCTAssertFalse(loaded.onTriggerStart)
        XCTAssertFalse(loaded.onSafetyStop)
        XCTAssertFalse(loaded.wantsAnything)
    }

    func testEachToggleIsReadBackFromItsOwnKey() {
        PreferencesSuite.defaults.set(true, forKey: SessionNotificationPreference.stopKey)
        var loaded = SessionNotificationPreference.load()
        XCTAssertTrue(loaded.onStop)
        XCTAssertFalse(loaded.onTriggerStart)
        XCTAssertFalse(loaded.onSafetyStop)

        PreferencesSuite.defaults.set(true, forKey: SessionNotificationPreference.triggerStartKey)
        loaded = SessionNotificationPreference.load()
        XCTAssertTrue(loaded.onStop)
        XCTAssertTrue(loaded.onTriggerStart)
        XCTAssertFalse(loaded.onSafetyStop)

        PreferencesSuite.defaults.set(true, forKey: SessionNotificationPreference.safetyStopKey)
        loaded = SessionNotificationPreference.load()
        XCTAssertTrue(loaded.onStop)
        XCTAssertTrue(loaded.onTriggerStart)
        XCTAssertTrue(loaded.onSafetyStop)
        XCTAssertTrue(loaded.wantsAnything)
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
            PreferencesSuite.defaults.set(junk,
                                          forKey: SessionNotificationPreference.safetyStopKey)
            let loaded = SessionNotificationPreference.load()
            XCTAssertFalse(loaded.onStop, "stored \"\(junk)\" must fall back")
            XCTAssertFalse(loaded.onTriggerStart, "stored \"\(junk)\" must fall back")
            XCTAssertFalse(loaded.onSafetyStop, "stored \"\(junk)\" must fall back")
        }
    }

    /// Which toggle governs which event, exhaustively — so the pair cannot be
    /// wired up crossed, which is a Settings pane where turning one thing on
    /// silently enables the other.
    func testEachEventIsGovernedByItsOwnToggle() {
        let stopOnly = SessionNotificationPreferences(onStop: true, onTriggerStart: false,
                                                      onSafetyStop: false)
        XCTAssertTrue(stopOnly.wants(.stoppedBeingKeptAwake))
        XCTAssertFalse(stopOnly.wants(.triggerStartedSession))

        let triggerOnly = SessionNotificationPreferences(onStop: false, onTriggerStart: true,
                                                         onSafetyStop: false)
        XCTAssertFalse(triggerOnly.wants(.stoppedBeingKeptAwake))
        XCTAssertTrue(triggerOnly.wants(.triggerStartedSession))

        let nothingAtAll = SessionNotificationPreferences(onStop: false, onTriggerStart: false,
                                                          onSafetyStop: false)
        for event in SessionNotificationEvent.allCases {
            XCTAssertFalse(nothingAtAll.wants(event), "\(event) fires with every toggle off")
        }
    }

    /// **One toggle governs every reason case, and only the reason cases.**
    /// Written over `SafetyReason.allCases` through the weld rather than over
    /// three hand-named events, so a fourth reason cannot ship governed by
    /// nothing.
    func testTheOneSafetyToggleGovernsEveryReasonAndNothingElse() {
        let safetyOnly = SessionNotificationPreferences(onStop: false, onTriggerStart: false,
                                                        onSafetyStop: true)
        for reason in SafetyReason.allCases {
            XCTAssertTrue(safetyOnly.wants(sessionNotificationEvent(for: reason)),
                          "\(reason) has no toggle")
        }
        XCTAssertFalse(safetyOnly.wants(.stoppedBeingKeptAwake),
                       "the safety toggle switched on the plain notice too")
        XCTAssertFalse(safetyOnly.wants(.triggerStartedSession))

        let withoutSafety = SessionNotificationPreferences(onStop: true, onTriggerStart: true,
                                                           onSafetyStop: false)
        for reason in SafetyReason.allCases {
            XCTAssertFalse(withoutSafety.wants(sessionNotificationEvent(for: reason)),
                           "\(reason) fires with the safety toggle off")
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
        /// How many times the notifier asked the daemon *why*. Zero is the
        /// assertion that matters whenever the safety toggle is off — that is
        /// what keeps a new XPC verb off the wire for users who never opted in.
        let asks: () -> Int
    }

    /// `records` is what the daemon would have replied. `[]` — the default — is
    /// every way a reason can be unavailable at once: an older daemon, a failed
    /// call, an evicted record, and an ending no guard was behind. They are the
    /// same value here because they are the same answer.
    private func harness(_ preferences: SessionNotificationPreferences,
                         records: [SafetyStopRecord] = []) -> Harness {
        let service = FakeNotificationService()
        let counter = Counter()
        let asked = Counter()
        let notifier = SessionNotifier(
            ownerUID: me,
            preferences: { preferences },
            makeService: {
                counter.value += 1
                return service
            },
            safetyStops: {
                asked.value += 1
                return records
            })
        return Harness(notifier: notifier, service: service, builds: { counter.value },
                       asks: { asked.value })
    }

    private final class Counter { var value = 0 }

    /// All three on.
    private var everything: SessionNotificationPreferences {
        SessionNotificationPreferences(onStop: true, onTriggerStart: true, onSafetyStop: true)
    }

    /// The Plan 7 shape: told when things stop, never told why. The whole stop
    /// path stays synchronous here, because the reason is not asked for at all.
    private var withoutReasons: SessionNotificationPreferences {
        SessionNotificationPreferences(onStop: true, onTriggerStart: true, onSafetyStop: false)
    }

    private var nothing: SessionNotificationPreferences {
        SessionNotificationPreferences(onStop: false, onTriggerStart: false, onSafetyStop: false)
    }

    /// One safety stop record for each of `sessions`, all naming `reason`.
    private func records(for sessions: [Session], reason: SafetyReason,
                         ownerUID: UInt32? = nil) -> [SafetyStopRecord] {
        sessions.map {
            SafetyStopRecord(sessionID: $0.id, ownerUID: ownerUID ?? $0.ownerUID,
                             reason: reason, endedAt: Date(timeIntervalSince1970: 3))
        }
    }

    func testAnEndingIsPostedWithTheEventsOwnCopy() {
        let harness = self.harness(withoutReasons)
        let live = session()
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(harness.service.posted, [])
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
        XCTAssertEqual(harness.asks(), 0,
                       "the reason was asked for with the safety toggle switched off")
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
            SessionNotificationPreferences(onStop: false, onTriggerStart: true,
                                           onSafetyStop: false))
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
        var preferences = SessionNotificationPreferences(onStop: false, onTriggerStart: false,
                                                         onSafetyStop: false)
        let notifier = SessionNotifier(ownerUID: me, preferences: { preferences },
                                       makeService: { service }, safetyStops: { [] })
        let live = session()
        notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        preferences = SessionNotificationPreferences(onStop: true, onTriggerStart: true,
                                                     onSafetyStop: false)
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

    // MARK: - Plan 8 Task 7: the reason, end to end

    /// Drives one live session to zero and settles the deferred round trip.
    private func endTheLastSession(_ harness: Harness, _ live: Session) async {
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        // Awaited rather than yielded a hopeful number of times: the reason
        // arrives over a round trip, and a test that guesses how long that takes
        // passes on a quiet machine and fails on a loaded one.
        await harness.notifier.reasonQuery?.value
    }

    /// **The reason REPLACES the reason-free event; it never accompanies it.**
    /// A safety stop is a `.stopAll`, so the snapshot that gains a reason is the
    /// same one that trips `.stoppedBeingKeptAwake` — posting both is two
    /// banners for one event. Asserted as the *whole* posted list, so an extra
    /// banner fails rather than hiding behind a `contains`.
    func testASafetyStopPostsTheReasonInsteadOfThePlainNotice() async {
        let live = session()
        let harness = self.harness(everything, records: records(for: [live], reason: .thermal))
        await endTheLastSession(harness, live)

        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedByThermalGuard)])
        XCTAssertEqual(harness.asks(), 1, "the reason was asked for more than once")
    }

    /// Every reason, not just the one the author picked — so a reason wired to
    /// the wrong banner fails here rather than in somebody's Notification
    /// Center.
    func testEveryReasonReachesItsOwnBanner() async {
        for reason in SafetyReason.allCases {
            let live = session()
            let harness = self.harness(everything, records: records(for: [live], reason: reason))
            await endTheLastSession(harness, live)
            XCTAssertEqual(harness.service.posted,
                           [sessionNotificationCopy(for: sessionNotificationEvent(for: reason))],
                           "\(reason) did not reach its own banner")
        }
    }

    // MARK: - ...and the three ways it can be unavailable, which all say the same thing

    /// **1. The daemon is too old to be asked.** `DaemonConnection` answers `[]`
    /// without sending anything (`SafetyStopVerbGate`), which arrives here as an
    /// empty reply — indistinguishable, on purpose, from the other two.
    func testAnOldDaemonPostsThePlainNotice() async {
        let live = session()
        let harness = self.harness(everything, records: [])
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    /// **2. The record aged out or was evicted.** The daemon replies, but not
    /// about this session — which is exactly what a five-minute-old episode
    /// looks like once its records have gone.
    func testAnEvictedRecordPostsThePlainNotice() async {
        let live = session()
        let somebodyElsesEpisode = records(for: [session()], reason: .lowBattery)
        let harness = self.harness(everything, records: somebodyElsesEpisode)
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    /// **3. No guard was behind it at all** — a lease expired, or somebody typed
    /// `keepy-uppy off`. The daemon has records, and none of them is about this.
    ///
    /// This is the one the honesty rule is really about: the app must not
    /// upgrade "I have no record of a guard" into "nothing went wrong". The copy
    /// posted is the reason-free one, which states no cause and implies none.
    func testAnOrdinaryEndingPostsThePlainNotice() async {
        let live = session()
        let stale = SafetyStopRecord(sessionID: UUID(), ownerUID: me, reason: .maxDuration,
                                     endedAt: Date(timeIntervalSince1970: 0))
        let harness = self.harness(everything, records: [stale])
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    /// With the reason toggle off the verb is never even sent, and the Plan 7
    /// behaviour is byte-for-byte what it was.
    func testWithTheReasonToggleOffNothingIsEverAsked() async {
        let live = session()
        let harness = self.harness(withoutReasons,
                                   records: records(for: [live], reason: .thermal))
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.asks(), 0,
                       "a user who did not opt in put a new XPC verb on the wire")
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedBeingKeptAwake)])
    }

    /// Reason on, plain notice off: the reason is posted when there is one...
    func testWithOnlyTheReasonToggleOnTheReasonIsStillPosted() async {
        let live = session()
        let harness = self.harness(
            SessionNotificationPreferences(onStop: false, onTriggerStart: false,
                                           onSafetyStop: true),
            records: records(for: [live], reason: .lowBattery))
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedByLowBattery)])
    }

    /// ...and nothing is posted when there is not, because the plain notice is
    /// the one the user switched off. Posting it anyway would be this app
    /// answering a question with a notification nobody asked for.
    func testWithOnlyTheReasonToggleOnAnUnattributableEndingIsSilent() async {
        let live = session()
        let harness = self.harness(
            SessionNotificationPreferences(onStop: false, onTriggerStart: false,
                                           onSafetyStop: true),
            records: [])
        await endTheLastSession(harness, live)
        XCTAssertEqual(harness.service.posted, [])
        XCTAssertEqual(harness.builds(), 0, "nothing to post, so nothing to build")
    }

    // MARK: - The interaction with Task 5's suppression

    /// **A stop this app asked for stays silent, reason or no reason.** The
    /// suppression governs the transition, and the reason event is a relabelling
    /// of that same transition rather than a second path around it — so a record
    /// naming a session this app stopped must not resurrect the banner.
    ///
    /// The record here is deliberately genuine and matching. The only thing
    /// keeping this quiet is that the transition never produced an event to
    /// relabel.
    func testAStopThisAppAskedForStaysSilentEvenWithAMatchingRecord() async {
        let live = session()
        let harness = self.harness(everything, records: records(for: [live], reason: .thermal))
        harness.notifier.record(sessions: [live], now: Date(timeIntervalSince1970: 1))
        harness.notifier.appWillStop(sessionIDs: [live.id], now: Date(timeIntervalSince1970: 2))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        await harness.notifier.reasonQuery?.value

        XCTAssertEqual(harness.service.posted, [])
        XCTAssertEqual(harness.asks(), 0,
                       "a suppressed transition still asked the daemon why")
        XCTAssertEqual(harness.builds(), 0)
    }

    /// One ending this app asked for, one it did not, and a record for the
    /// second. The suppression removes the first from the set to be explained,
    /// so the second is fully explained and the reason is named.
    func testAnUnrequestedEndingBesideARequestedOneIsStillAttributed() async {
        let clicked = session()
        let guarded = session()
        let harness = self.harness(everything, records: records(for: [guarded], reason: .maxDuration))
        harness.notifier.record(sessions: [clicked, guarded], now: Date(timeIntervalSince1970: 1))
        harness.notifier.appWillStop(sessionIDs: [clicked.id], now: Date(timeIntervalSince1970: 2))
        harness.notifier.record(sessions: [], now: Date(timeIntervalSince1970: 4))
        await harness.notifier.reasonQuery?.value

        XCTAssertEqual(harness.service.posted,
                       [sessionNotificationCopy(for: .stoppedByMaxDuration)])
    }
}

/// The attribution rule on its own — pure, so every edge is cheap to state.
final class AttributedStopEventTests: XCTestCase {
    private let me: UInt32 = 501
    private let other: UInt32 = 502
    private let when = Date(timeIntervalSince1970: 1_000)

    private func record(_ id: UUID, uid: UInt32? = nil,
                        _ reason: SafetyReason) -> SafetyStopRecord {
        SafetyStopRecord(sessionID: id, ownerUID: uid ?? me, reason: reason, endedAt: when)
    }

    func testNoEndingsMeansNothingToAttribute() {
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [], records: [], ownerUID: me),
                       .stoppedBeingKeptAwake)
    }

    func testAnExplainedEndingIsNamed() {
        let id = UUID()
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [id],
                                           records: [record(id, .thermal)], ownerUID: me),
                       .stoppedByThermalGuard)
    }

    /// **Another account's record explains nothing of yours**, even for the
    /// same episode: the reply is unfiltered by design, so the uid filter is
    /// applied here, on the way in.
    func testARecordBelongingToAnotherAccountIsNotYourExplanation() {
        let id = UUID()
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [id],
                                           records: [record(id, uid: other, .thermal)],
                                           ownerUID: me),
                       .stoppedBeingKeptAwake)
    }

    /// **Attribution is by id, never by recency.** The daemon keeps records for
    /// five minutes, so a window-based match would happily explain a lease that
    /// expired by itself shortly after a real thermal stop.
    func testARecordForADifferentSessionExplainsNothing() {
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [UUID()],
                                           records: [record(UUID(), .lowBattery)], ownerUID: me),
                       .stoppedBeingKeptAwake)
    }

    /// **Partial attribution is the polite version of guessing.** A guard that
    /// ended one of two sessions did not stop "your sessions".
    func testAnEndingLeftUnexplainedFallsBackForAllOfThem() {
        let explained = UUID()
        let unexplained = UUID()
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [explained, unexplained],
                                           records: [record(explained, .thermal)], ownerUID: me),
                       .stoppedBeingKeptAwake)
    }

    func testEveryEndingExplainedByTheSameReasonIsNamed() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [a, b],
                                           records: [record(a, .lowBattery),
                                                     record(b, .lowBattery)],
                                           ownerUID: me),
                       .stoppedByLowBattery)
    }

    /// Two reasons and no honest way to pick one, so it names neither.
    func testDisagreeingReasonsNameNeither() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(attributedStopEvent(endedUnrequested: [a, b],
                                           records: [record(a, .thermal),
                                                     record(b, .maxDuration)],
                                           ownerUID: me),
                       .stoppedBeingKeptAwake)
    }

    /// Whatever it answers is a reason-free event or one of the reason events —
    /// never `.triggerStartedSession`, which would be this function reaching
    /// into a different question entirely.
    func testItOnlyEverAnswersWithAStopEvent() {
        for reason in SafetyReason.allCases {
            let id = UUID()
            let event = attributedStopEvent(endedUnrequested: [id],
                                            records: [record(id, reason)], ownerUID: me)
            XCTAssertNotEqual(event, .triggerStartedSession)
            XCTAssertEqual(safetyReason(named: event), reason)
        }
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
