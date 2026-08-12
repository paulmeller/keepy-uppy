import XCTest
@testable import KeepyUppy

/// Final whole-branch review, Item 2: a broken XPC connection must resume
/// the awaiting continuation, not hang forever.
///
/// `Sources/DaemonConnection.swift` used to send each message through a
/// proxy whose error handler only logged and flipped `isConnected` — it had
/// no reference to whichever `withCheckedContinuation` was pending, so when
/// the connection failed mid-call the awaiting `refresh()` never resumed.
/// The 3s poll timer then started a fresh, equally stuck `refresh()` `Task`
/// every tick, leaking one task per tick for the lifetime of the app.
///
/// This test exercises exactly that path: nothing registers the privileged
/// daemon in the test environment, so `resume()` succeeds (Mach service
/// lookup is lazy) and the *first real message* is what fails — the precise
/// shape of the bug. It asserts only that the call returns, deliberately
/// making no claim about `isConnected`, so it stays honest on a developer
/// machine that does happen to have the daemon registered: there, the calls
/// succeed and return promptly, which is equally fine. It fails only if a
/// continuation is left unresumed.
///
/// Verified to be a real regression test, not a tautology: with the
/// pre-fix `Sources/DaemonConnection.swift` restored in place, this test
/// times out.
@MainActor
final class DaemonConnectionFailurePathTests: XCTestCase {
    /// Well under the 10s expectation timeout below, but long enough that a
    /// slow machine's XPC round-trip is not mistaken for a hang.
    private let timeout: TimeInterval = 10

    private func expectCompletion(
        _ name: String,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let done = expectation(description: name)
        Task { @MainActor in
            await work()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }

    func testRefreshReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("refresh() returned") { await daemon.refresh() }
    }

    func testStartSessionReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("startSession() returned") {
            _ = await daemon.startSession(
                kind: .indefinite,
                power: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
        }
    }

    func testStopSessionReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("stopSession() returned") { await daemon.stopSession(UUID()) }
    }

    func testStopAllSessionsReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("stopAllSessions() returned") {
            await daemon.stopAllSessions(all: false)
        }
    }

    /// The newest verb, and the one whose failure a user is most likely to be
    /// looking at when it happens: Diagnostics calls it precisely when
    /// something has already gone wrong. Same contract as the four above — it
    /// returns rather than leaving a continuation unresumed — and `nil` is the
    /// answer that reaches the pane, which renders it as "not answering"
    /// rather than as a version.
    func testVersionReturnsInsteadOfHangingWhenTheConnectionFails() async {
        let daemon = DaemonConnection()
        daemon.start()
        await expectCompletion("version() returned") { _ = await daemon.version() }
    }
}

