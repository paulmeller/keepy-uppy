import XCTest
@testable import KeepyUppy

/// Security review batch B, Fix 5: an unenforced (DEBUG) daemon must never
/// silently accept XPC connections. `InsecureDebugGate` is the pure
/// predicate `HelperListenerDelegate` gates on, pulled out so the "must
/// never be on by accident" property is testable without standing up a real
/// XPC connection.
final class InsecureDebugGateTests: XCTestCase {
    func testRefusesWhenTheEnvironmentVariableIsAbsent() {
        XCTAssertFalse(InsecureDebugGate.isExplicitlyOptedIn(environment: [:]))
    }

    func testRefusesATruthyButWrongValue() {
        XCTAssertFalse(InsecureDebugGate.isExplicitlyOptedIn(environment: ["KEEPY_UPPY_INSECURE_XPC": "true"]))
        XCTAssertFalse(InsecureDebugGate.isExplicitlyOptedIn(environment: ["KEEPY_UPPY_INSECURE_XPC": "yes"]))
        XCTAssertFalse(InsecureDebugGate.isExplicitlyOptedIn(environment: ["KEEPY_UPPY_INSECURE_XPC": "0"]))
    }

    func testAcceptsOnlyTheExactExplicitOptIn() {
        XCTAssertTrue(InsecureDebugGate.isExplicitlyOptedIn(environment: ["KEEPY_UPPY_INSECURE_XPC": "1"]))
    }

    func testIsUnaffectedByUnrelatedEnvironmentVariables() {
        XCTAssertFalse(InsecureDebugGate.isExplicitlyOptedIn(environment: ["PATH": "/usr/bin"]))
    }
}
