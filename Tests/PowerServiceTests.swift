import XCTest
@testable import KeepyUppy

final class PowerServiceSleepStateTests: XCTestCase {
    func testParsesDisabledState() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.disabledOutput), .disabled)
    }

    func testDefaultsToEnabledWhenLineAbsent() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.defaultOutput), .enabled)
    }

    func testUnknownStateOnUnexpectedValue() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.malformedOutput), .unknown)
    }

    // pmset's column padding is spaces today, but the battery output already
    // mixes tabs, so the parser must not silently misread a tab-padded
    // SleepDisabled line as "line absent" (which would report Normal Sleep
    // while sleep is actually disabled — the dangerous direction).
    func testParsesTabSeparatedDisabledLine() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.tabSeparatedOutput), .disabled)
    }

    static let disabledOutput = """
    System-wide power settings:
     SleepDisabled      1
    Currently in use:
     standbydelaylow      10
     sleep                 1
     hibernatemode         3
     lidwake               1
    """

    static let defaultOutput = """
    Currently in use:
     standbydelaylow      10
     sleep                 10
     hibernatemode         3
     lidwake               1
    """

    static let malformedOutput = """
    System-wide power settings:
     SleepDisabled      maybe
    Currently in use:
     sleep                 10
    """

    static let tabSeparatedOutput = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep\t1\n"
}

final class PowerServiceBatteryTests: XCTestCase {
    func testParsesDischargingBattery() {
        let state = PowerService.parseBattery(Self.batteryDischarging)
        XCTAssertEqual(state.source, .battery)
        XCTAssertEqual(state.percentage, 87)
    }

    func testParsesChargedOnAC() {
        let state = PowerService.parseBattery(Self.acCharged)
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 100)
    }

    func testDesktopMacHasNoPercentage() {
        let state = PowerService.parseBattery(Self.acNoBattery)
        XCTAssertEqual(state.source, .acPower)
        XCTAssertNil(state.percentage)
    }

    // Real-world variant: while charging, pmset emits "(no estimate)"
    // instead of an "H:MM remaining" figure.
    func testParsesChargingWithNoEstimate() {
        let state = PowerService.parseBattery(Self.acChargingNoEstimate)
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 68)
    }

    static let batteryDischarging = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4325027)\t87%; discharging; 3:48 remaining present: true\n"
    static let acCharged = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4325027)\t100%; charged; 0:00 remaining present: true\n"
    static let acNoBattery = "Now drawing from 'AC Power'\n"
    static let acChargingNoEstimate = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4325027)\t68%; charging; (no estimate) present: true\n"
}