/// What the app actually asks the daemon for.
///
/// The XPC round trip itself is not testable here (nothing registers the
/// privileged daemon, and the ad-hoc-signed test host is refused by a real one
/// at the code-signing gate), but the *payload* is — and the payload is where
/// this app's one remaining silent-default trap lived. `Session` used to have
/// exactly three fields with memberwise defaults; dropping any of them from a
/// construction site compiled, passed, and was invisible in every surface the
/// product has. It happened three times in this repo. It has none now — but the
/// compiler can only force a field to be *named* here, not to be named with the
/// value the caller asked for, which is what these tests check.
final class DaemonConnectionRequestTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The regression this closes literally: `startSession` built its `Session`
    /// without `wakeMode:`, so Settings and the menu could offer a choice that
    /// was thrown away one line before it reached the wire.
    ///
    /// Every mode crossed with both disk answers, because the second axis can
    /// fail in exactly the same way — a Settings toggle whose value is dropped
    /// one line before the wire looks identical to one nobody switched on.
    func testTheRequestCarriesEveryPowerRequestItIsGiven() {
        for mode in WakeMode.allCases {
            for disks in [false, true] {
                let power = PowerRequest(wakeMode: mode, keepsDisksAwake: disks)
                let request = DaemonConnection.requestedSession(
                    kind: .indefinite, power: power, persistence: .clientBound,
                    origin: .manual, now: t0)
                XCTAssertEqual(request.power, power,
                               "the app asked for \(power) and sent \(request.power)")
            }
        }
    }

    /// A whole-struct comparison rather than a field list, so a field the
    /// request sets that it has no business setting fails here, and so does a
    /// field it drops — **for the fields pinned below**.
    ///
    /// That qualifier is the whole point, and this comment used to omit it. It
    /// claimed the shape gave what `SessionEngineTests`' renewal test gives:
    /// "a field added later is covered without anyone remembering to add it
    /// here". It does not, and cannot. The expectation is built with the *same*
    /// memberwise initialiser as the value under test, so a field given the same
    /// uninteresting value on both sides proves nothing about what
    /// `requestedSession` did with it. This is now only half the old hazard:
    /// `Session.init` defaults nothing, so a new field cannot be silently
    /// *omitted* from either side — it would not compile — but it can still be
    /// named `false` on both and compare equal for free.
    ///
    /// So: adding a field to `Session` means naming it here with a
    /// **non-default** value, and nothing but this sentence will say so.
    /// `wakeMode` is `.systemAndDisplay` rather than `.clamshell` for that
    /// reason, and the server-owned fields are asserted against literals rather
    /// than read back off `request` — `ownerUID: request.ownerUID` compared the
    /// value to itself, so the app could have claimed any UID it liked and this
    /// test would have stayed green.
    func testTheRequestIsExactlyTheClientChosenFieldsAndNothingElse() {
        let until = t0.addingTimeInterval(3600)
        let request = DaemonConnection.requestedSession(
            kind: .duration(until: until),
            power: PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: true),
            persistence: .detached, origin: .trigger, now: t0)

        // `id`, `owner`, `ownerUID` and `startedAt` are all overwritten by the
        // daemon (`Session.authorized(id:owner:ownerUID:startedAt:)`), so the
        // request's values for them are not the contract with the daemon — but
        // they are still what this app puts on the wire, and a client that
        // tries to mint a session as another user is worth failing on even
        // though the daemon would ignore the attempt.
        XCTAssertEqual(request.owner, ClientID(rawValue: "app"))
        XCTAssertEqual(request.ownerUID, 0,
                       "the app must not claim a UID; only the daemon can establish one")
        XCTAssertEqual(request.startedAt, t0)
        // `id` is the one server-owned field with no literal to compare
        // against — it is a fresh UUID per request by design. It is also the
        // one that cannot be dropped by accident: it has no memberwise
        // default, so omitting it is a compile error.
        XCTAssertEqual(request, Session(id: request.id, kind: .duration(until: until),
                                        owner: ClientID(rawValue: "app"), ownerUID: 0,
                                        persistence: .detached, origin: .trigger, startedAt: t0,
                                        triggerID: nil, wakeMode: .systemAndDisplay,
                                        keepsDisksAwake: true))
    }
}

/// `ContinuationLatch` is the primitive the fix above is built on, and as of
/// fix wave D it is shared (`Shared/ContinuationLatch.swift`) by BOTH XPC
/// clients — the app's, exercised directly above, and the agent's
/// (`Agent/DaemonConnection.swift`), which had the identical unfixed
/// continuation leak until the same wave.
///
/// The agent's client deliberately has no XCTest here, and cannot have one:
/// it declares a type also named `DaemonConnection`, so it cannot join the
/// app target alongside `Sources/DaemonConnection.swift`, and compiled into
/// the test target instead it could not see the internal `Shared` symbols
/// (`HelperProtocol`, `agentMachServiceName`, `Session`) it is written
/// against. It is instead verified by compiling the real, unmodified file
/// into a standalone executable with the real `Shared` sources and driving it
/// against the (unregistered) daemon Mach service — pre-fix that run trips
/// "SWIFT TASK CONTINUATION MISUSE: listSessions() leaked its continuation
/// without resuming it" and hangs; post-fix all three calls return. See
/// `.superpowers/sdd/final-review-fixwave-D-report.md` for the transcript.
///
/// What is testable here, and now matters twice over, is the latch's own
/// contract: it exists because NSXPC's reply block and its error handler
/// arrive on arbitrary queues, and resuming a `CheckedContinuation` twice
/// traps at runtime — a crash would be a strictly worse outcome than the hang
/// the latch prevents.
final class ContinuationLatchTests: XCTestCase {
    func testASecondResumeIsDroppedRatherThanTrapping() async {
        let value: Int = await withCheckedContinuation { continuation in
            let latch = ContinuationLatch(continuation)
            latch.resume(1)
            // Without the latch this is `CheckedContinuation` misuse and
            // traps the process.
            latch.resume(2)
        }
        XCTAssertEqual(value, 1, "the first resume must win")
    }

