import XCTest
@testable import KeepyUppy

final class CPUBusyWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A momentary lull mid-job must not end the session — only a
    /// SUSTAINED drop below threshold for the full window should.
    func testBriefDipBelowThresholdDoesNotEndBusyWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.8, at: t0)
        window.record(busy: 0.3, at: t0.addingTimeInterval(10))
        window.record(busy: 0.8, at: t0.addingTimeInterval(20))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(20)))
    }

    func testSustainedQuietForTheFullWindowEndsIt() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.3, at: t0)
        window.record(busy: 0.2, at: t0.addingTimeInterval(60))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(60)), "not yet 120s")
        window.record(busy: 0.1, at: t0.addingTimeInterval(121))
        XCTAssertTrue(window.isSustainedQuiet(at: t0.addingTimeInterval(121)))
    }

    func testGoingBusyAgainResetsTheWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.2, at: t0)
        window.record(busy: 0.9, at: t0.addingTimeInterval(100))
        window.record(busy: 0.2, at: t0.addingTimeInterval(200))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(200)), "quiet period restarted at t=100")
    }
}
