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
        UserDefaults.standard.removePersistentDomain(forName: "au.com.workwireless.keepy-uppy")
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
}