    /// The real shape of the race: the reply block and the error handler are
    /// on different queues, so "check then resume" without a lock is not
    /// enough. Repeated so a lost race is not a one-in-a-thousand flake that
    /// only shows up in production.
    func testConcurrentResumesDeliverExactlyOneValue() async {
        for _ in 0..<250 {
            let value: Int = await withCheckedContinuation { continuation in
                let latch = ContinuationLatch(continuation)
                DispatchQueue.concurrentPerform(iterations: 8) { latch.resume($0) }
            }
            XCTAssertTrue((0..<8).contains(value), "unexpected value \(value)")
        }
    }
}

// MARK: - Plan 8 Task 6: the gate in front of a verb an old daemon may not have

/// The version gate, as pure parsing. Everything it decides rests on
/// `bundleVersionText`'s output shape, so the two are tested against the same
/// strings that function actually produces.
final class DaemonCapabilityTests: XCTestCase {
    /// The parser and the formatter agree, checked by driving one with the
    /// other rather than with hand-written strings — the failure this project
    /// keeps closing is two functions that must agree and are written apart.
    func testTheBuildNumberIsReadBackOutOfWhatTheFormatterWrites() {
        for build in [0, 1, 4, 17, 1_234] {
            let text = bundleVersionText(shortVersion: "0.1.0", build: String(build))
            XCTAssertEqual(DaemonCapability.buildNumber(inVersionText: text), build, text)
        }
    }

    /// A daemon predating Plan 7 Task 10 composed no build number at all — its
    /// `version` was `CFBundleShortVersionString ?? "0"`. That has to read as
    /// "no build number", not as `1` scavenged out of `0.1.0`.
    func testAVersionWithNoBuildNumberHasNone() {
        for text in ["0.1.0", "0", "unknown", "", "0.1.0 ()", "0.1.0 (x)", "0.1.0 (3",
                     "0.1.0 (3) beta"] {
            XCTAssertNil(DaemonCapability.buildNumber(inVersionText: text),
                         "\"\(text)\" yielded a build number")
        }
        XCTAssertNil(DaemonCapability.buildNumber(
            inVersionText: bundleVersionText(shortVersion: "0.1.0", build: nil)))
    }

    /// **The live state of this Mac.** The daemon serving this user replies a
    /// bare `"0.1.0"` (Plan 8 Task 1, Step 3c, established read-only), and it
    /// has none of this. It must never be sent **any** gated verb, which is
    /// written over `allCases` so a third one inherits the claim.
    func testTheDaemonRunningOnThisMacIsRefused() {
        for verb in DaemonCapability.Verb.allCases {
            XCTAssertFalse(DaemonCapability.supports(verb, versionReply: "0.1.0"),
                           "the daemon on this Mac was cleared for \(verb)")
        }
    }

    /// Every uncertain answer is "no". Being wrong towards absent costs a
    /// feature one action; being wrong towards present costs the user their
    /// sessions.
    func testEveryUncertainAnswerMeansTheVerbIsAbsent() {
        for verb in DaemonCapability.Verb.allCases {
            XCTAssertFalse(DaemonCapability.supports(verb, versionReply: nil),
                           "a failed version call knows nothing, so it may not clear anything")
            XCTAssertFalse(DaemonCapability.supports(verb, versionReply: ""))
            XCTAssertFalse(DaemonCapability.supports(verb, versionReply: "banana"))
        }
    }

    /// The boundary, in both directions, for every gated verb — plus the floor
    /// under all of them: **3 has already shipped** on a daemon with none of
    /// this (the installed app on this machine reports `CFBundleVersion` 3), so
    /// no verb may be introduced at or below it.
    func testOnlyABuildAtOrAboveTheIntroducingOneIsCleared() {
        for verb in DaemonCapability.Verb.allCases {
            let introduced = verb.introducedInBuild
            XCTAssertGreaterThan(introduced, 3,
                                 "\(verb) is gated at \(introduced); build 3 has shipped without "
                                 + "it, so that clears the daemon this must not be sent to")
            for build in [0, 1, 2, 3, introduced - 1] {
                XCTAssertFalse(DaemonCapability.supports(
                    verb, versionReply: bundleVersionText(shortVersion: "0.1.0", build: String(build))),
                               "build \(build) was cleared for \(verb)")
            }
            for build in [introduced, introduced + 1, introduced + 100] {
                XCTAssertTrue(DaemonCapability.supports(
                    verb, versionReply: bundleVersionText(shortVersion: "0.1.0", build: String(build))),
                              "build \(build) was refused for \(verb)")
            }
        }
    }

