import XCTest
@testable import KeepyUppy

final class SafetyConfigStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // This used to clear `PreferencesSuite.name` — which, in this
        // process, was the *shipping* preference domain, so the isolation
        // line was itself deleting the live user's safety configuration. See
        // `PreferencesSuiteIsolationTests` below and `PreferencesSuite.name`
        // for the redirect that fixed it.
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    func testLoadWithNothingSavedReturnsDefault() {
        XCTAssertEqual(SafetyConfigStore.load().thermalSensitivity, SafetyConfig.default.thermalSensitivity)
    }

    func testSaveThenLoadRoundTrips() {
        var config = SafetyConfig.default
        config.thermalSensitivity = .cautious
        config.batteryCutoff = 20
        SafetyConfigStore.save(config)

        let loaded = SafetyConfigStore.load()
        XCTAssertEqual(loaded.thermalSensitivity, .cautious)
        XCTAssertEqual(loaded.batteryCutoff, 20)
    }

    // MARK: - Reading a named user's config (what the root daemon does)

    func testAccountLookupResolvesTheCurrentUser() {
        let account = PreferencesSuite.account(forUserID: getuid())
        XCTAssertEqual(account?.userName, NSUserName())
        XCTAssertEqual(account?.homeDirectory, NSHomeDirectory())
    }

    func testAccountLookupForAUserThatDoesNotExistIsNil() {
        XCTAssertNil(PreferencesSuite.account(forUserID: 999_999))
    }

    func testLoadForAUserIDThatDoesNotExistIsNil() {
        XCTAssertNil(SafetyConfigStore.load(forUserID: 999_999))
    }

    /// The `CFPreferencesCopyValue` half. Naming the *current* user
    /// explicitly exercises exactly the call the daemon makes for a
    /// different user — the parameter is resolved the same way either way,
    /// and this is the half that proves an explicit user name works at all.
    func testLoadForUserNamedReadsWhatThisUserSaved() {
        var config = SafetyConfig.default
        config.thermalSensitivity = .off
        config.maxSessionDuration = nil
        SafetyConfigStore.save(config)

        XCTAssertEqual(SafetyConfigStore.load(forUserNamed: NSUserName()), config)
    }

    func testLoadForAUserNameThatDoesNotExistIsNil() {
        SafetyConfigStore.save(.default)
        XCTAssertNil(SafetyConfigStore.load(forUserNamed: "no-such-account-here"))
    }

    /// The on-disk half, against a purpose-built home directory — the path
    /// the daemon actually takes, since root reads a *different* user's
    /// `~/Library/Preferences` file rather than being served from its own
    /// preferences cache.
    func testLoadFromHomeDirectoryReadsAPreferencesPlist() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SafetyConfigStoreTests-\(UUID().uuidString)")
        let preferences = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var config = SafetyConfig.default
        config.thermalSensitivity = .permissive
        config.batteryCutoff = nil
        config.cooldown = 42
        let plist = ["safetyConfig": try JSONEncoder().encode(config)]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: preferences.appendingPathComponent("\(PreferencesSuite.name).plist"))

        XCTAssertEqual(SafetyConfigStore.load(fromHomeDirectory: home.path), config)
    }

    func testLoadFromAHomeDirectoryWithNoPreferencesPlistIsNil() {
        let missing = NSTemporaryDirectory() + "/nothing-here-\(UUID().uuidString)"
        XCTAssertNil(SafetyConfigStore.load(fromHomeDirectory: missing))
    }

    /// A plist that exists but holds something that is not an encoded
    /// `SafetyConfig` must read as "nothing", so the daemon keeps its last
    /// good config rather than adopting a corrupt one.
    func testLoadFromHomeDirectoryWithAnUndecodableValueIsNil() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SafetyConfigStoreTests-\(UUID().uuidString)")
        let preferences = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let plist = ["safetyConfig": Data("not json".utf8)]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: preferences.appendingPathComponent("\(PreferencesSuite.name).plist"))

        XCTAssertNil(SafetyConfigStore.load(fromHomeDirectory: home.path))
    }
}

/// The suite these tests are allowed to touch.
///
/// Every other file in this target writes real payloads through
/// `PreferencesSuite` — trigger rules, safety configuration, completed
/// sessions — and until this class existed they wrote them into the shipping
/// app's preference domain, because `Keepy UppyTests` is hosted by the app and
/// therefore shares its bundle identifier. The three `setUp`s meant to isolate
/// the tests from each other were deleting the live user's configuration on
/// every run: default session kind, default wake mode, safety settings and all
/// of their trigger rules.
///
/// These are the tripwire for that. They assert the property directly rather
/// than trusting the mechanism, so a change to `project.yml`, to the runner, or
/// to `PreferencesSuite.isRunningTests` that quietly restores the old behaviour
/// fails here — instead of being discovered by a user whose triggers vanished.
final class PreferencesSuiteIsolationTests: XCTestCase {
    func testTheRunnerIsDetectedAtAll() {
        XCTAssertTrue(PreferencesSuite.isRunningTests,
                      "nothing below can hold if the process cannot tell it is a test run")
    }

    func testTheSuiteUnderTestIsNotTheShippingOne() {
        XCTAssertNotEqual(PreferencesSuite.name, PreferencesSuite.productionName,
                          "these tests would be reading and writing the real user's preferences")
    }

    /// The invariant the whole class exists for, checked against the domain
    /// itself rather than against the name: a value written the way every
    /// store writes must not be visible in the shipping domain.
    ///
    /// Read back with `CFPreferencesCopyValue` naming `productionName`
    /// explicitly, because that is the one API here that cannot be fooled by
    /// the redirect — `UserDefaults` would resolve whatever suite this process
    /// happens to be pointed at, which is exactly the thing under test.
    func testAWriteThroughTheSuiteNeverLandsInTheShippingDomain() {
        let key = "isolationProbe-\(UUID().uuidString)"
        PreferencesSuite.defaults.set("written by the test target", forKey: key)
        defer { PreferencesSuite.defaults.removeObject(forKey: key) }

        XCTAssertNotNil(PreferencesSuite.defaults.string(forKey: key),
                        "the write did not land anywhere at all, so this proves nothing")
        XCTAssertNil(
            CFPreferencesCopyValue(key as CFString, PreferencesSuite.productionName as CFString,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            "a test wrote into the shipping preference domain")
    }

    /// `removeAllValuesForTesting()` is the only thing in the target that
    /// deletes a whole domain, and the three `setUp`s call it unconditionally.
    /// It has to be the thing that refuses, not the caller.
    func testClearingRefusesToTouchTheShippingSuite() {
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "it must clear the redirected suite, or the tests do not isolate")
        // The refusal path is stated by construction: the guard compares
        // against `productionName`, and the assertion above proves `name` is
        // not it. A test that could exercise the refusal would have to point
        // the suite back at the shipping domain to do so, which is the one
        // thing this file exists to prevent.
        XCTAssertNotEqual(PreferencesSuite.name, PreferencesSuite.productionName)
    }
}
