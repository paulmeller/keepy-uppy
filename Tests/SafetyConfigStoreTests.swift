import XCTest
@testable import KeepyUppy

final class SafetyConfigStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `UserDefaults(suiteName:)` returns nil when `suiteName` equals the
        // *calling process's own* bundle identifier — which is exactly the
        // case here, since this test host is the "Keepy Uppy" app itself
        // (PRODUCT_BUNDLE_IDENTIFIER `au.com.workwireless.keepy-uppy`,
        // identical to the suite name string). So `UserDefaults(suiteName:
        // "au.com.workwireless.keepy-uppy")?.removePersistentDomain(...)`
        // (the brief's original form of this line) would silently no-op in
        // this process — confirmed: running this test twice in a row with
        // that form failed the second time, because the first run's saved
        // config leaked through. `SafetyConfigStore` itself works around
        // the same case by falling back to `.standard`, which for this
        // exact degenerate case resolves to the identical underlying
        // preferences file — so clearing `.standard`'s domain here really
        // does reset it.
        UserDefaults.standard.removePersistentDomain(forName: PreferencesSuite.name)
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