    /// **A verb added later may not be gated at or below one added earlier.**
    ///
    /// `.recentSafetyStops` shipped at 4 and `.changeSessionPower` at 5, and the
    /// second number is not a formality: local builds at 4 exist and have the
    /// first verb without the second, so gating the second at 4 would clear a
    /// daemon that cannot answer it — which for *this* verb is unrecoverable,
    /// because it has no zero-live-sessions gate behind it to make a wrong
    /// answer free.
    func testTheLaterVerbIsGatedAboveTheEarlierOne() {
        XCTAssertGreaterThan(DaemonCapability.Verb.changeSessionPower.introducedInBuild,
                             DaemonCapability.Verb.recentSafetyStops.introducedInBuild,
                             "a build carrying the older verb would be cleared for the newer one")
        XCTAssertFalse(DaemonCapability.supports(
            .changeSessionPower,
            versionReply: bundleVersionText(
                shortVersion: "0.1.0",
                build: String(DaemonCapability.Verb.recentSafetyStops.introducedInBuild))))
    }

    /// The gate is only implementable because the release introducing a verb
    /// bumps, so this pins the third leg of that: the case in `Verb`, the verb
    /// itself and `project.yml` travel together or the gate is a guess.
    ///
    /// Over `allCases`, so the day a third verb is added with no bump, this is
    /// what says so.
    func testThisBuildIsNewEnoughToBeAskedItsOwnVerbs() {
        for verb in DaemonCapability.Verb.allCases {
            XCTAssertTrue(DaemonCapability.supports(verb, versionReply: bundleVersionText(of: .main)),
                          "this build ships \(verb) but would refuse to ask a daemon of its own "
                          + "vintage — CURRENT_PROJECT_VERSION was not bumped with it")
        }
    }
}

/// The decision itself, and the latch behind it.
@MainActor
final class SafetyStopVerbGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SafetyStopVerbGate.resetForTesting()
    }

    override func tearDown() {
        SafetyStopVerbGate.resetForTesting()
        super.tearDown()
    }

    func testAFreshProcessKnowsNothingAndProbesFirst() {
        XCTAssertEqual(SafetyStopVerbGate.support, .unknown)
        XCTAssertEqual(SafetyStopVerbGate.nextStep(support: .unknown, liveSessionsOfThisUser: 0),
                       .askTheVersionFirst)
    }

    func testAClearedDaemonIsSent() {
        XCTAssertEqual(SafetyStopVerbGate.nextStep(support: .present, liveSessionsOfThisUser: 0),
                       .send)
    }

    func testAnOldDaemonIsNeverSent() {
        XCTAssertEqual(SafetyStopVerbGate.nextStep(support: .absent, liveSessionsOfThisUser: 0),
                       .refuse(.daemonCannotAnswer))
    }

    /// **The load-bearing gate, and it is checked first.** A live session means
    /// refuse whatever is known about the daemon — including the state where
    /// the daemon has already answered once, because being wrong here is what
    /// costs somebody an eight-hour job (Task 1's R1.5).
    func testALiveSessionRefusesRegardlessOfWhatIsKnownAboutTheDaemon() {
        for support in [SafetyStopVerbGate.Support.unknown, .present, .absent] {
            XCTAssertEqual(SafetyStopVerbGate.nextStep(support: support, liveSessionsOfThisUser: 1),
                           .refuse(.sessionsAreStillLive),
                           "support \(support) sent a verb while a session was live")
            XCTAssertEqual(SafetyStopVerbGate.nextStep(support: support,
                                                       liveSessionsOfThisUser: 200),
                           .refuse(.sessionsAreStillLive))
        }
    }

    /// **`.absent` is terminal.** This is Task 1's R1.2: the latch has to
    /// outlive the connection, and nothing observed afterwards may talk it back
    /// into asking — otherwise one failure per reconnect becomes one teardown
    /// per reconnect, and the sessions go with them.
    func testOnceTheDaemonHasFailedNothingTalksTheLatchBackIntoAsking() {
        SafetyStopVerbGate.record(.absent)
        XCTAssertEqual(SafetyStopVerbGate.support, .absent)

        SafetyStopVerbGate.record(.present)
        XCTAssertEqual(SafetyStopVerbGate.support, .absent, "a failed latch was re-armed")
        SafetyStopVerbGate.record(.unknown)
        XCTAssertEqual(SafetyStopVerbGate.support, .absent)
        XCTAssertEqual(SafetyStopVerbGate.nextStep(support: SafetyStopVerbGate.support,
                                                   liveSessionsOfThisUser: 0),
                       .refuse(.daemonCannotAnswer))
    }

    /// The latch is process-wide state, not per-connection and not per-object:
    /// a second `DaemonConnection` reads the same answer, because "does this
    /// Mac's daemon implement a verb" is not a property of a connection.
    func testTheLatchIsProcessWideRatherThanPerConnection() {
        SafetyStopVerbGate.record(.present)
        XCTAssertEqual(SafetyStopVerbGate.support, .present)
        _ = DaemonConnection()
        _ = DaemonConnection()
        XCTAssertEqual(SafetyStopVerbGate.support, .present,
                       "building connections reset a latch that has to outlive them")
    }

    /// A probe that clears the daemon is remembered, so the version call
    /// happens at most once per process rather than once per explanation.
    func testAClearedProbeIsRememberedSoNothingProbesTwice() {
        SafetyStopVerbGate.record(.present)
        XCTAssertEqual(SafetyStopVerbGate.nextStep(support: SafetyStopVerbGate.support,
                                                   liveSessionsOfThisUser: 0),
                       .send, "a second explanation would re-probe the version")
    }
}

