import XCTest
@testable import KeepyUppy

final class PowerControlBatteryTests: XCTestCase {
    func testParsesDischargingBattery() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 87,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .battery)
        XCTAssertEqual(state.percentage, 87)
    }

    func testParsesACPower() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "AC Power",
            "Current Capacity": 100,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 100)
    }

    func testScalesWhenMaxCapacityIsNotOneHundred() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 25,
            "Max Capacity": 50,
        ])
        XCTAssertEqual(state.percentage, 50)
    }

    func testMissingKeysYieldUnknown() {
        let state = PowerControl.parseBattery(from: [:])
        XCTAssertEqual(state.source, .unknown)
        XCTAssertNil(state.percentage)
    }
}

/// The daemon's `.whileOnACPower` handling had the same
/// `.unknown`-collapses-into-false defect the tri-state observer contract
/// removed everywhere else: `DaemonRuntime.tickLocked` tested
/// `battery.source != .acPower` and, on a match, applied
/// `.acPowerDisconnected`, which ends every `.whileOnACPower` session. A
/// failed IOKit read therefore ended sessions and let the Mac sleep while it
/// was still plugged in.
///
/// `DaemonRuntime` lives in the Helper target and is not reachable from this
/// test host, so the decision itself moved to `PowerSource`, where it is both
/// testable and shared with the agent — which had the mapping right already,
/// written out inline, and no longer keeps its own copy to drift.
final class ACPowerReadingTests: XCTestCase {
    func testACPowerIsAConfidentPresent() {
        XCTAssertEqual(PowerSource.acPower.acPowerReading, .present)
        XCTAssertTrue(PowerSource.acPower.acPowerReading.isConfidentlyPresent)
    }

    func testBatteryIsAConfidentAbsent() {
        XCTAssertEqual(PowerSource.battery.acPowerReading, .absent)
        XCTAssertTrue(PowerSource.battery.acPowerReading.isConfidentlyAbsent)
    }

    /// The regression itself: a failed read must not be able to end a
    /// session. `.isConfidentlyAbsent` is the exact predicate the daemon's
    /// tick now gates `.acPowerDisconnected` on.
    func testUnknownIsUndeterminedAndCannotEndASession() {
        XCTAssertEqual(PowerSource.unknown.acPowerReading, .undetermined)
        XCTAssertFalse(PowerSource.unknown.acPowerReading.isConfidentlyAbsent)
    }

    /// A failed read must not *start* one either — it is not evidence in
    /// either direction, which is what makes `.undetermined` safe.
    func testUnknownAlsoCannotStartASession() {
        XCTAssertFalse(PowerSource.unknown.acPowerReading.isConfidentlyPresent)
    }

    /// A total IOKit failure — the path where the power-source description
    /// yields nothing usable — parses to `.unknown`, so it reaches the
    /// daemon's tick as `.undetermined` end to end, not as "unplugged".
    func testAFailedPowerReadReachesTheDaemonAsUndetermined() {
        let state = PowerControl.parseBattery(from: [:])
        XCTAssertEqual(state.source.acPowerReading, .undetermined)
    }

    /// The one true statement about ending `.whileOnACPower` sessions:
    /// exactly one of the three sources may do it.
    func testOnlyBatteryEndsACBoundSessions() {
        let enders = [PowerSource.acPower, .battery, .unknown]
            .filter { $0.acPowerReading.isConfidentlyAbsent }
        XCTAssertEqual(enders, [.battery])
    }
}
