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

/// Final whole-branch review, Item 1: the app and CLI both pinned an
/// *inbound* requirement on their outbound connection to the daemon.
/// `setCodeSigningRequirement` validates the **peer**, and the inbound
/// requirements deliberately omit the daemon's own identifier, so pinning one
/// client-side rejects the daemon on the first real message: the app shows
/// "Not connected" forever and the CLI only ever errors, in any signed build.
/// Verified independently with `codesign -R` against a real
/// `KeepyUppyHelper` binary: the inbound requirement fails (exit 3),
/// `helperRequirement` succeeds (exit 0).
///
/// These are pure string assertions on the constants themselves — no XPC
/// connection required, exactly like `InsecureDebugGateTests` above — so the
/// structural property survives even though the requirement can't be
/// enforced in a DEBUG/ad-hoc build.
final class SigningRequirementIdentifierTests: XCTestCase {
    /// Every requirement a listener pins on the peers it accepts.
    private let inboundRequirements = ClientRole.allCases.map(\.inboundSigningRequirement)

    func testHelperRequirementPinsTheDaemonsOwnIdentifier() {
        XCTAssertTrue(
            SigningRequirement.helperRequirement.contains(SigningRequirement.helperIdentifier),
            "helperRequirement must pin the daemon's own identifier — it is what clients pin the daemon peer with")
    }

    func testNoInboundRequirementAdmitsTheDaemonsOwnIdentifier() {
        for requirement in inboundRequirements {
            XCTAssertFalse(
                requirement.contains(SigningRequirement.helperIdentifier),
                "the daemon's own identifier must stay out of every inbound requirement: \(requirement)")
        }
    }

    /// Inbound and outbound are not interchangeable — the whole point of the
    /// bug. If any of these ever match, one has drifted into the other.
    func testNoInboundRequirementEqualsTheOutboundOne() {
        for requirement in inboundRequirements {
            XCTAssertNotEqual(requirement, SigningRequirement.helperRequirement)
        }
    }

    // MARK: - One service, one identifier

    /// The core tightening behind stable identity: a role's service admits
    /// its own binary and nothing else. The old single general service
    /// admitted any of the three client identifiers, which is exactly why
    /// arriving on it could not say *which* client had arrived.
    func testEachRoleAdmitsItsOwnIdentifierAndNoOtherClients() {
        let identifiersByRole: [ClientRole: String] = [
            .app: SigningRequirement.appIdentifier,
            .agent: SigningRequirement.agentIdentifier,
            .cli: SigningRequirement.cliIdentifier,
        ]
        for role in ClientRole.allCases {
            guard let own = identifiersByRole[role] else {
                return XCTFail("no identifier mapped for role \(role.rawValue)")
            }
            let requirement = role.inboundSigningRequirement
            XCTAssertTrue(requirement.contains("identifier = \"\(own)\""),
                          "\(role.rawValue) must admit its own identifier")
            for (otherRole, other) in identifiersByRole where otherRole != role {
                XCTAssertFalse(requirement.contains("identifier = \"\(other)\""),
                               "\(role.rawValue)'s service must not admit \(otherRole.rawValue)'s identifier")
            }
        }
    }

    /// No live requirement string contains an `or` any more, so the
    /// documented `and`-binds-tighter-than-`or` parenthesisation hazard
    /// cannot currently be tripped. If someone widens one of these to admit
    /// a second identifier, this fails and sends them to the note in
    /// `SigningRequirement` explaining why the group must be parenthesised.
    func testNoRequirementUsesAnUnparenthesisedOrGroup() {
        for requirement in inboundRequirements + [SigningRequirement.helperRequirement] {
            guard requirement.contains(" or ") else { continue }
            XCTAssertTrue(
                requirement.contains("("),
                "an OR-group MUST be parenthesised — `and` binds tighter than `or`, so `... and A or B` admits B with no Team ID check at all: \(requirement)")
        }
    }

    func testEveryRequirementCarriesTheAnchorAndTeamIDClauses() {
        for requirement in inboundRequirements + [SigningRequirement.helperRequirement] {
            XCTAssertTrue(requirement.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = "),
                          "every requirement must be built from the shared anchor+team clause: \(requirement)")
            XCTAssertTrue(requirement.contains(SigningRequirement.teamID),
                          "every requirement must carry the Team ID: \(requirement)")
        }
    }

    func testEachServiceIsDistinct() {
        let services = ClientRole.allCases.map(\.machServiceName)
        XCTAssertEqual(Set(services).count, ClientRole.allCases.count,
                       "each role needs its own Mach service, or role stops being structural: \(services)")
    }

    /// The daemon's launchd job must actually vend every service a listener
    /// is stood up on; a listener whose service is undeclared never receives
    /// anything, which is a silent "nothing happens" failure rather than an
    /// error.
    func testEveryRoleServiceIsDeclaredInTheDaemonLaunchdPlist() throws {
        // Tests/ sits alongside Launchd/ in the repo, and the test bundle
        // knows its own source file path at compile time.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("Launchd")
            .appendingPathComponent("au.com.workwireless.keepy-uppy.helper.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        for role in ClientRole.allCases {
            XCTAssertNotNil(machServices[role.machServiceName],
                            "MachServices must declare \(role.machServiceName) for role \(role.rawValue)")
        }
    }
}