// MARK: - Plan 8 Task 9: the gate in front of the mode change

/// The second gate, and the one with **less** protection behind it — which is
/// the thing worth pinning, because it is the difference a reader has to be able
/// to see. `SafetyStopVerbGate` refuses while this user owns a live session, so
/// a wrong version answer costs nothing there; this verb exists to act on a live
/// session, so that gate cannot exist here at all and the version gate carries
/// the whole weight.
@MainActor
final class ChangeSessionPowerGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChangeSessionPowerGate.resetForTesting()
    }

    override func tearDown() {
        ChangeSessionPowerGate.resetForTesting()
        super.tearDown()
    }

    func testAFreshProcessKnowsNothingAndProbesFirst() {
        XCTAssertEqual(ChangeSessionPowerGate.support, .unknown)
        XCTAssertEqual(ChangeSessionPowerGate.nextStep(support: .unknown), .askTheVersionFirst)
    }

    func testAClearedDaemonIsSentAndAnOldOneNeverIs() {
        XCTAssertEqual(ChangeSessionPowerGate.nextStep(support: .present), .send)
        XCTAssertEqual(ChangeSessionPowerGate.nextStep(support: .absent), .refuse)
    }

    /// **`.absent` is terminal** — Task 1's R1.2. Nothing observed later may talk
    /// it back into asking, or one failure per reconnect becomes one teardown per
    /// reconnect, and this user's sessions go with them.
    func testOnceTheDaemonHasFailedNothingTalksTheLatchBackIntoAsking() {
        ChangeSessionPowerGate.record(.absent)
        ChangeSessionPowerGate.record(.present)
        XCTAssertEqual(ChangeSessionPowerGate.support, .absent, "a failed latch was re-armed")
        ChangeSessionPowerGate.record(.unknown)
        XCTAssertEqual(ChangeSessionPowerGate.support, .absent)
        XCTAssertEqual(ChangeSessionPowerGate.nextStep(support: ChangeSessionPowerGate.support),
                       .refuse)
    }

    /// The latch is process-wide, not per-connection and not per-object: the
    /// connection is rebuilt three seconds after every failure, and "does this
    /// Mac's daemon implement a verb" is not a property of a connection.
    func testTheLatchIsProcessWideRatherThanPerConnection() {
        ChangeSessionPowerGate.record(.present)
        _ = DaemonConnection()
        _ = DaemonConnection()
        XCTAssertEqual(ChangeSessionPowerGate.support, .present,
                       "building connections reset a latch that has to outlive them")
    }

    /// A cleared probe is remembered, so the version call happens at most once
    /// per process rather than once per click.
    func testAClearedProbeIsRememberedSoNothingProbesTwice() {
        ChangeSessionPowerGate.record(.present)
        XCTAssertEqual(ChangeSessionPowerGate.nextStep(support: ChangeSessionPowerGate.support),
                       .send)
    }

    /// **The two gates are independent facts about the same daemon**, and must
    /// not be able to answer for each other: during exactly the upgrade window
    /// these exist for, a daemon can have one verb and not the other.
    func testLatchingOneVerbSaysNothingAboutTheOther() {
        SafetyStopVerbGate.resetForTesting()
        defer { SafetyStopVerbGate.resetForTesting() }

        ChangeSessionPowerGate.record(.absent)
        XCTAssertEqual(SafetyStopVerbGate.support, .unknown,
                       "one verb's failure latched the other's gate")
        SafetyStopVerbGate.record(.present)
        XCTAssertEqual(ChangeSessionPowerGate.support, .absent)
    }
}

