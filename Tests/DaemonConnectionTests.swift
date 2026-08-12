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
    /// has none of this. It must never be sent the verb.
    func testTheDaemonRunningOnThisMacIsRefused() {
        XCTAssertFalse(DaemonCapability.supportsRecentSafetyStops(versionReply: "0.1.0"))
    }

    /// Every uncertain answer is "no". Being wrong towards absent costs a
    /// sentence; being wrong towards present costs the user their sessions.
    func testEveryUncertainAnswerMeansTheVerbIsAbsent() {
        XCTAssertFalse(DaemonCapability.supportsRecentSafetyStops(versionReply: nil),
                       "a failed version call knows nothing, so it may not clear anything")
        XCTAssertFalse(DaemonCapability.supportsRecentSafetyStops(versionReply: ""))
        XCTAssertFalse(DaemonCapability.supportsRecentSafetyStops(versionReply: "banana"))
    }

    /// The boundary, in both directions, plus the number itself — 4 rather
    /// than 3, because 3 has already shipped on a daemon with none of this
    /// (the installed app on this machine reports `CFBundleVersion` 3).
    func testOnlyABuildAtOrAboveTheIntroducingOneIsCleared() {
        XCTAssertGreaterThan(DaemonCapability.recentSafetyStopsBuild, 3,
                             "build 3 has shipped without this verb; gating at or below it "
                             + "would clear the daemon this feature must not be sent to")
        let introduced = DaemonCapability.recentSafetyStopsBuild
        for build in [0, 1, 2, 3, introduced - 1] {
            XCTAssertFalse(DaemonCapability.supportsRecentSafetyStops(
                versionReply: bundleVersionText(shortVersion: "0.1.0", build: String(build))),
                           "build \(build) was cleared")
        }
        for build in [introduced, introduced + 1, introduced + 100] {
            XCTAssertTrue(DaemonCapability.supportsRecentSafetyStops(
                versionReply: bundleVersionText(shortVersion: "0.1.0", build: String(build))),
                          "build \(build) was refused")
        }
    }

    /// The gate is only implementable because the release introducing the verb
    /// bumps, so this pins the third leg of that: the constant, the verb and
    /// `project.yml` travel together or the gate is a guess.
    func testThisBuildIsNewEnoughToBeAskedItsOwnVerb() {
        XCTAssertTrue(DaemonCapability.supportsRecentSafetyStops(
            versionReply: bundleVersionText(of: .main)),
                      "this build ships the verb but would refuse to ask a daemon of its own "
                      + "vintage — CURRENT_PROJECT_VERSION was not bumped with it")
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
