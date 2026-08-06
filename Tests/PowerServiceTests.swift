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