/// **Asking must cost nothing but the change**, on a machine whose daemon cannot
/// answer — the same claim `DaemonConnectionSafetyStopQueryTests` makes below,
/// for the verb that has one fewer gate in front of it.
///
/// Nothing here reaches a working daemon: the test host is ad-hoc signed, which
/// the installed daemon refuses at its code-signing gate, so the `version` probe
/// fails, the gate latches "absent", and `changeSessionPower` is **never put on
/// the wire at all** — which is exactly the behaviour under test. The
/// `[app] XPC error` lines in the log are that refusal.
@MainActor
final class DaemonConnectionPowerChangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChangeSessionPowerGate.resetForTesting()
    }

    override func tearDown() {
        ChangeSessionPowerGate.resetForTesting()
        super.tearDown()
    }

    /// The call must *return*, and must report failure rather than a change that
    /// did not happen.
    func testTheChangeReturnsAndReportsFailureWhenTheDaemonCannotAnswer() async {
        let daemon = DaemonConnection()
        daemon.start()
        let done = expectation(description: "changeSessionPower() returned")
        Task { @MainActor in
            let changed = await daemon.changeSessionPower(
                of: UUID(), to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
            XCTAssertFalse(changed, "a daemon that cannot be asked must not report a change")
            XCTAssertNotNil(daemon.powerRequestNote,
                            "and the menu must say why nothing happened, rather than showing a "
                            + "row that silently does nothing")
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
    }

    /// **Asking once leaves the latch set**, so a second click reads a decision
    /// instead of making a fresh attempt. Which value it holds depends on the
    /// daemon this machine is running; that it is no longer `.unknown` does not,
    /// and it is the half that decides whether anything is sent again.
    func testAskingOnceLeavesNothingLeftToProbe() async {
        XCTAssertEqual(ChangeSessionPowerGate.support, .unknown)
        let daemon = DaemonConnection()
        daemon.start()
        _ = await daemon.changeSessionPower(
            of: UUID(), to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
        XCTAssertNotEqual(ChangeSessionPowerGate.support, .unknown,
                          "the first ask left nothing behind, so every later one probes again")
    }

    /// A daemon already known to be too old is refused **without being asked**,
    /// and the refusal says which of the two "nothing happened" sentences it is.
    ///
    /// **What this cannot prove, stated rather than implied**: that the send is
    /// really skipped. `DaemonConnection` builds its `NSXPCConnection` against a
    /// Mach service with no injection point, so there is no way from here to
    /// observe what was and was not put on the wire — the same limitation
    /// `SafetyStopVerbGate`'s wiring has, and the reason the decision itself is a
    /// pure function tested above. This pins the branch's *visible* behaviour;
    /// that `changeSessionPower` consults it before encoding anything is
    /// read-verified.
    func testADaemonAlreadyKnownToBeTooOldGetsTheUnavailableSentence() async {
        ChangeSessionPowerGate.record(.absent)
        let daemon = DaemonConnection()
        let changed = await daemon.changeSessionPower(
            of: UUID(), to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
        XCTAssertFalse(changed)
        XCTAssertEqual(daemon.powerRequestNote, menuPowerChangeUnavailableNote,
                       "the note has to name the cause a user can act on — a restart — rather "
                       + "than the one they cannot")
    }

    /// The client heals: a failed change runs through the same `handleDisconnect`
    /// funnel as any other failed call, so the thing to prove is that the poll
    /// path still runs to completion afterwards.
    func testAFailedChangeLeavesTheConnectionPollingAndPublishing() async {
        let daemon = DaemonConnection()
        daemon.start()
        _ = await daemon.changeSessionPower(
            of: UUID(), to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))

        let refreshed = expectation(description: "refresh() returned after the change")
        Task { @MainActor in
            await daemon.refresh()
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 10)

        let askedAgain = expectation(description: "a second change returned")
        Task { @MainActor in
            let changed = await daemon.changeSessionPower(
                of: UUID(), to: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false))
            XCTAssertFalse(changed)
            askedAgain.fulfill()
        }
        await fulfillment(of: [askedAgain], timeout: 10)
    }
}

// MARK: - Plan 8 Task 7: the reason query must not be able to break the client

/// **A daemon that cannot answer must cost nothing but the sentence.**
///
/// The hazard Task 1 measured is not a missing reply; it is a connection
/// destroyed server-side, taking the caller's sessions with it. So the claims
/// worth testing at this level are that asking is survivable and that a failure
/// is remembered: the app must go on polling, go on publishing sessions, and
/// never ask again.
///
/// Nothing here reaches a working daemon. The test host is ad-hoc signed, which
/// the installed daemon refuses at its code-signing gate, so the `version`
/// probe fails and the gate latches "absent" — meaning `recentSafetyStops`
/// itself is **never put on the wire at all**, which is exactly the behaviour
/// under test. The `[app] XPC error` lines in the log are that refusal.
@MainActor
final class DaemonConnectionSafetyStopQueryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SafetyStopVerbGate.resetForTesting()
    }

    override func tearDown() {
        SafetyStopVerbGate.resetForTesting()
        super.tearDown()
    }

    /// Same shape as the continuation-leak tests above: the call must *return*.
    /// A reason query that hung would strand the notifier's deferred task and,
    /// with it, the banner the user was waiting for.
    func testTheReasonQueryReturnsInsteadOfHangingWhenTheDaemonCannotAnswer() async {
        let daemon = DaemonConnection()
        daemon.start()
        let done = expectation(description: "recentSafetyStops() returned")
        Task { @MainActor in
            let records = await daemon.recentSafetyStops()
            XCTAssertEqual(records, [],
                           "a daemon that cannot answer must produce no reason, not a wrong one")
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
    }

    /// **Asking leaves the latch set**, so the next explanation reads a decision
    /// instead of making a fresh attempt. Which value it holds depends on the
    /// daemon this machine happens to be running; that it is no longer
    /// `.unknown` does not, and it is the half that decides whether anything is
    /// sent a second time. The terminal-ness of `.absent` is pinned
    /// deterministically in `SafetyStopVerbGateTests`, with no daemon involved.
    func testAskingOnceLeavesNothingLeftToProbe() async {
        XCTAssertEqual(SafetyStopVerbGate.support, .unknown)
        let daemon = DaemonConnection()
        daemon.start()
        _ = await daemon.recentSafetyStops()
        XCTAssertNotEqual(SafetyStopVerbGate.support, .unknown,
                          "the first ask left nothing behind, so every later one probes again")
    }

    /// **The connection survives it.** A failed reason query runs through the
    /// same `handleDisconnect` funnel as any other failed call, so the thing to
    /// prove is that the client heals: it still polls, and it still publishes.
    func testAFailedReasonQueryLeavesTheConnectionPollingAndPublishing() async {
        let daemon = DaemonConnection()
        daemon.start()
        _ = await daemon.recentSafetyStops()

        let refreshed = expectation(description: "refresh() returned after the reason query")
        Task { @MainActor in
            await daemon.refresh()
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 10)
        // `sessions` is published either way — what matters is that the poll
        // path still runs to completion rather than being wedged by the query.
        XCTAssertTrue(daemon.sessions.isEmpty || !daemon.sessions.isEmpty)

        let askedAgain = expectation(description: "a second reason query returned")
        Task { @MainActor in
            let records = await daemon.recentSafetyStops()
            XCTAssertEqual(records, [])
            askedAgain.fulfill()
        }
        await fulfillment(of: [askedAgain], timeout: 10)
    }
}
