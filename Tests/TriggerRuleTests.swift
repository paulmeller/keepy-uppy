import XCTest
@testable import KeepyUppy

final class TriggerRuleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `UserDefaults(suiteName:)` returns nil when `suiteName` equals the
        // *calling process's own* bundle identifier — which is exactly the
        // case here, since this test host is the "Keepy Uppy" app itself
        // (PRODUCT_BUNDLE_IDENTIFIER `au.com.workwireless.keepy-uppy`,
        // identical to the suite name string). `TriggerStore` works around
        // this by falling back to `.standard`, which for this exact
        // degenerate case resolves to the identical underlying preferences
        // file — so clearing `.standard`'s domain here really does reset
        // it (mirrors `SafetyConfigStoreTests.setUp()`, which needed the
        // same fix to avoid the prior run's saved rules leaking through).
        UserDefaults.standard.removePersistentDomain(forName: PreferencesSuite.name)
    }

    struct FakeAppRunning: AppRunningObserving {
        let running: Set<String>
        var reading: ConditionReading? = nil
        func isRunning(bundleID: String) -> ConditionReading {
            reading ?? ConditionReading(running.contains(bundleID))
        }
    }
    struct FakeDisplay: DisplayObserving {
        let external: Bool
        var reading: ConditionReading? = nil
        func hasExternalDisplay() -> ConditionReading { reading ?? ConditionReading(external) }
    }
    struct FakeProcessRunning: ProcessRunningObserving {
        let running: Set<String>
        var reading: ConditionReading? = nil
        func isRunning(processName: String) -> ConditionReading {
            reading ?? ConditionReading(running.contains(processName))
        }
    }

    private func rule(_ condition: TriggerCondition, kind: DefaultSessionKind = .indefinite, enabled: Bool = true) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, defaultKind: kind, enabled: enabled)
    }

    /// One `triggersToFire` evaluation with every observer defaulted to
    /// "condition false", so each test names only what it is about.
    ///
    /// The per-observer parameters stay parameters even though `triggersToFire`
    /// now takes one `ObserverSet`: the set is assembled here, so a new
    /// condition costs this file one defaulted argument rather than an edit to
    /// every one of the call sites below.
    private func fire(_ rules: [TriggerRule],
                      activeSessions: [Session] = [],
                      app: FakeAppRunning = FakeAppRunning(running: []),
                      display: FakeDisplay = FakeDisplay(external: false),
                      process: FakeProcessRunning = FakeProcessRunning(running: []),
                      acPower: ConditionReading = .absent) -> [TriggerRule] {
        triggersToFire(rules, activeSessions: activeSessions,
                       // No trigger condition consults the CPU sample, so this
                       // is filler — and `.undetermined` is the filler that
                       // cannot fire anything if one ever starts to.
                       observers: ObserverSet(appRunning: app, display: display,
                                              processRunning: process, acPower: acPower,
                                              cpuBusy: .undetermined))
    }

    func testDisabledRuleNeverFires() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), enabled: false)
        XCTAssertTrue(fire([r], app: FakeAppRunning(running: ["com.apple.dt.Xcode"])).isEmpty)
    }

    func testAppLaunchedFiresWhenRunning() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(fire([r], app: FakeAppRunning(running: ["com.apple.dt.Xcode"])).map(\.id), [r.id])
    }

    func testExternalDisplayConnectedFires() {
        let r = rule(.externalDisplayConnected)
        XCTAssertEqual(fire([r], display: FakeDisplay(external: true)).map(\.id), [r.id])
    }

    func testACPowerConnectedFires() {
        let r = rule(.acPowerConnected)
        XCTAssertEqual(fire([r], acPower: .present).map(\.id), [r.id])
    }

    func testProcessRunningFiresWhenRunning() {
        let r = rule(.processRunning(processName: "claude"))
        XCTAssertEqual(fire([r], process: FakeProcessRunning(running: ["claude"])).map(\.id), [r.id])
    }

    func testProcessRunningDoesNotFireWhenNotRunning() {
        let r = rule(.processRunning(processName: "claude"))
        XCTAssertTrue(fire([r]).isEmpty)
    }

    /// The most important test in this file: a trigger already represented
    /// by a live session must not fire again every tick.
    func testAlreadyActiveTriggerDoesNotFireAgain() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let already = Session(id: UUID(), kind: r.defaultKind.sessionKind(now: Date()),
                              owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id)
        XCTAssertTrue(fire([r], activeSessions: [already],
                           app: FakeAppRunning(running: ["com.apple.dt.Xcode"])).isEmpty)
    }

    /// The same de-dup guarantee for `.processRunning`, which had no coverage
    /// of it at all — and which needs it most, because it is the one
    /// condition whose session lasts exactly as long as the condition holds.
    /// Without this, a running `claude` would originate a fresh session every
    /// 5s tick for as long as it ran: a real XPC round-trip and a privileged
    /// power-assertion write each time.
    func testAlreadyActiveProcessTriggerDoesNotFireAgain() {
        let r = rule(.processRunning(processName: "claude"))
        let already = Session(id: UUID(), kind: sessionKind(firing: r, now: Date()),
                              owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id)
        XCTAssertEqual(already.kind, .whileProcessRunning(processName: "claude"))
        XCTAssertTrue(fire([r], activeSessions: [already],
                           process: FakeProcessRunning(running: ["claude"])).isEmpty,
                      "the process is still running, but its session already exists")
    }

    /// De-dup is by trigger id, not by condition: an unrelated live session
    /// for a *different* rule must not suppress this one.
    func testAProcessTriggerStillFiresWhileAnotherRulesSessionIsLive() {
        let mine = rule(.processRunning(processName: "claude"))
        let other = rule(.processRunning(processName: "codex"))
        let othersSession = Session(id: UUID(), kind: sessionKind(firing: other, now: Date()),
                                    owner: ClientID(rawValue: "agent"),
                                    persistence: .detached, origin: .trigger, startedAt: Date(),
                                    triggerID: other.id)
        let fired = fire([mine], activeSessions: [othersSession],
                         process: FakeProcessRunning(running: ["claude", "codex"]))
        XCTAssertEqual(fired.map(\.id), [mine.id])
    }

    func testConditionFalseDoesNotFire() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(fire([r]).isEmpty)
    }

    // MARK: - The tri-state contract
    //
    // The mirror of the `sessionsToEnd` tests in EvidenceLoopTests: a session
    // may only be STARTED on a confident positive. An observer that could not
    // look has not seen the condition become true.

    func testUndeterminedNeverFiresAnyCondition() {
        let appRule = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(fire([appRule], app: FakeAppRunning(running: [], reading: .undetermined)).isEmpty)

        let displayRule = rule(.externalDisplayConnected)
        XCTAssertTrue(fire([displayRule], display: FakeDisplay(external: false, reading: .undetermined)).isEmpty)

        let processRule = rule(.processRunning(processName: "claude"))
        XCTAssertTrue(fire([processRule], process: FakeProcessRunning(running: [], reading: .undetermined)).isEmpty)

        let powerRule = rule(.acPowerConnected)
        XCTAssertTrue(fire([powerRule], acPower: .undetermined).isEmpty,
                      "IOKit declining to name the power source is not 'AC connected'")
    }

    /// The reading, not the fake's backing set, is what decides — proving the
    /// call sites really do test for `.present` rather than for "not absent".
    func testUndeterminedDoesNotFireEvenWhenTheProcessIsActuallyRunning() {
        let r = rule(.processRunning(processName: "claude"))
        XCTAssertTrue(fire([r], process: FakeProcessRunning(running: ["claude"], reading: .undetermined)).isEmpty)
    }

    // MARK: - Both halves of the contract, over every condition there is
    //
    // Every firing test above names one condition, and so does every clause of
    // `testUndeterminedNeverFiresAnyCondition`. A fifth condition therefore gets
    // neither: its arm in `triggersToFire` can `return false` and its
    // `.undetermined` handling can be anything at all with the whole suite
    // green — which a reviewer demonstrated by adding a condition, stubbing its
    // arm, and watching 382 tests pass. The two loops below close that, over
    // `TriggerConditionKind.allCases`, which a new condition cannot stay out of:
    // `sampleCondition` is an exhaustive switch, so the case cannot be added
    // without also handing these tests a condition to try it with.
    //
    // They are kept alongside the per-condition tests, not instead of them:
    // those pin specifics (which bundle ID, which process name, the de-dup by
    // trigger id) that a loop over stand-in samples cannot.

    /// Every observer answering `.present`, whatever it is asked about — the one
    /// `ObserverSet` under which *every* condition must fire.
    ///
    /// The backing sets are deliberately empty: the `reading` override is what
    /// answers, so an arm that consults something other than the reading it was
    /// handed fails here instead of passing by accident.
    ///
    /// `ObserverSet` gives no member a default, on purpose (see its doc
    /// comment), which is also what keeps this helper honest: a seventh observer
    /// stops it compiling until somebody states what "present" means for it,
    /// rather than leaving the loops below quietly testing a stale bundle.
    private var everyObserverPresent: ObserverSet {
        ObserverSet(appRunning: FakeAppRunning(running: [], reading: .present),
                    display: FakeDisplay(external: false, reading: .present),
                    processRunning: FakeProcessRunning(running: [], reading: .present),
                    acPower: .present,
                    // No trigger condition consults the CPU sample today;
                    // `.busy(fraction: 1)` is that reading's analogue of
                    // `.present` for the day one does.
                    cpuBusy: .busy(fraction: 1))
    }

    /// The same bundle with every observation failed.
    private var everyObserverUndetermined: ObserverSet {
        ObserverSet(appRunning: FakeAppRunning(running: [], reading: .undetermined),
                    display: FakeDisplay(external: false, reading: .undetermined),
                    processRunning: FakeProcessRunning(running: [], reading: .undetermined),
                    acPower: .undetermined,
                    cpuBusy: .undetermined)
    }

    /// A condition whose firing arm cannot fire is a trigger that ships dead:
    /// it appears in the picker, the user creates a rule with it, and nothing
    /// ever happens — no error, no session, nothing to notice. The general form
    /// of `testAppLaunchedFiresWhenRunning` and its three siblings.
    ///
    /// A future condition that reads something `ObserverSet` does not carry at
    /// all would fail here too. That is the right prompt rather than a
    /// nuisance: the tick's set of facts is what both `triggersToFire` and
    /// `sessionsToEnd` are given, and a condition evaluated from outside it is a
    /// condition the evidence loop cannot reason about.
    func testEveryConditionFiresWhenItsObserverIsConfidentlyPresent() {
        for kind in TriggerConditionKind.allCases {
            let r = rule(kind.sampleCondition)
            XCTAssertEqual(
                triggersToFire([r], activeSessions: [], observers: everyObserverPresent).map(\.id), [r.id],
                "\(kind) does not fire on a confident positive — its arm in triggersToFire is dead")
        }
    }

    /// The safety half, and the one `testUndeterminedNeverFiresAnyCondition`
    /// cannot extend to a condition nobody has written yet: an observation that
    /// failed says nothing about the world, so it must start nothing. Every
    /// observer is `.undetermined` at once, so whichever one a new condition
    /// reads, it reads a failure.
    ///
    /// The mirror of `sessionsToEnd`'s rule, and the more expensive half to get
    /// wrong in the other direction: a `sysctl` race that answered `false` 15%
    /// of the time under load once read as "the process exited" and ended live
    /// sessions mid-build.
    func testNoConditionFiresWhenEveryObservationFailed() {
        for kind in TriggerConditionKind.allCases {
            let r = rule(kind.sampleCondition)
            XCTAssertTrue(
                triggersToFire([r], activeSessions: [], observers: everyObserverUndetermined).isEmpty,
                "\(kind) fires on an observation that failed")
        }
    }

    // MARK: - Process-name validation

    func testAPlainNameIsAcceptedWhateverItsLength() {
        XCTAssertNil(TriggerCondition.processNameProblem("claude"))
        // Longer than MAXCOMLEN (16). Matching argv[0] and the executable
        // path rather than the truncated `p_comm` is what makes this legal;
        // verified empirically against a 31-character binary name.
        XCTAssertNil(TriggerCondition.processNameProblem("keepy-uppy-observer-probe-sleep"))
    }

    func testAPathIsRejectedRatherThanSilentlyNeverMatching() {
        XCTAssertNotNil(TriggerCondition.processNameProblem("/opt/homebrew/bin/claude"))
        XCTAssertNotNil(TriggerCondition.processNameProblem("bin/claude"))
    }

    func testSurroundingWhitespaceIsRejected() {
        XCTAssertNotNil(TriggerCondition.processNameProblem("claude "))
        XCTAssertNotNil(TriggerCondition.processNameProblem(" claude"))
    }

    func testTheEmptyFieldIsNotYetAnError() {
        XCTAssertNil(TriggerCondition.processNameProblem(""),
                     "an empty field is incomplete, not wrong — the Add button is disabled for it")
    }

    /// Every shipped quick-add preset must itself be a name the matcher can
    /// match, or the button would write a rule that can never fire.
    func testEveryShippedPresetNameIsValid() {
        for name in ["claude", "codex", "pi", "agent", "agy"] {
            XCTAssertNil(TriggerCondition.processNameProblem(name), "preset \"\(name)\"")
        }
    }

    /// Final whole-branch review, Finding 2. A rule created today and fired
    /// next week must keep the Mac awake for an hour *from when it fired*.
    /// Before the fix the rule stored an absolute `SessionKind` frozen at
    /// creation time, so the deadline here landed seven days in the past —
    /// the daemon's `removeExpired` sweep then deleted the session in the
    /// same call that admitted it, and the agent refired the rule forever.
    func testRuleFiredLongAfterCreationGetsADeadlineInTheFuture() {
        let creation = Date(timeIntervalSince1970: 1_000_000)
        let fire = creation.addingTimeInterval(7 * 24 * 3600)
        // Exactly what TriggersSettingsTab.addRule() does, at `creation`.
        let r = rule(.acPowerConnected, kind: .oneHour)
        // Exactly what EvidenceLoopRunner does when the rule fires, at `fire`.
        let session = Session(id: UUID(), kind: r.defaultKind.sessionKind(now: fire),
                              owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: fire, triggerID: r.id)
        XCTAssertGreaterThan(session.kind.deadline ?? .distantPast, fire,
                             "a rule fired at `fire` must produce a session that outlives `fire`")
        XCTAssertEqual(session.kind, .duration(until: fire.addingTimeInterval(3600)))
    }

    /// The structural half of the same guarantee: one stored rule, two
    /// materializations far apart, two deadlines that differ by exactly the
    /// gap between them. A rule holding a frozen `Date` could not do this —
    /// both materializations would return the identical value.
    func testTheSameRuleMaterializesADifferentDeadlineAtEachFireTime() {
        let r = rule(.externalDisplayConnected, kind: .oneHour)
        let first = Date(timeIntervalSince1970: 1_000_000)
        let gap: TimeInterval = 30 * 24 * 3600
        let second = first.addingTimeInterval(gap)

        guard case .duration(let firstDeadline) = r.defaultKind.sessionKind(now: first),
              case .duration(let secondDeadline) = r.defaultKind.sessionKind(now: second)
        else { return XCTFail("expected .duration from a .oneHour rule") }

        XCTAssertEqual(secondDeadline.timeIntervalSince(firstDeadline), gap, accuracy: 1,
                       "the deadline must track the fire time, not be frozen at construction")
        XCTAssertEqual(firstDeadline.timeIntervalSince(first), 3600, accuracy: 1)
        XCTAssertEqual(secondDeadline.timeIntervalSince(second), 3600, accuracy: 1)
    }

    func testStoreSaveThenLoadRoundTrips() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), kind: .oneHour, enabled: false)
        TriggerStore.save([r])

        let loaded = TriggerStore.load()
        XCTAssertEqual(loaded, [r])
    }

    /// The round-trip above is only meaningful if what got persisted was the
    /// relative intent. A rule that survives a save/load cycle and *then*
    /// fires must still produce a deadline relative to the firing, which is
    /// only possible if no absolute date was ever written to disk.
    func testAPersistedRuleStillMaterializesRelativeToFireTime() {
        TriggerStore.save([rule(.acPowerConnected, kind: .fourHours)])
        guard let loaded = TriggerStore.load().first else { return XCTFail("nothing round-tripped") }

        let fire = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(loaded.defaultKind.sessionKind(now: fire),
                       .duration(until: fire.addingTimeInterval(4 * 3600)))
    }

    // MARK: - sessionKind(firing:now:)

    /// The one deliberate exception: a `.processRunning` rule always starts
    /// `.whileProcessRunning`, ignoring whatever `defaultKind` happens to be
    /// stored — because ending on process exit, not after a picked
    /// duration, is the entire point of this condition.
    func testProcessRunningRuleAlwaysMaterializesWhileProcessRunning() {
        let r = rule(.processRunning(processName: "claude"), kind: .fourHours)
        XCTAssertEqual(sessionKind(firing: r, now: Date()), .whileProcessRunning(processName: "claude"))
    }

    /// Regression guard: this refactor must not change what the other three
    /// conditions materialize. Each still defers to `defaultKind`, exactly
    /// as `rule.defaultKind.sessionKind(now:)` did before this function
    /// existed.
    func testEveryOtherConditionStillDefersToDefaultKind() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        for condition: TriggerCondition in [.appLaunched(bundleID: "com.apple.dt.Xcode"),
                                            .externalDisplayConnected, .acPowerConnected] {
            let r = rule(condition, kind: .oneHour)
            XCTAssertEqual(sessionKind(firing: r, now: now), r.defaultKind.sessionKind(now: now))
        }
    }

    // MARK: - The condition table
    //
    // The generalisation of the carve-out above: `sessionKind(firing:now:)`
    // now reads `boundSessionKind` rather than matching `.processRunning`, and
    // `TriggerConditionKind` is the one list the picker and the copy both read.

    /// Plan 4 proved a mode can exist that nobody can select
    /// (`testEveryWakeModeIsReachableFromTheCommandLine`). The same hole is open
    /// here and is wider: `AddTriggerSheet.ConditionKind` is a *parallel* enum, so
    /// adding a `TriggerCondition` case does not fail to compile — it just produces
    /// a condition no user can ever create. `TriggerConditionKind` closes it by
    /// being the single list both the model and the picker read.
    func testEveryConditionKindBuildsACondition() {
        for kind in TriggerConditionKind.allCases {
            XCTAssertEqual(kind.sampleCondition.kind, kind,
                           "\(kind) does not round-trip through TriggerCondition.kind")
        }
    }

    /// ...and no two kinds collapse onto the same condition.
    func testEveryConditionKindIsDistinct() {
        let kinds = TriggerConditionKind.allCases.map(\.sampleCondition.kind)
        XCTAssertEqual(Set(kinds).count, TriggerConditionKind.allCases.count)
    }

    /// The carve-out, stated once instead of hardcoded in three places. A condition
    /// that binds its session's lifetime must produce a `SessionKind`; one that
    /// does not must produce nil, so `sessionKind(firing:now:)` falls through to
    /// `defaultKind`.
    func testBindingConditionsProduceASessionKindAndOthersDoNot() {
        for kind in TriggerConditionKind.allCases {
            let bound = kind.sampleCondition.boundSessionKind
            XCTAssertEqual(bound != nil, kind.bindsSessionLifetime,
                           "\(kind): bindsSessionLifetime and boundSessionKind disagree")
        }
    }

    /// Regression guard for the one condition that already had this behaviour.
    func testProcessRunningStillBindsAndTheOriginalThreeStillDoNot() {
        XCTAssertTrue(TriggerConditionKind.processRunning.bindsSessionLifetime)
        XCTAssertFalse(TriggerConditionKind.appLaunched.bindsSessionLifetime)
        XCTAssertFalse(TriggerConditionKind.externalDisplayConnected.bindsSessionLifetime)
        XCTAssertFalse(TriggerConditionKind.acPowerConnected.bindsSessionLifetime)
    }

    /// The table restated as the behaviour it drives: whatever
    /// `boundSessionKind` says is exactly what a firing rule starts, and a
    /// non-binding kind is untouched by the stored `defaultKind`. This is the
    /// general form of the two `sessionKind(firing:now:)` tests above, which
    /// name `.processRunning` and the original three by hand.
    func testFiringMaterializesTheBoundKindOrDefersToDefaultKind() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        for kind in TriggerConditionKind.allCases {
            let r = rule(kind.sampleCondition, kind: .fourHours)
            if let bound = kind.sampleCondition.boundSessionKind {
                XCTAssertEqual(sessionKind(firing: r, now: now), bound, "\(kind)")
                XCTAssertNotEqual(sessionKind(firing: r, now: now),
                                  r.defaultKind.sessionKind(now: now),
                                  "\(kind) binds, so defaultKind must be ignored")
            } else {
                XCTAssertEqual(sessionKind(firing: r, now: now),
                               r.defaultKind.sessionKind(now: now), "\(kind)")
            }
        }
    }
}
