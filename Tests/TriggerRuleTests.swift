import XCTest
@testable import KeepyUppy

final class TriggerRuleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // This line used to read `UserDefaults.standard.removePersistentDomain(
        // forName: PreferencesSuite.name)`, which in this process deleted the
        // *live user's* trigger rules, safety config and defaults on every
        // run — the test host is the app itself, so that domain was the
        // shipping one. `PreferencesSuite.name` now redirects under XCTest
        // and this helper refuses to clear the production suite; see
        // `PreferencesSuiteIsolationTests` for the guarantee stated as a test.
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one, so these tests would "
                      + "be writing to the real user's preferences")
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
    /// `frontmost` is deliberately an `Optional`, and `nil` means `.absent`
    /// rather than `.undetermined`: "no app is in front" is not a state the
    /// *matching* can produce — only the live observer's failed read is, and
    /// that is what `reading` is for. A fake that conflated the two would let
    /// a call site testing for "not absent" pass.
    struct FakeFrontmostApp: FrontmostAppObserving {
        let frontmost: String?
        var reading: ConditionReading? = nil
        func isFrontmost(bundleID: String) -> ConditionReading {
            reading ?? ConditionReading(frontmost == bundleID)
        }
    }

    struct FakeMountedVolume: MountedVolumeObserving {
        let mounted: Set<String>
        var reading: ConditionReading? = nil
        func isMounted(volumeName: String) -> ConditionReading {
            reading ?? ConditionReading(mounted.contains(volumeName))
        }
    }

    /// Answers from a set of addresses, exactly as the live observer does, so
    /// the fake exercises `IPv4Subnet.contains` rather than standing in for
    /// it. `reading` overrides the lot, for the failure case.
    struct FakeNetworkAddress: NetworkAddressObserving {
        let addresses: Set<UInt32>
        var reading: ConditionReading? = nil
        init(_ dotted: [String] = [], reading: ConditionReading? = nil) {
            addresses = Set(dotted.compactMap { IPv4Subnet(cidr: $0)?.network })
            self.reading = reading
        }
        func isOnSubnet(_ subnet: IPv4Subnet) -> ConditionReading {
            reading ?? ConditionReading(addresses.contains(where: subnet.contains))
        }
    }

    /// The only observer with nothing to ask *about*: `.vpnActive` names no
    /// tunnel, so the fake is a bare reading rather than a set plus an
    /// override.
    struct FakeVPN: VPNObserving {
        let reading: ConditionReading
        init(_ reading: ConditionReading = .absent) { self.reading = reading }
        func isVPNActive() -> ConditionReading { reading }
    }

    /// Answers from a set of attached devices, exactly as the live observer
    /// does, so the fake exercises the identifier comparison rather than
    /// standing in for it. `reading` overrides the lot, for the failure case.
    struct FakeUSBDevice: USBDeviceObserving {
        let attached: Set<USBDeviceID>
        var reading: ConditionReading? = nil
        init(_ texts: [String] = [], reading: ConditionReading? = nil) {
            attached = Set(texts.compactMap { USBDeviceID(text: $0) })
            self.reading = reading
        }
        func isPresent(vendorID: UInt16, productID: UInt16) -> ConditionReading {
            reading ?? ConditionReading(attached.contains(USBDeviceID(vendorID: vendorID, productID: productID)))
        }
    }

    /// `effect` is an `Optional` with no default value of its own rather than
    /// `= TriggerEffect.default(for: ...)`, which Swift cannot express anyway
    /// (a default argument cannot read another argument) — and the shape is the
    /// right one regardless: "not stated" and "stated as the default" are the
    /// same rule here, and both are what the ~40 tests written before Plan 8
    /// Task 10 meant. The tests that are *about* the field pass it.
    private func rule(_ condition: TriggerCondition, kind: DefaultSessionKind = .indefinite,
                      enabled: Bool = true, effect: TriggerEffect? = nil) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, defaultKind: kind, enabled: enabled,
                    effect: effect ?? TriggerEffect.default(for: condition))
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
                      frontmost: FakeFrontmostApp = FakeFrontmostApp(frontmost: nil),
                      volume: FakeMountedVolume = FakeMountedVolume(mounted: []),
                      network: FakeNetworkAddress = FakeNetworkAddress(),
                      vpn: FakeVPN = FakeVPN(),
                      usbDevice: FakeUSBDevice = FakeUSBDevice(),
                      acPower: ConditionReading = .absent,
                      now: Date? = nil) -> [TriggerRule] {
        triggersToFire(rules, activeSessions: activeSessions,
                       // No trigger condition consults the CPU sample, so this
                       // is filler — and `.undetermined` is the filler that
                       // cannot fire anything if one ever starts to.
                       observers: ObserverSet(appRunning: app, display: display,
                                              processRunning: process, frontmostApp: frontmost,
                                              mountedVolume: volume, networkAddress: network,
                                              vpn: vpn, usbDevice: usbDevice,
                                              acPower: acPower, cpuBusy: .undetermined),
                       // Inside the sample window by default, so a caller that
                       // does not care about the clock still gets a
                       // `.onSchedule` rule that behaves like the others.
                       now: now ?? insideTheSampleSchedule)
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

    func testFrontmostAppFiresWhenItIsFrontmost() {
        let r = rule(.appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(fire([r], frontmost: FakeFrontmostApp(frontmost: "com.apple.dt.Xcode")).map(\.id),
                       [r.id])
    }

    /// The whole difference between this condition and `.appLaunched`. An app
    /// that is running but behind something else must not fire it — otherwise
    /// the two conditions are one condition with two names, and the picker
    /// offers a choice that makes no difference.
    func testFrontmostAppDoesNotFireWhenItIsMerelyRunning() {
        let r = rule(.appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(fire([r],
                           app: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                           frontmost: FakeFrontmostApp(frontmost: "com.apple.Safari")).isEmpty,
                      "Xcode is running, but Safari is the app in front")
    }

    /// The safety half, named for this condition specifically because its
    /// `.undetermined` is the most reachable of the three Plan 5 adds: a
    /// locked screen, the login window, and fast user switching all leave
    /// `NSWorkspace.frontmostApplication` nil while the app is exactly where
    /// it was. None of those is "Xcode came to the front".
    func testFrontmostAppUndeterminedNeverFires() {
        let r = rule(.appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(fire([r], frontmost: FakeFrontmostApp(frontmost: "com.apple.dt.Xcode",
                                                            reading: .undetermined)).isEmpty,
                      "the app really is in front, but the observer could not tell — so it must not fire")
    }

    func testVolumeMountedFiresWhenTheVolumeIsMounted() {
        let r = rule(.volumeMounted(name: "Backup"))
        XCTAssertEqual(fire([r], volume: FakeMountedVolume(mounted: ["Backup"])).map(\.id), [r.id])
    }

    func testVolumeMountedDoesNotFireForADifferentVolume() {
        let r = rule(.volumeMounted(name: "Backup"))
        XCTAssertTrue(fire([r], volume: FakeMountedVolume(mounted: ["Macintosh HD", "Archive"])).isEmpty)
    }

    /// The `triggersToFire` half of the same contract
    /// `testAVolumeReadThatFailedNeverEndsASession` pins for `sessionsToEnd`:
    /// a volume list that could not be enumerated is not a mounted drive
    /// either.
    func testVolumeMountedUndeterminedNeverFires() {
        let r = rule(.volumeMounted(name: "Backup"))
        XCTAssertTrue(fire([r], volume: FakeMountedVolume(mounted: ["Backup"],
                                                          reading: .undetermined)).isEmpty,
                      "the volume really is mounted, but the read failed — so it must not fire")
    }

    /// The motivating case, end to end through the one table that decides it:
    /// a volume rule starts a session that lasts exactly as long as the drive
    /// is mounted, whatever duration is stored on the rule.
    func testVolumeMountedBindsItsSessionToTheVolume() {
        XCTAssertTrue(TriggerConditionKind.volumeMounted.bindsSessionLifetime)
        let r = rule(.volumeMounted(name: "Backup"), kind: .fourHours)
        XCTAssertEqual(sessionKind(firing: r, now: Date()), .whileVolumeMounted(name: "Backup"))
    }

    func testOnSubnetFiresWhenThisMacHoldsAnAddressInTheBlock() {
        let r = rule(.onSubnet(cidr: "192.168.1.0/24"))
        XCTAssertEqual(fire([r], network: FakeNetworkAddress(["192.168.1.50"])).map(\.id), [r.id])
    }

    func testOnSubnetDoesNotFireFromADifferentNetwork() {
        let r = rule(.onSubnet(cidr: "192.168.1.0/24"))
        XCTAssertTrue(fire([r], network: FakeNetworkAddress(["10.0.0.5", "192.168.2.50"])).isEmpty)
    }

    /// A Mac with Wi-Fi off holds no address at all, and that is a *confident*
    /// negative rather than a failed read — the one place the three Plan 5
    /// observers differ, since an empty volume list or an empty app list means
    /// the enumeration broke.
    func testOnSubnetDoesNotFireWithNoAddressesAtAll() {
        let r = rule(.onSubnet(cidr: "192.168.1.0/24"))
        XCTAssertTrue(fire([r], network: FakeNetworkAddress([])).isEmpty)
    }

    /// `getifaddrs` failing is not "you are on a different subnet".
    func testOnSubnetUndeterminedNeverFires() {
        let r = rule(.onSubnet(cidr: "192.168.1.0/24"))
        XCTAssertTrue(fire([r], network: FakeNetworkAddress(["192.168.1.50"],
                                                            reading: .undetermined)).isEmpty,
                      "this Mac really is on that network, but the read failed")
    }

    /// A rule holding a block this build cannot parse fires nothing. It cannot
    /// be created from the UI or the CLI — both refuse it — so this pins the
    /// backstop rather than a route.
    func testAnUnparseableBlockFiresNothing() {
        let r = rule(.onSubnet(cidr: "not-a-network"))
        XCTAssertTrue(fire([r], network: FakeNetworkAddress(["192.168.1.50"], reading: .present)).isEmpty,
                      "nothing is inside a block that is not one")
    }

    // MARK: - VPN

    func testVPNActiveFiresWhileATunnelIsUp() {
        let r = rule(.vpnActive)
        XCTAssertEqual(fire([r], vpn: FakeVPN(.present)).map(\.id), [r.id])
    }

    /// A Mac with no VPN configured, and a Mac whose VPN is configured but
    /// disconnected, are the same confident negative — see `VPNServiceReading`
    /// for why an empty answer here is a real one rather than a failed read.
    func testVPNActiveDoesNotFireWhileNoTunnelIsUp() {
        XCTAssertTrue(fire([rule(.vpnActive)], vpn: FakeVPN(.absent)).isEmpty)
    }

    /// The whole reason this condition is not "a `utun` exists": a read that
    /// could not tell must not start a session either.
    func testVPNActiveUndeterminedNeverFires() {
        XCTAssertTrue(fire([rule(.vpnActive)], vpn: FakeVPN(.undetermined)).isEmpty,
                      "a network configuration that could not be read is not a connected VPN")
    }

    /// The motivating case through the one table that decides it: "keep this
    /// Mac awake while the tunnel is up" starts a session bound to the tunnel,
    /// whatever duration is stored on the rule.
    func testVPNActiveBindsItsSessionToTheTunnel() {
        XCTAssertTrue(TriggerConditionKind.vpnActive.bindsSessionLifetime)
        let r = rule(.vpnActive, kind: .fourHours)
        XCTAssertEqual(sessionKind(firing: r, now: Date()), .whileVPNActive)
    }

    // MARK: - USB devices

    func testUSBDevicePresentFiresWhenThatDeviceIsAttached() {
        let r = rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f))
        XCTAssertEqual(fire([r], usbDevice: FakeUSBDevice(["05ac:024f"])).map(\.id), [r.id])
    }

    /// **Both** identifiers have to match. A vendor's other product is a
    /// different device, and matching on the vendor alone would hold a Mac
    /// awake for any Apple peripheral at all.
    func testUSBDevicePresentDoesNotFireForADifferentProductFromTheSameVendor() {
        let r = rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f))
        XCTAssertTrue(fire([r], usbDevice: FakeUSBDevice(["05ac:0250", "1234:024f"])).isEmpty)
    }

    /// A laptop with nothing plugged in genuinely has no USB devices — the
    /// same confident negative the network observer makes, and deliberately
    /// unlike the volume observer, whose empty list means the enumeration
    /// broke.
    func testUSBDevicePresentDoesNotFireWithNothingAttachedAtAll() {
        XCTAssertTrue(fire([rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f))],
                           usbDevice: FakeUSBDevice([])).isEmpty)
    }

    /// `IOServiceGetMatchingServices` failing is not "you unplugged it".
    func testUSBDevicePresentUndeterminedNeverFires() {
        let r = rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f))
        XCTAssertTrue(fire([r], usbDevice: FakeUSBDevice(["05ac:024f"], reading: .undetermined)).isEmpty,
                      "the device really is attached, but the registry read failed")
    }

    func testUSBDevicePresentBindsItsSessionToTheDevice() {
        XCTAssertTrue(TriggerConditionKind.usbDevicePresent.bindsSessionLifetime)
        let r = rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f), kind: .fourHours)
        XCTAssertEqual(sessionKind(firing: r, now: Date()),
                       .whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f))
    }

    // MARK: - USB identifier validation

    func testAValidDevicePairHasNoProblem() {
        for good in ["05ac:024f", "0x05ac:0x024F", "5AC:24f", "0:0", "ffff:ffff"] {
            XCTAssertNil(TriggerCondition.usbDeviceProblem(good), good)
        }
    }

    func testTheEmptyDeviceFieldIsNotYetAnError() {
        XCTAssertNil(TriggerCondition.usbDeviceProblem(""),
                     "an empty field is incomplete, not wrong — the Add button is disabled separately")
    }

    func testADeviceValueThatCanNeverMatchIsRejectedWithASentence() {
        for bad in ["05ac", "05ac:", ":024f", "05ac:024f:0", "zzzz:024f", "05ac024f",
                    "12345:024f", "05ac:12345", "05 ac:024f"] {
            let problem = TriggerCondition.usbDeviceProblem(bad)
            XCTAssertNotNil(problem, "'\(bad)' can never match and must say so")
            XCTAssertTrue(problem?.contains("05ac:024f") ?? false,
                          "the message must give a form that would work: \(problem ?? "nil")")
        }
    }

    // MARK: - Subnet validation

    func testAValidBlockOrAddressHasNoProblem() {
        XCTAssertNil(TriggerCondition.subnetProblem("192.168.1.0/24"))
        XCTAssertNil(TriggerCondition.subnetProblem("192.168.1.50"))
        XCTAssertNil(TriggerCondition.subnetProblem("10.0.0.0/8"))
    }

    func testTheEmptySubnetFieldIsNotYetAnError() {
        XCTAssertNil(TriggerCondition.subnetProblem(""),
                     "an empty field is incomplete, not wrong — the Add button is disabled for it")
    }

    func testAValueThatCanNeverMatchIsRejectedWithASentence() {
        for bad in ["192.168.1", "banana", "192.168.1.0/33", "256.0.0.1"] {
            guard let problem = TriggerCondition.subnetProblem(bad) else {
                return XCTFail("\"\(bad)\" can never match, so it must be named")
            }
            XCTAssertTrue(problem.contains("192.168.1.0/24"),
                          "the message has to show what would work: \(problem)")
        }
    }

    /// A v6 address is a perfectly good address that this build cannot watch,
    /// which is a different message from "that is not an address" — and the
    /// one Task 8 exists to say out loud rather than silently never matching.
    func testAnIPv6AddressSaysWhyRatherThanJustBeingWrong() {
        for v6 in ["::1", "fe80::1/64", "2001:db8::1"] {
            guard let problem = TriggerCondition.subnetProblem(v6) else {
                return XCTFail("\(v6) can never match")
            }
            XCTAssertTrue(problem.contains("IPv6"), "\(v6): \(problem)")
        }
    }

    /// The most important test in this file: a trigger already represented
    /// by a live session must not fire again every tick.
    func testAlreadyActiveTriggerDoesNotFireAgain() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let already = Session(id: UUID(), kind: r.defaultKind.sessionKind(now: Date()),
                              owner: ClientID(rawValue: "agent"), ownerUID: 0,
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id, wakeMode: .clamshell, keepsDisksAwake: false)
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
                              owner: ClientID(rawValue: "agent"), ownerUID: 0,
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id, wakeMode: .clamshell, keepsDisksAwake: false)
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
                                    owner: ClientID(rawValue: "agent"), ownerUID: 0,
                                    persistence: .detached, origin: .trigger, startedAt: Date(),
                                    triggerID: other.id, wakeMode: .clamshell,
                                    keepsDisksAwake: false)
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

        let frontmostRule = rule(.appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(fire([frontmostRule],
                           frontmost: FakeFrontmostApp(frontmost: nil, reading: .undetermined)).isEmpty,
                      "a locked screen has no frontmost app, and that is not 'Xcode came to the front'")

        let vpnRule = rule(.vpnActive)
        XCTAssertTrue(fire([vpnRule], vpn: FakeVPN(.undetermined)).isEmpty,
                      "a network configuration that could not be read is not a connected VPN")

        let usbRule = rule(.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f))
        XCTAssertTrue(fire([usbRule], usbDevice: FakeUSBDevice(reading: .undetermined)).isEmpty,
                      "a USB tree that could not be enumerated is not a device being plugged in")
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
    /// Noon on a Wednesday, built from components so it is noon *locally*
    /// wherever this runs — the sample schedule is a weekday nine-to-six and is
    /// compared on wall-clock components, so a UTC literal would put CI outside
    /// the window and this suite would pass or fail by time zone.
    /// 3am on a Sunday: no day of the weekday sample is ticked and no hour of
    /// it is open, so the sample schedule is shut on both axes.
    private var outsideTheSampleSchedule: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 16  // a Sunday
        parts.hour = 3; parts.minute = 0
        return Calendar.current.date(from: parts)!
    }

    private var insideTheSampleSchedule: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 12  // a Wednesday
        parts.hour = 12; parts.minute = 0
        return Calendar.current.date(from: parts)!
    }

    private var everyObserverPresent: ObserverSet {
        ObserverSet(appRunning: FakeAppRunning(running: [], reading: .present),
                    display: FakeDisplay(external: false, reading: .present),
                    processRunning: FakeProcessRunning(running: [], reading: .present),
                    frontmostApp: FakeFrontmostApp(frontmost: nil, reading: .present),
                    mountedVolume: FakeMountedVolume(mounted: [], reading: .present),
                    networkAddress: FakeNetworkAddress(reading: .present),
                    vpn: FakeVPN(.present),
                    usbDevice: FakeUSBDevice(reading: .present),
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
                    frontmostApp: FakeFrontmostApp(frontmost: nil, reading: .undetermined),
                    mountedVolume: FakeMountedVolume(mounted: [], reading: .undetermined),
                    networkAddress: FakeNetworkAddress(reading: .undetermined),
                    vpn: FakeVPN(.undetermined),
                    usbDevice: FakeUSBDevice(reading: .undetermined),
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
                triggersToFire([r], activeSessions: [], observers: everyObserverPresent,
                               now: insideTheSampleSchedule).map(\.id), [r.id],
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
                // **Outside the window for `.onSchedule`, and that is the only
                // honest reading here.** Every other condition is silenced by
                // its observer failing; a clock has no failure to simulate, so
                // the analogue is a window that is legitimately shut. Handing
                // it a time *inside* the window instead would fail this
                // assertion for a condition that is behaving perfectly.
                triggersToFire([r], activeSessions: [], observers: everyObserverUndetermined,
                               now: outsideTheSampleSchedule).isEmpty,
                "\(kind) fires on an observation that failed")
        }
    }

    /// The mirror of `testNoConditionFiresWhenEveryObservationFailed` above, on
    /// the half that matters more. An observer that cannot answer must not be
    /// able to put a Mac to sleep — and that has to be true for **every** kind
    /// there is, including the one somebody adds next year, not only for the
    /// nine that happen to have their own test today.
    ///
    /// Carried-over debt from Plan 5's whole-plan review, and it is worth being
    /// precise about why it is here, because the obvious justification is
    /// false: **Plan 6 adds nothing that ends a session.** This is not forced by
    /// that plan's content. It is here because the guard is small, because it is
    /// on the more dangerous half of the loop, and because a known open defect
    /// that everybody agrees about and nobody closes is exactly how the CPU
    /// observer survived four plans.
    ///
    /// The gap it closes: `triggersToFire` — the *starting* direction — has had
    /// a generalised guard over `TriggerConditionKind.allCases` since Plan 5, so
    /// a tenth condition inherits the guarantee for free. `sessionsToEnd` — the
    /// *ending* direction, the one that puts a Mac to sleep mid-build — had only
    /// per-kind tests: `testUndeterminedNeverEndsAProcessSession`,
    /// `testAVolumeReadThatFailedNeverEndsASession`,
    /// `testANetworkReadThatFailedNeverEndsASession` and six more, nine in all,
    /// each written *after* somebody thought of it. A fourteenth `SessionKind`
    /// inherited nothing.
    ///
    /// Written over `SessionKind.Family.allCases` for the reason the CLI
    /// bijection test is: `SessionKind` cannot be `CaseIterable` (four cases
    /// carry values), so `Family` is the only trustworthy list of every kind
    /// there is, and a fourteenth kind cannot stay out of it — `SessionKind.
    /// family` is an exhaustive switch.
    ///
    /// **It lives in this file, not beside its nine ending-direction siblings in
    /// `EvidenceLoopTests`.** `everyObserverUndetermined` is `private` to this
    /// class, so the alternative was either dropping that `private` or copying
    /// the fixture — and a second `ObserverSet` full of `.undetermined`s is the
    /// two-lists-that-must-agree drift this project forbids: it would silently
    /// stop covering a tenth observer the day one is added to only one copy.
    /// Reusing it as-is costs one visibility decision nobody has to make, and it
    /// puts the two halves of one guarantee next to each other, which is an
    /// argument in its own right.
    ///
    /// `.lease`, `.duration` and `.untilTime` are deadline-driven and
    /// `sessionsToEnd` returns them untouched. That is correct behaviour, so the
    /// loop confirms it rather than excluding it — **and that turns out to be
    /// the half that was actually uncovered**, not the hypothetical fourteenth
    /// kind. Measured while writing this, by injecting the regression twice and
    /// running the whole suite each time:
    ///
    /// * Make `.whileVolumeMounted` end on `.undetermined` → this test fails
    ///   naming `while-volume-mounted` at run 2 of 4, and so does its per-kind
    ///   sibling `testAVolumeReadThatFailedNeverEndsASession`. Belt and braces.
    /// * Move `.whileOnACPower` out of the untouched arm and end it on a failed
    ///   read → **this test is the only one in 557 that fails.** Nothing else in
    ///   the suite covers the five kinds `sessionsToEnd` is supposed to return
    ///   untouched, because every per-kind sibling was written for a kind the
    ///   agent evaluates.
    ///
    /// So this is not only insurance against a kind nobody has written yet. It
    /// closes a live gap: the daemon-evaluated kinds could have been given an
    /// ending arm by accident, and no test would have said a word.
    func testNoSessionEndsWhenEveryObservationFailed() {
        var evidence = SessionEvidence()
        // Inside the weekday window `Family.whileOnSchedule`'s sample carries,
        // rather than an epoch offset that lands wherever the local zone puts
        // it. That kind has no failed reading to simulate — a clock always
        // answers — so the world in which "every observation failed" leaves it
        // running is one where its window is legitimately open. The runs below
        // advance a minute at a time and stay inside it.
        let start = insideTheSampleSchedule
        for family in SessionKind.Family.allCases {
            let session = Session(id: UUID(),
                                  kind: family.sampleKind(deadline: start.addingTimeInterval(86_400)),
                                  owner: ClientID(rawValue: "cli-501"), ownerUID: 0,
                                  persistence: .clientBound, origin: .manual, startedAt: start,
                                  triggerID: nil, wakeMode: .clamshell, keepsDisksAwake: false)
            // More runs than `negativesBeforeEnding`, because the bug this
            // guards against is a *stream* of failed reads accumulating into an
            // end — which is what the process observer's sysctl race actually
            // did. The clock advances a minute a run, so the four runs span
            // longer than `.whileCPUBusy`'s 120s sustained-quiet window: a CPU
            // arm that mistook "cannot read the CPU" for "the CPU went quiet"
            // would have had time to trip.
            for run in 0..<(SessionEvidence.negativesBeforeEnding + 2) {
                let now = start.addingTimeInterval(Double(run) * 60)
                XCTAssertTrue(
                    sessionsToEnd([session], observers: everyObserverUndetermined,
                                  evidence: &evidence, now: now).isEmpty,
                    "\(family.rawValue) ends a session on observations that all failed "
                    + "(run \(run + 1) of \(SessionEvidence.negativesBeforeEnding + 2))")
            }
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
                              owner: ClientID(rawValue: "agent"), ownerUID: 0,
                              persistence: .detached, origin: .trigger, startedAt: fire,
                              triggerID: r.id, wakeMode: .clamshell, keepsDisksAwake: false)
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

    // MARK: - One rule this build cannot read must not delete the rest
    //
    // `load()` decoded `[TriggerRule]` in a single `try?`, so one element this
    // build could not decode returned `[]` — every trigger the user configured
    // gone from the UI, with the file still on disk and the next edit
    // overwriting it for good. Plan 5 multiplies the exposure by six: a user who
    // runs a build with the new conditions and then runs an older one for any
    // reason (a downgrade, a second Mac, a stale copy in /Applications) hits it
    // with everything they have.

    /// The JSON `TriggerStore` really writes for a rule, as a dictionary, so a
    /// test can splice a hand-built element in among genuine ones rather than
    /// hand-writing all three and hoping they match the encoder.
    private func storedElement(_ rule: TriggerRule) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(rule),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// A rule written by a build that has a condition this one has never heard
    /// of — exactly what a downgrade sees. `wifiNetwork` is one of the six Plan
    /// 5 adds; today's `TriggerCondition` decoder has no case for it and throws,
    /// which is the whole scenario.
    private var futureRule: [String: Any] {
        ["id": "7F0C6C9E-3C6E-4A3C-9E52-2F5B1E0A77D1",
         "condition": ["wifiNetwork": ["ssid": "Studio", "band": 5, "hidden": false]],
         "defaultKind": "eightHours",
         "enabled": true]
    }

    private func writeStoredPayload(_ elements: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: elements) else {
            return XCTFail("could not build the payload")
        }
        PreferencesSuite.defaults.set(data, forKey: TriggerStore.key)
    }

    private func storedPayload() -> [Any] {
        guard let data = PreferencesSuite.defaults.data(forKey: TriggerStore.key),
              let elements = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return elements
    }

    /// The whole point: an unknown rule costs you that rule, not the file.
    func testAnUndecodableRuleDoesNotTakeTheOthersWithIt() {
        let good = rule(.acPowerConnected, kind: .oneHour)
        let alsoGood = rule(.externalDisplayConnected, kind: .fourHours, enabled: false)
        writeStoredPayload([storedElement(good), futureRule, storedElement(alsoGood)])

        let loaded = TriggerStore.load()
        XCTAssertEqual(loaded.count, 2, "one unreadable element must cost one rule, not all of them")
        XCTAssertTrue(loaded.contains(good))
        XCTAssertTrue(loaded.contains(alsoGood))
    }

    /// ...and saving afterwards must not be the thing that deletes it. A load
    /// that silently drops a rule, followed by any UI edit, writes the loss back
    /// to disk — which is the point at which it stops being recoverable by
    /// running the newer build again.
    func testSavingAfterASkippedRulePreservesTheUnreadableOne() {
        let good = rule(.acPowerConnected, kind: .oneHour)
        writeStoredPayload([storedElement(good), futureRule])

        // Exactly what the Settings UI does: load, change something, save.
        var rules = TriggerStore.load()
        // Not `rules[0]` directly: when this test is failing, the load has
        // usually returned nothing, and an out-of-range subscript traps the
        // whole test *process* — which takes the rest of the suite with it and
        // reports a crash instead of the one line that explains the fault.
        guard rules.count == 1 else {
            return XCTFail("the readable rule did not survive the load: \(rules.count) came back")
        }
        rules[0].enabled = false
        TriggerStore.save(rules)

        XCTAssertEqual(storedPayload().count, 2, "the rule this build cannot read was dropped by save()")
        let survivor = storedPayload().compactMap { $0 as? [String: Any] }
            .first { ($0["condition"] as? [String: Any])?["wifiNetwork"] != nil }
        XCTAssertNotNil(survivor, "the unreadable element is gone from the file")
        XCTAssertEqual(survivor?["id"] as? String, futureRule["id"] as? String)
        XCTAssertEqual(TriggerStore.load().first?.enabled, false, "the edit itself must still land")
    }

    /// The preserved element must come back to the newer build *unchanged* —
    /// preserving it as something subtly different is a slower version of the
    /// same data loss. Nested objects, a whole number that must not become
    /// `5.0`, a bool, a string and a null all survive the round trip.
    func testAPreservedRuleIsWrittenBackByteForByte() {
        writeStoredPayload([futureRule])
        TriggerStore.save(TriggerStore.load())

        guard let survivor = storedPayload().first as? [String: Any] else {
            return XCTFail("the unreadable element is gone")
        }
        XCTAssertEqual(NSDictionary(dictionary: survivor), NSDictionary(dictionary: futureRule))
    }

    /// The `NSDictionary` comparison above cannot see this one: `NSNumber`
    /// compares by value, so `5` and `5.0` are equal to it. 2^53+1 is the first
    /// integer a `Double` cannot hold — a preserver that kept every number as a
    /// `Double` would write it back as 2^53, silently, and the round trip would
    /// still look like a success.
    func testAPreservedRuleKeepsANumberNoDoubleCanHold() {
        let exact = 9_007_199_254_740_993
        var exotic = futureRule
        exotic["condition"] = ["wifiNetwork": ["ssid": "Studio", "lastSeen": exact]]
        writeStoredPayload([exotic])

        TriggerStore.save(TriggerStore.load())

        let survivor = storedPayload().first as? [String: Any]
        let condition = survivor?["condition"] as? [String: Any]
        let network = condition?["wifiNetwork"] as? [String: Any]
        XCTAssertEqual(network?["lastSeen"] as? Int, exact)
    }

    /// The structural half, and the reason `save()` re-reads the file rather
    /// than trusting something a previous `load()` remembered: a process that
    /// never called `load()` at all still cannot destroy the rule. There is no
    /// ordering to get wrong and no state to go stale.
    func testSavingWithoutEverLoadingStillKeepsTheUnreadableRule() {
        writeStoredPayload([futureRule])
        TriggerStore.save([rule(.acPowerConnected, kind: .oneHour)])

        XCTAssertEqual(storedPayload().count, 2)
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1)
    }

    /// Removing every rule the user can actually see is still not permission to
    /// delete the one they cannot.
    func testDeletingEveryVisibleRuleStillKeepsTheUnreadableOne() {
        writeStoredPayload([storedElement(rule(.acPowerConnected)), futureRule])
        TriggerStore.save([])

        XCTAssertEqual(storedPayload().count, 1)
        XCTAssertTrue(TriggerStore.load().isEmpty)
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1)
    }

    /// A readable rule must be written exactly once — the merge appends what was
    /// skipped, it does not append everything it read.
    func testASaveDoesNotDuplicateTheRulesItCanRead() {
        let good = rule(.acPowerConnected, kind: .oneHour)
        writeStoredPayload([storedElement(good), futureRule])
        TriggerStore.save(TriggerStore.load())
        TriggerStore.save(TriggerStore.load())

        XCTAssertEqual(storedPayload().count, 2)
        XCTAssertEqual(TriggerStore.load(), [good])
    }

    /// Skipping is for elements, not for the file. Data that is not an array of
    /// anything is not a rule store, and there is nothing in it to keep.
    func testCompletelyCorruptDataStillLoadsAsEmpty() {
        PreferencesSuite.defaults.set(Data([0xFF, 0x00, 0x13, 0x37]), forKey: TriggerStore.key)
        XCTAssertTrue(TriggerStore.load().isEmpty)
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0,
                       "nothing was skipped — the payload was never a rule array")

        PreferencesSuite.defaults.set(Data("{\"rules\":[]}".utf8), forKey: TriggerStore.key)
        XCTAssertTrue(TriggerStore.load().isEmpty)
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0)
    }

    /// No stored value at all is the first-run case, not a skip.
    func testNoStoredRulesLoadsAsEmptyWithNothingSkipped() {
        XCTAssertTrue(TriggerStore.load().isEmpty)
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0)
    }

    /// An element that is the right shape but decodes to nothing this build can
    /// use — a `defaultKind` from the future, say — is skipped and kept for the
    /// same reason a new condition is. The skip is not condition-specific.
    func testAnyUndecodableFieldSkipsJustThatRule() {
        let good = rule(.acPowerConnected)
        var futureDuration = storedElement(good)
        futureDuration["id"] = "0BE0F0B2-4B26-4C0E-8F0B-2E5C1A9D3E77"
        futureDuration["defaultKind"] = "twelveHours"
        writeStoredPayload([storedElement(good), futureDuration])

        XCTAssertEqual(TriggerStore.load(), [good])
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1)
    }

    // MARK: - The gap element-wise skipping does not close
    //
    // `StoredTriggerRule.init(from:)` is not total: it throws for a JSON number
    // outside `Double`'s finite range, and Foundation's synthesized array
    // decoder propagates that, failing the *whole* decode. The doc used to
    // claim decoding could not throw, which hid this. These pin what it really
    // costs, so the honest version cannot quietly revert to the false one.

    /// Raw bytes rather than `JSONSerialization`, because `1e999` is a payload
    /// `JSONSerialization` itself refuses to build ("Number wound up as NaN").
    /// `JSONDecoder`'s parser accepts it, which is the whole reason it reaches
    /// `JSONValue` at all.
    private func writeRawStoredPayload(_ json: String) {
        PreferencesSuite.defaults.set(Data(json.utf8), forKey: TriggerStore.key)
    }

    /// A number no `Double` can hold still costs the entire file. Stated as a
    /// test rather than left in a doc comment, because the last doc comment
    /// about this said the opposite.
    func testANumberOutsideDoublesRangeStillCostsTheWholeFile() {
        let good = rule(.acPowerConnected, kind: .oneHour)
        guard let goodJSON = try? JSONEncoder().encode(good),
              let goodText = String(data: goodJSON, encoding: .utf8)
        else { return XCTFail("could not build the readable element") }
        writeRawStoredPayload(
            "[\(goodText),{\"id\":\"7F0C6C9E-3C6E-4A3C-9E52-2F5B1E0A77D1\","
            + "\"condition\":{\"wifiNetwork\":{\"lastSeen\":1e999}},"
            + "\"defaultKind\":\"eightHours\",\"enabled\":true}]")

        XCTAssertTrue(TriggerStore.load().isEmpty,
                      "one unmodellable number fails the array decode, taking the readable rule too")
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0,
                       "nothing was skipped — the decode never got as far as an element")
    }

    /// ...but it is no longer *silent*. This is the distinction `loadStored()`
    /// cannot express: `[]` from an empty store and `[]` from a store that
    /// would not decode are the same value and very different facts.
    func testAnUndecodablePayloadIsDistinguishableFromAnEmptyOne() {
        XCTAssertFalse(TriggerStore.storedPayloadIsUndecodable,
                       "nothing stored is not a failure to read")

        TriggerStore.save([rule(.acPowerConnected)])
        XCTAssertFalse(TriggerStore.storedPayloadIsUndecodable,
                       "a payload this build wrote must read back cleanly")

        writeRawStoredPayload("[{\"condition\":{\"x\":{\"n\":1e999}}}]")
        XCTAssertTrue(TriggerStore.storedPayloadIsUndecodable,
                      "the one case where an empty load is not the whole truth")
    }

    /// The boundary the docs quote, measured rather than assumed: nesting is
    /// *not* a `JSONValue` limit. `JSONDecoder` refuses the document itself
    /// past 512 levels, so it lands in the "not a rule store at all" branch and
    /// never reaches an element.
    func testDeepNestingIsRefusedByTheParserRatherThanByJSONValue() {
        func nested(depth: Int) -> String {
            "[" + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "]"
        }
        writeRawStoredPayload(nested(depth: 512))
        XCTAssertFalse(TriggerStore.storedPayloadIsUndecodable,
                       "512 levels parse; the element is simply not a rule")
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1,
                       "an array of one non-rule element is one skipped element")

        writeRawStoredPayload(nested(depth: 513))
        XCTAssertTrue(TriggerStore.storedPayloadIsUndecodable,
                      "513 levels is refused by the parser, not by JSONValue")
    }

    // MARK: - A newer build that adds a *field* is dropped, not preserved
    //
    // `StoredTriggerRule.unreadable`'s doc used to say "any field this build
    // cannot decode lands here". Only a field whose decode *fails* does. A rule
    // carrying an unknown extra field decodes cleanly, because a synthesized
    // `init(from:)` ignores unknown keys — and the next save writes it back
    // without the field. `TriggerRule`'s doc comment is where the consequence
    // for Plan 7 is argued; these are the proof it is real.

    func testARuleWithAnUnknownFieldIsAcceptedAndLosesTheField() {
        let good = rule(.acPowerConnected, kind: .oneHour)
        var withFutureField = storedElement(good)
        withFutureField["bindsLifetime"] = true
        writeStoredPayload([withFutureField])

        XCTAssertEqual(TriggerStore.load(), [good],
                       "an unknown field does not make the rule unreadable — it is ignored")
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0,
                       "so nothing is counted, and the pane says nothing")

        TriggerStore.save(TriggerStore.load())

        let survivor = storedPayload().first as? [String: Any]
        XCTAssertEqual(survivor?["id"] as? String, storedElement(good)["id"] as? String)
        XCTAssertNil(survivor?["bindsLifetime"],
                     "the field is gone — this is the Plan 7 hazard, not a hypothetical")
    }

    /// The same thing one level down: a new key inside a condition this build
    /// already knows. The condition still decodes, so the rule is readable and
    /// the key is dropped.
    func testANewKeyInsideAKnownConditionIsAlsoDroppedRatherThanKept() {
        let good = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        var element = storedElement(good)
        element["condition"] = ["appLaunched": ["bundleID": "com.apple.dt.Xcode",
                                                "matchByExecutablePath": true]]
        writeStoredPayload([element])

        XCTAssertEqual(TriggerStore.load(), [good])
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0)

        TriggerStore.save(TriggerStore.load())

        let condition = (storedPayload().first as? [String: Any])?["condition"] as? [String: Any]
        let payload = condition?["appLaunched"] as? [String: Any]
        XCTAssertEqual(payload?["bundleID"] as? String, "com.apple.dt.Xcode")
        XCTAssertNil(payload?["matchByExecutablePath"],
                     "a new key in a known condition is dropped just as a new top-level field is")
    }

    /// The contrast that makes the hazard legible: change the condition's *wire
    /// name* and the rule is preserved verbatim instead. This is the shape Plan
    /// 7's field has to be given, and the reason `TriggerRule`'s doc argues for
    /// making the change undecodable rather than defaulted.
    func testAnUnknownConditionNameIsPreservedWhereAnUnknownFieldIsNot() {
        writeStoredPayload([futureRule])
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1)
        TriggerStore.save([])
        XCTAssertEqual(storedPayload().count, 1, "kept, where the unknown field was dropped")
    }

    /// What the UI needs to be able to say "one of your triggers was made by a
    /// newer version and isn't shown here" — a rule that is silently invisible
    /// is a milder failure than one that is silently deleted, but the user
    /// should still not have to discover it.
    func testTheSkippedCountIsAvailableToTheUI() {
        writeStoredPayload([storedElement(rule(.acPowerConnected)), futureRule, futureRule])
        let stored = TriggerStore.loadStored()
        XCTAssertEqual(stored.compactMap(\.rule).count, 1)
        XCTAssertEqual(stored.unreadableCount, 2)
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

    /// Task 6's design decision, pinned rather than left in a comment. "While
    /// this app is frontmost" is a session that ends because you glanced at a
    /// browser: the tick is 5s and two confident negatives end a session, so
    /// eleven seconds in another window would stop it. `.whileAppRunning` is
    /// the durable version and already exists. A later change of heart here
    /// has to turn this red first.
    func testFrontmostAppDeliberatelyDoesNotBindTheSessionsLifetime() {
        XCTAssertFalse(TriggerConditionKind.appFrontmost.bindsSessionLifetime)
        XCTAssertNil(TriggerCondition.appFrontmost(bundleID: "com.apple.dt.Xcode").boundSessionKind)
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

    // MARK: - The candidate table
    //
    // `boundSessionKind` answers "what does this condition bind to when nobody
    // said otherwise". `candidateBoundSessionKind` answers "what *could* a rule
    // on this condition bind to". The first is about rules people already saved;
    // the second is about rules they have not written yet, and conflating them is
    // what kept `.whileExternalDisplay` and `.whileOnACPower` unreachable from
    // the Triggers pane for four plans.

    /// The relationship, in the direction that must hold: a condition that binds
    /// by default must be *able* to bind, and to the same thing. The reverse does
    /// not hold and that is the point of having two tables.
    func testWhateverBindsByDefaultIsAlsoACandidateAndTheyAgree() {
        for kind in TriggerConditionKind.allCases {
            let condition = kind.sampleCondition
            guard let bound = condition.boundSessionKind else { continue }
            XCTAssertEqual(condition.candidateBoundSessionKind, bound,
                           "\(kind): the default table and the candidate table disagree")
        }
    }

    /// The three the old table refused *for existing rules' sake*, and which a
    /// new rule may now ask for. Each is a real new capability rather than a
    /// re-spelling: before this, no trigger could end a session when the app
    /// quit, the display was unplugged, or the charger came out.
    func testTheThreeNewCandidatesAreExactlyTheOnesTheDefaultTableRefuses() {
        XCTAssertEqual(TriggerCondition.appLaunched(bundleID: "com.apple.dt.Xcode")
                        .candidateBoundSessionKind,
                       .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(TriggerCondition.externalDisplayConnected.candidateBoundSessionKind,
                       .whileExternalDisplay)
        XCTAssertEqual(TriggerCondition.acPowerConnected.candidateBoundSessionKind,
                       .whileOnACPower)
        for condition: TriggerCondition in [.appLaunched(bundleID: "com.apple.dt.Xcode"),
                                            .externalDisplayConnected, .acPowerConnected] {
            XCTAssertNil(condition.boundSessionKind,
                         "\(condition) must still not bind by default — rules people already "
                         + "saved mean 'start a timed session', and changing that under them is "
                         + "the objection the default table exists for")
        }
    }

    /// `.appFrontmost` is the one condition with no candidate at all, and it is a
    /// deliberate refusal rather than an omission: frontmost flickers, so a
    /// session bound to it ends after an eleven-second glance at a browser. A
    /// later change of heart has to turn this red first.
    func testFrontmostAppIsTheOnlyConditionWithNoCandidateAtAll() {
        let withoutCandidate = TriggerConditionKind.allCases
            .filter { $0.sampleCondition.candidateBoundSessionKind == nil }
        XCTAssertEqual(withoutCandidate, [.appFrontmost])
    }

    /// A candidate must carry the condition's associated value through, not a
    /// stand-in — a `.whileVolumeMounted(name: "")` would end the instant it
    /// started.
    func testACandidateCarriesTheConditionsOwnValue() {
        XCTAssertEqual(TriggerCondition.volumeMounted(name: "Backup").candidateBoundSessionKind,
                       .whileVolumeMounted(name: "Backup"))
        XCTAssertEqual(TriggerCondition.onSubnet(cidr: "10.0.0.0/8").candidateBoundSessionKind,
                       .whileOnSubnet(cidr: "10.0.0.0/8"))
        XCTAssertEqual(TriggerCondition.usbDevicePresent(vendorID: 0x05ac, productID: 0x024f)
                        .candidateBoundSessionKind,
                       .whileUSBDevicePresent(vendorID: 0x05ac, productID: 0x024f))
    }

    // MARK: - The default effect reproduces the old behaviour exactly
    //
    // The whole backward-compatibility claim of Plan 8 Task 10, stated as a test
    // over every condition rather than as a sentence about a few of them.

    /// A rule with no stored effect starts precisely what the pre-Task-10 line
    /// started — `condition.boundSessionKind ?? defaultKind.sessionKind(now:)` —
    /// and asks the machine for precisely what `EvidenceLoopRunner` used to
    /// hardcode. Both halves, for every condition there is.
    func testARuleWithNoStoredEffectBehavesExactlyAsItDidBefore() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        for kind in TriggerConditionKind.allCases {
            let condition = kind.sampleCondition
            let r = rule(condition, kind: .fourHours)
            XCTAssertEqual(sessionKind(firing: r, now: now),
                           condition.boundSessionKind ?? r.defaultKind.sessionKind(now: now),
                           "\(kind): a rule nobody edited now starts a different session")
            XCTAssertEqual(r.effect.power,
                           PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false),
                           "\(kind): the two literals EvidenceLoopRunner used to hardcode")
        }
    }

    /// ...and the same claim about a rule that came off *disk* in the old
    /// four-key shape, which is the form every rule any user has is actually in.
    func testAStoredRuleWithNoEffectKeyDecodesToTheOldBehaviour() throws {
        let now = Date(timeIntervalSince1970: 5_000_000)
        for kind in TriggerConditionKind.allCases {
            let condition = kind.sampleCondition
            let element = storedElement(rule(condition, kind: .fourHours))
            XCTAssertEqual(Set(element.keys), ["id", "condition", "defaultKind", "enabled"],
                           "\(kind): a rule with the default effect must be written in the exact "
                           + "four-key shape every previous build wrote and reads")
            let data = try JSONSerialization.data(withJSONObject: element)
            let decoded = try JSONDecoder().decode(TriggerRule.self, from: data)
            XCTAssertEqual(decoded.effect, TriggerEffect.default(for: condition), "\(kind)")
            XCTAssertEqual(sessionKind(firing: decoded, now: now),
                           condition.boundSessionKind ?? decoded.defaultKind.sessionKind(now: now),
                           "\(kind)")
        }
    }

    func testTheDefaultLifetimeIsTheConditionsOwnAnswer() {
        for kind in TriggerConditionKind.allCases {
            XCTAssertEqual(TriggerEffect.defaultLifetime(for: kind) == .whileConditionHolds,
                           kind.bindsSessionLifetime, "\(kind)")
            XCTAssertEqual(TriggerEffect.default(for: kind.sampleCondition).lifetime,
                           TriggerEffect.defaultLifetime(for: kind), "\(kind)")
        }
    }

    // MARK: - A rule chooses, and the pipeline obeys

    /// The first half of the new capability: a condition that binds by default
    /// can be told to run for a duration instead.
    func testARuleCanAskForADurationOnAConditionThatBindsByDefault() {
        let now = Date(timeIntervalSince1970: 6_000_000)
        for kind in TriggerConditionKind.allCases where kind.bindsSessionLifetime {
            let condition = kind.sampleCondition
            let r = rule(condition, kind: .fourHours,
                         effect: TriggerEffect(power: TriggerEffect.defaultPower,
                                               lifetime: .forDuration))
            XCTAssertEqual(sessionKind(firing: r, now: now), .duration(until: now.addingTimeInterval(4 * 3600)),
                           "\(kind) was told to run for four hours and did not")
        }
    }

    /// The second half, and the one that reaches three `SessionKind`s no trigger
    /// could produce before: a condition that does *not* bind by default can be
    /// told to.
    func testARuleCanAskToBindOnAConditionThatDoesNotByDefault() {
        let now = Date(timeIntervalSince1970: 6_000_000)
        for kind in TriggerConditionKind.allCases where !kind.bindsSessionLifetime {
            let condition = kind.sampleCondition
            guard let candidate = condition.candidateBoundSessionKind else {
                XCTAssertEqual(kind, .appFrontmost, "only .appFrontmost may have no candidate")
                continue
            }
            let r = rule(condition, kind: .fourHours,
                         effect: TriggerEffect(power: TriggerEffect.defaultPower,
                                               lifetime: .whileConditionHolds))
            XCTAssertEqual(sessionKind(firing: r, now: now), candidate, "\(kind)")
        }
    }

    /// The combination nobody may reach from the UI, and what the pure function
    /// does when it is handed one anyway — a hand-edited store, or a future build
    /// that gives `.appFrontmost` a candidate and is then downgraded to this one.
    ///
    /// It falls back to the duration, which is the only other thing it can
    /// return and is the safe direction: a session with a deadline rather than
    /// one that never ends. Pinned so that "silently indefinite" cannot become
    /// the answer by accident.
    func testARuleThatAskedToBindToAConditionWithNoCandidateFallsBackToItsDuration() {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let r = rule(.appFrontmost(bundleID: "com.apple.dt.Xcode"), kind: .oneHour,
                     effect: TriggerEffect(power: TriggerEffect.defaultPower,
                                           lifetime: .whileConditionHolds))
        XCTAssertNil(r.condition.candidateBoundSessionKind)
        XCTAssertEqual(sessionKind(firing: r, now: now), .duration(until: now.addingTimeInterval(3600)))
    }

    /// ...and the boundary that stores rules refuses to write it in the first
    /// place, so the fallback above is a backstop rather than a route.
    func testChosenRefusesALifetimeTheConditionCannotHonour() {
        let effect = TriggerEffect.chosen(power: TriggerEffect.defaultPower,
                                          lifetime: .whileConditionHolds,
                                          for: .appFrontmost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(effect.lifetime, .forDuration)

        // ...and keeps it everywhere it can be honoured, including the three
        // conditions that do not bind by default.
        for kind in TriggerConditionKind.allCases where kind != .appFrontmost {
            XCTAssertEqual(TriggerEffect.chosen(power: TriggerEffect.defaultPower,
                                                lifetime: .whileConditionHolds,
                                                for: kind.sampleCondition).lifetime,
                           .whileConditionHolds, "\(kind)")
        }
    }

    /// The power axis, through the one function the agent reads. It is not
    /// test-reachable in `Agent/EvidenceLoopRunner.swift` — that file is in no
    /// target the tests link — so what is pinned here is that the rule carries
    /// the request at all, and the line that reads it is verified by reading plus
    /// a green agent build.
    func testARuleCarriesWhateverPowerRequestItWasGiven() {
        for mode in WakeMode.allCases {
            for disks in [false, true] {
                let power = PowerRequest(wakeMode: mode, keepsDisksAwake: disks)
                let r = rule(.acPowerConnected,
                             effect: TriggerEffect(power: power, lifetime: .forDuration))
                XCTAssertEqual(r.effect.power, power)
            }
        }
    }
}

/// **What an older build does with a rule this one wrote, proved rather than
/// argued.**
///
/// `TriggerRule`'s doc comment used to prescribe making the new field
/// undecodable to older builds outright, on the grounds that such a rule lands
/// in `StoredTriggerRule.unreadable` and is preserved. That is true of every
/// build from Plan 5 onward and **false of the only build that has ever
/// shipped**, which has no `StoredTriggerRule` at all — so this file replicates
/// both older stores rather than reasoning about either.
///
/// The replicas are written from `git show v0.1.0:Shared/TriggerRule.swift`, not
/// from memory: v0.1.0 is the only old build that exists, and a replica of a
/// remembered one would prove nothing.
final class TriggerRuleDowngradeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    // MARK: - The replicas

    /// v0.1.0's whole `TriggerCondition`: three cases, synthesized `Codable`.
    private enum V010Condition: Codable, Equatable {
        case appLaunched(bundleID: String)
        case externalDisplayConnected
        case acPowerConnected
    }

    /// v0.1.0's whole `TriggerRule`: four fields, synthesized `Codable`.
    ///
    /// `DefaultSessionKind` is the shipping type rather than a fourth replica
    /// because it is byte-identical at v0.1.0 — same four cases, same raw values
    /// — which `testTheReplicaMatchesTheBuildItClaimsToBe` checks rather than
    /// assumes.
    private struct V010Rule: Codable, Equatable {
        let id: UUID
        var condition: V010Condition
        var defaultKind: DefaultSessionKind
        var enabled: Bool
    }

    /// Plan 5's `StoredTriggerRule`, over the v0.1.0 rule shape: the
    /// skip-and-preserve machinery as it exists in every build between v0.1.0
    /// and this one. `JSONValue` is the shipping type because it is the same
    /// type those builds have.
    private enum V010StoredRule: Codable, Equatable {
        case readable(V010Rule)
        case unreadable(JSONValue)

        var rule: V010Rule? {
            if case .readable(let rule) = self { return rule }
            return nil
        }

        init(from decoder: Decoder) throws {
            if let rule = try? V010Rule(from: decoder) {
                self = .readable(rule)
                return
            }
            self = .unreadable(try JSONValue(from: decoder))
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .readable(let rule): try rule.encode(to: encoder)
            case .unreadable(let json): try json.encode(to: encoder)
            }
        }
    }

    /// v0.1.0's whole `TriggerStore.load()`, verbatim:
    /// `guard let data = …, let rules = try? decode([TriggerRule].self) else { return [] }`.
    /// Its `save()` then writes whatever this returned back over the file.
    private func v010Load(_ data: Data) -> [V010Rule] {
        (try? JSONDecoder().decode([V010Rule].self, from: data)) ?? []
    }

    private func rule(_ condition: TriggerCondition, kind: DefaultSessionKind = .fourHours,
                      effect: TriggerEffect? = nil) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, defaultKind: kind, enabled: true,
                    effect: effect ?? TriggerEffect.default(for: condition))
    }

    private var nonDefaultEffect: TriggerEffect {
        TriggerEffect(power: PowerRequest(wakeMode: .systemAndDisplay, keepsDisksAwake: true),
                      lifetime: .whileConditionHolds)
    }

    /// The shape a v0.1.0 build actually wrote, hand-built from that build's
    /// source rather than produced by this one's encoder — which is the only way
    /// step 5 below can claim anything.
    private var v010Payload: Data {
        Data("""
        {"id":"7F0C6C9E-3C6E-4A3C-9E52-2F5B1E0A77D1","condition":{"acPowerConnected":{}},\
        "defaultKind":"fourHours","enabled":true}
        """.utf8)
    }

    private func writeStoredPayload(_ elements: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: elements) else {
            return XCTFail("could not build the payload")
        }
        PreferencesSuite.defaults.set(data, forKey: TriggerStore.key)
    }

    private func storedPayload() -> [Any] {
        guard let data = PreferencesSuite.defaults.data(forKey: TriggerStore.key),
              let elements = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return elements
    }

    private func jsonObject(_ rule: TriggerRule) throws -> [String: Any] {
        let data = try JSONEncoder().encode(rule)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("a rule did not encode as a JSON object")
        }
        return object
    }

    /// The replica is only evidence if it is a replica. `DefaultSessionKind` is
    /// shared with the shipping build, so its wire names are pinned here against
    /// the four v0.1.0 shipped.
    func testTheReplicaMatchesTheBuildItClaimsToBe() {
        XCTAssertEqual(Set(DefaultSessionKind.allCases.map(\.rawValue)),
                       ["indefinite", "oneHour", "fourHours", "eightHours"])
        XCTAssertNoThrow(try JSONDecoder().decode(V010Rule.self, from: v010Payload),
                         "the replica cannot read the payload v0.1.0 wrote")
    }

    // MARK: - (2) A rule with the default effect survives the downgrade

    /// **The load-bearing one.** Every rule any user has today, and every rule
    /// anybody writes without touching the new controls, must read back in
    /// v0.1.0 exactly as it does now — because against *that* build
    /// "undecodable" does not mean "hidden", it means "deleted on the next
    /// save".
    func testARuleWithTheDefaultEffectStillDecodesInTheOldestBuild() throws {
        let mine = rule(.acPowerConnected, kind: .eightHours)
        let decoded = try JSONDecoder().decode(V010Rule.self, from: JSONEncoder().encode(mine))

        XCTAssertEqual(decoded.id, mine.id)
        XCTAssertEqual(decoded.condition, .acPowerConnected)
        XCTAssertEqual(decoded.defaultKind, .eightHours)
        XCTAssertEqual(decoded.enabled, true)
    }

    /// ...and the object it wrote has the old key set and nothing else, which is
    /// the fact the decode above depends on. Stated separately so a decoder that
    /// happened to tolerate an extra key could not hide an encoder that added
    /// one.
    func testADefaultEffectRuleIsWrittenInExactlyTheOldFourKeyShape() throws {
        for kind in TriggerConditionKind.allCases {
            let object = try jsonObject(rule(kind.sampleCondition))
            XCTAssertEqual(Set(object.keys), ["id", "condition", "defaultKind", "enabled"], "\(kind)")
        }
    }

    // MARK: - (3) A rule that uses the new field does not

    func testARuleWithANonDefaultEffectIsUndecodableToTheOldestBuild() throws {
        let mine = rule(.acPowerConnected, effect: nonDefaultEffect)
        let data = try JSONEncoder().encode(mine)

        XCTAssertThrowsError(try JSONDecoder().decode(V010Rule.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected a missing-key failure, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "condition",
                           "the whole mechanism is that the old build's required `condition` "
                           + "decode finds nothing")
        }
    }

    func testANonDefaultEffectRuleMovesItsConditionToTheNewKeyAndCarriesTheEffect() throws {
        let object = try jsonObject(rule(.acPowerConnected, effect: nonDefaultEffect))
        XCTAssertEqual(Set(object.keys), ["id", "conditionV2", "effect", "defaultKind", "enabled"])
        XCTAssertNil(object["condition"])
    }

    /// Both directions of the one rule that decides the wire shape, over every
    /// condition: default effect ⇒ old shape ⇒ old build reads it; anything else
    /// ⇒ new shape ⇒ old build throws. No condition may be an exception.
    func testTheWireShapeFollowsTheEffectForEveryCondition() throws {
        for kind in TriggerConditionKind.allCases {
            let condition = kind.sampleCondition
            let defaulted = try JSONEncoder().encode(rule(condition))
            let chosen = try JSONEncoder().encode(
                rule(condition, effect: TriggerEffect(
                    power: PowerRequest(wakeMode: .system, keepsDisksAwake: true),
                    lifetime: TriggerEffect.default(for: condition).lifetime)))

            let defaultedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: defaulted) as? [String: Any])
            let chosenObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: chosen) as? [String: Any])
            XCTAssertNotNil(defaultedObject["condition"], "\(kind)")
            XCTAssertNil(defaultedObject["effect"], "\(kind)")
            XCTAssertNotNil(chosenObject["conditionV2"], "\(kind)")
            XCTAssertNotNil(chosenObject["effect"], "\(kind)")
        }
    }

    // MARK: - (4) …and every build with the preserve machinery keeps it

    /// A Plan 5-or-later build reading a rule this one wrote: the element fails
    /// to decode, so it lands in `unreadable`, is counted, is hidden from the
    /// pane, and comes back **verbatim** when that build saves. This is the job
    /// the whole design is aimed at, and it is checked against a replica of that
    /// build's store rather than against this one's, because this build can read
    /// its own payload perfectly well.
    func testAnIntermediateBuildHidesTheNewRuleAndWritesItBackUntouched() throws {
        let ordinary = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), kind: .oneHour)
        let advanced = rule(.acPowerConnected, effect: nonDefaultEffect)
        let payload = try JSONEncoder().encode([ordinary, advanced])

        let stored = try JSONDecoder().decode([V010StoredRule].self, from: payload)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.compactMap(\.rule).count, 1,
                       "the ordinary rule must still be readable to that build")
        XCTAssertEqual(stored.filter { $0.rule == nil }.count, 1,
                       "…and the one using the new field must be hidden, not misread")
        XCTAssertEqual(stored.compactMap(\.rule).first?.id, ordinary.id)

        // What that build's `save()` writes back.
        let rewritten = try JSONEncoder().encode(stored)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [[String: Any]])
        XCTAssertEqual(NSArray(array: after), NSArray(array: before),
                       "the preserved element came back changed")

        // …and this build reads its own rule back out of what that build wrote.
        let roundTripped = try JSONDecoder().decode([TriggerRule].self, from: rewritten)
        XCTAssertEqual(roundTripped, [ordinary, advanced])
    }

    /// The same chain through the **real** `TriggerStore`, using the next rung of
    /// the ladder `TriggerRule.CodingKeys` documents: a payload from a future
    /// build that moved the condition to `conditionV3`. This build cannot decode
    /// it, and must therefore hide it, count it, and keep it.
    func testThisBuildHidesAndKeepsARuleFromTheNextBreakInTheLadder() throws {
        let mine = rule(.acPowerConnected, kind: .oneHour)
        let future: [String: Any] = [
            "id": "3C6E4A3C-7F0C-6C9E-9E52-2F5B1E0A77D1",
            "conditionV3": ["volumeMounted": ["name": "Backup"]],
            "effect": ["power": ["wakeMode": "system", "keepsDisksAwake": true],
                       "lifetime": "whileConditionHolds",
                       "thermalCeiling": 0.75],
            "defaultKind": "oneHour", "enabled": true,
        ]
        writeStoredPayload([try jsonObject(mine), future])

        XCTAssertEqual(TriggerStore.load(), [mine], "one unreadable element costs one rule")
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 1)
        XCTAssertFalse(TriggerStore.storedPayloadIsUndecodable)

        TriggerStore.save(TriggerStore.load())

        let survivor = storedPayload().compactMap { $0 as? [String: Any] }
            .first { $0["conditionV3"] != nil }
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(survivor)),
                       NSDictionary(dictionary: future),
                       "the future rule was not written back verbatim")
    }

    // MARK: - (5) The other direction: this build reads what v0.1.0 wrote

    /// The half the old doc comment never considered. A *required* `decode` for
    /// the new key — the route it recommended — would throw here, so the new
    /// build could not show a user a single rule they already have. Measured
    /// before this task was designed; pinned so nobody re-adopts that route.
    func testAPayloadWrittenByTheOldestBuildStillReadsHere() throws {
        let decoded = try JSONDecoder().decode(TriggerRule.self, from: v010Payload)

        XCTAssertEqual(decoded.condition, .acPowerConnected)
        XCTAssertEqual(decoded.defaultKind, .fourHours)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.effect, TriggerEffect.default(for: .acPowerConnected),
                       "an absent effect is the one that reproduces the old behaviour")
        XCTAssertEqual(sessionKind(firing: decoded, now: Date(timeIntervalSince1970: 100)),
                       .duration(until: Date(timeIntervalSince1970: 100 + 4 * 3600)))
    }

    /// A rule with **neither** condition key is not a rule, and must fail rather
    /// than default to something. The one thing the two-key decode must not
    /// become is "tolerant".
    func testARuleWithNoConditionAtAllStillFails() {
        let data = Data("""
        {"id":"7F0C6C9E-3C6E-4A3C-9E52-2F5B1E0A77D1","defaultKind":"oneHour","enabled":true}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TriggerRule.self, from: data))
    }

    /// A *present* condition this build has never heard of must still throw,
    /// which is what keeps such a rule preserved rather than silently reshaped.
    /// `decodeIfPresent` answers nil only for an absent key or an explicit null,
    /// and this is the test that says so out loud.
    func testAnUnknownConditionUnderTheOldKeyStillFails() {
        let data = Data("""
        {"id":"7F0C6C9E-3C6E-4A3C-9E52-2F5B1E0A77D1",\
        "condition":{"wifiNetwork":{"ssid":"Studio"}},"defaultKind":"oneHour","enabled":true}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TriggerRule.self, from: data))
    }

    // MARK: - (6) The whole struct, with nothing at its default

    /// The test that catches a field the hand-written encoder forgot.
    ///
    /// `TriggerRule` lost its synthesized `Codable` in Plan 8 Task 10, which
    /// buys the conditional wire shape and costs exactly this: an encoder that
    /// must be updated for every future field, with no compiler to say so. Every
    /// value here is away from its default, and the comparison is of the whole
    /// struct, so a dropped field cannot pass by matching a default.
    func testEveryFieldOfARuleSurvivesARoundTripWithNothingAtItsDefault() throws {
        for lifetime in TriggerLifetime.allCases {
            for mode in WakeMode.allCases {
                for disks in [false, true] {
                    let original = TriggerRule(
                        id: UUID(uuidString: "0BE0F0B2-4B26-4C0E-8F0B-2E5C1A9D3E77")!,
                        condition: .usbDevicePresent(vendorID: 0x05ac, productID: 0x024f),
                        defaultKind: .eightHours,
                        enabled: false,
                        effect: TriggerEffect(
                            power: PowerRequest(wakeMode: mode, keepsDisksAwake: disks),
                            lifetime: lifetime))
                    let decoded = try JSONDecoder().decode(
                        TriggerRule.self, from: JSONEncoder().encode(original))
                    XCTAssertEqual(decoded, original, "\(lifetime) \(mode) \(disks)")
                }
            }
        }
    }

    /// The same round trip through the real store, so the wire shape is proved
    /// against `UserDefaults` and not only against `JSONEncoder`.
    func testBothWireShapesRoundTripThroughTheRealStore() {
        let ordinary = rule(.volumeMounted(name: "Backup"))
        let advanced = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"),
                            effect: nonDefaultEffect)
        TriggerStore.save([ordinary, advanced])

        XCTAssertEqual(TriggerStore.load(), [ordinary, advanced])
        XCTAssertEqual(TriggerStore.loadStored().unreadableCount, 0)
    }

    // MARK: - (7) The v0.1.0 destruction path, pinned so nobody widens it

    /// **Why "a rule the user never touched stays byte-compatible" is a
    /// data-preservation guarantee and not a nicety.**
    ///
    /// v0.1.0 has no element-wise skipping: one element it cannot decode fails
    /// the whole array, `load()` answers `[]`, and the next `save()` writes that
    /// over the file. So against the only shipped build an undecodable element is
    /// not hidden — every rule the user has is deleted.
    func testAnOldStoreDestroysEverythingWhenOneElementIsUndecodable() throws {
        let ordinary = rule(.acPowerConnected, kind: .oneHour)
        let advanced = rule(.externalDisplayConnected, effect: nonDefaultEffect)
        let payload = try JSONEncoder().encode([ordinary, advanced])

        XCTAssertTrue(v010Load(payload).isEmpty,
                      "v0.1.0 answers [] for the whole file, and its save() then writes that back")
    }

    /// ...and the assertion that bounds the exposure: a file of rules that all
    /// have the default effect survives v0.1.0 completely intact. This is the
    /// requirement the conditional wire shape exists to meet, and it is what
    /// makes the design smaller than "everything this build writes goes opaque".
    func testAnOldStoreKeepsEveryDefaultEffectRuleIntact() throws {
        let rules = [rule(.acPowerConnected, kind: .oneHour),
                     rule(.externalDisplayConnected, kind: .eightHours),
                     rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), kind: .indefinite)]
        let survivors = v010Load(try JSONEncoder().encode(rules))

        XCTAssertEqual(survivors.count, rules.count, "v0.1.0 lost a rule it should have kept")
        XCTAssertEqual(survivors.map(\.id), rules.map(\.id))
        XCTAssertEqual(survivors.map(\.defaultKind), rules.map(\.defaultKind))
    }

    /// The exposure that already existed and which this change must not enlarge:
    /// a rule using any of Plan 5's six conditions is *already* undecodable to
    /// v0.1.0, whatever its effect. Stated as a test so "the new field made this
    /// worse" is answerable with a fact.
    func testPlan5sConditionsAlreadyDestroyedAnOldStoreBeforeThisChange() throws {
        let payload = try JSONEncoder().encode([rule(.acPowerConnected, kind: .oneHour),
                                                rule(.volumeMounted(name: "Backup"))])
        XCTAssertTrue(v010Load(payload).isEmpty,
                      "a .volumeMounted rule with the DEFAULT effect already does this — the "
                      + "population at risk is not enlarged by the new field")
    }
}
