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

/// Final whole-branch review, Item 1: the app and CLI both pinned
/// `SigningRequirement.requirement` on their outbound connection to the
/// daemon. `setCodeSigningRequirement` validates the **peer**, and
/// `requirement` is the *inbound* requirement the daemon applies to its
/// clients — it deliberately omits the daemon's own identifier (see
/// `identifiers`' comment), so pinning it client-side rejects the daemon on
/// the first real message: the app shows "Not connected" forever and the CLI
/// only ever errors, in any signed build. Verified independently with
/// `codesign -R` against a real `KeepyUppyHelper` binary: `requirement`
/// fails (exit 3), `helperRequirement` succeeds (exit 0).
///
/// These are pure string assertions on the constants themselves — no XPC
/// connection required, exactly like `InsecureDebugGateTests` above — so the
/// structural property survives even though the requirement can't be
/// enforced in a DEBUG/ad-hoc build.
final class SigningRequirementIdentifierTests: XCTestCase {
    func testHelperRequirementPinsTheDaemonsOwnIdentifier() {
        XCTAssertTrue(
            SigningRequirement.helperRequirement.contains(SigningRequirement.helperIdentifier),
            "helperRequirement must pin the daemon's own identifier — it is what clients pin the daemon peer with")
    }

    func testGeneralRequirementDoesNotAdmitTheDaemonsOwnIdentifier() {
        XCTAssertFalse(
            SigningRequirement.identifiers.contains(SigningRequirement.helperIdentifier),
            "the daemon's own identifier must stay out of the inbound client allow-list")
        XCTAssertFalse(
            SigningRequirement.requirement.contains(SigningRequirement.helperIdentifier),
            "requirement is built from `identifiers`; the daemon's identifier must not appear in it")
    }

    /// The two constants are not interchangeable — the whole point of the
    /// bug. If this ever passes, one of them has drifted into the other.
    func testTheTwoRequirementsAreNotTheSameString() {
        XCTAssertNotEqual(SigningRequirement.requirement, SigningRequirement.helperRequirement)
    }
}
