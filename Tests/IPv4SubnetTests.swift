import XCTest
@testable import KeepyUppy

/// The one trigger in Plan 5 whose logic is fully pinnable without a machine
/// to observe: no interfaces, no sockets, no network, just arithmetic. So it
/// carries the weight for `.onSubnet` — the live reader below it has one job
/// (turn `getifaddrs` into a set of addresses) and everything that decides
/// whether a rule matches is here.
final class IPv4SubnetTests: XCTestCase {
    /// An address as the reader hands it over: host byte order, so
    /// `192.168.1.50` is `0xC0A80132`.
    private func address(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        a << 24 | b << 16 | c << 8 | d
    }

    // MARK: - Parsing

    func testParsesAPlainCIDR() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.0/24") else { return XCTFail("did not parse") }
        XCTAssertEqual(subnet.network, address(192, 168, 1, 0))
        XCTAssertEqual(subnet.prefixLength, 24)
    }

    /// Typing one address is a complete thought — "when I am at this exact
    /// address" — so it is accepted, and it means the block containing only
    /// itself.
    func testABareAddressMeansSlash32() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.50") else { return XCTFail("did not parse") }
        XCTAssertEqual(subnet.network, address(192, 168, 1, 50))
        XCTAssertEqual(subnet.prefixLength, 32)
        XCTAssertEqual(subnet, IPv4Subnet(cidr: "192.168.1.50/32"))
    }

    func testRejectsAPrefixOver32() {
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/33"))
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/64"))
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/999"))
    }

    func testRejectsAnOctetOver255() {
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.256"))
        XCTAssertNil(IPv4Subnet(cidr: "256.0.0.0/8"))
        XCTAssertNil(IPv4Subnet(cidr: "192.999.1.1"))
    }

    func testRejectsGarbage() {
        for bad in ["", "  ", "hello", "192.168.1", "192.168.1.1.1", "192.168.1.1/",
                    "/24", "192.168.1.1//24", "192.168.1.1/24/8", "192.168.1.-1",
                    "192.168.1.+1", " 192.168.1.1", "192.168.1.1 ", "192.168.1.a",
                    "192.168..1", "::1", "fe80::1/64", "192.168.1.1/2a"] {
            XCTAssertNil(IPv4Subnet(cidr: bad), "\"\(bad)\" is not an IPv4 block")
        }
    }

    // MARK: - Containment

    func testAnAddressInsideItsOwnSlash24() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.0/24") else { return XCTFail("did not parse") }
        XCTAssertTrue(subnet.contains(address(192, 168, 1, 50)))
        XCTAssertTrue(subnet.contains(address(192, 168, 1, 1)))
    }

    /// Both ends count. A /24's `.0` and `.255` are ordinary addresses as far
    /// as this question goes — an interface really can hold either — and an
    /// off-by-one at the edge would make a rule stop matching for one machine
    /// on the network and nobody would ever work out why.
    func testTheNetworkAndBroadcastAddressesAreBothInside() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.0/24") else { return XCTFail("did not parse") }
        XCTAssertTrue(subnet.contains(address(192, 168, 1, 0)))
        XCTAssertTrue(subnet.contains(address(192, 168, 1, 255)))
    }

    func testAnAddressOneOutsideTheBlockIsOutside() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.0/24") else { return XCTFail("did not parse") }
        XCTAssertFalse(subnet.contains(address(192, 168, 0, 255)), "one below the block")
        XCTAssertFalse(subnet.contains(address(192, 168, 2, 0)), "one above it")
    }

    /// `/0` masks nothing, and the shift that computes its mask is the one
    /// that would trap: `~0 << 32` is undefined-shift territory, so the
    /// implementation has to special-case it rather than discover it in
    /// production.
    func testSlashZeroContainsEverything() {
        guard let subnet = IPv4Subnet(cidr: "0.0.0.0/0") else { return XCTFail("did not parse") }
        for candidate: UInt32 in [0, 1, address(10, 0, 0, 1), address(192, 168, 1, 1), .max] {
            XCTAssertTrue(subnet.contains(candidate), "\(candidate)")
        }
    }

    func testSlash32ContainsOnlyItself() {
        guard let subnet = IPv4Subnet(cidr: "192.168.1.50/32") else { return XCTFail("did not parse") }
        XCTAssertTrue(subnet.contains(address(192, 168, 1, 50)))
        XCTAssertFalse(subnet.contains(address(192, 168, 1, 49)))
        XCTAssertFalse(subnet.contains(address(192, 168, 1, 51)))
    }

    /// The form a user actually types. Somebody reading their own network
    /// settings sees `192.168.1.50` and a `/24`, and writes the two together;
    /// that has to mean the same block as `192.168.1.0/24` rather than a rule
    /// matching one machine, or silently nothing.
    func testHostBitsSetInTheRuleAreMasked() {
        guard let typed = IPv4Subnet(cidr: "192.168.1.50/24"),
              let canonical = IPv4Subnet(cidr: "192.168.1.0/24") else { return XCTFail("did not parse") }
        XCTAssertEqual(typed, canonical)
        XCTAssertEqual(typed.network, address(192, 168, 1, 0))
        XCTAssertTrue(typed.contains(address(192, 168, 1, 99)))
    }

    /// Prefixes that are not multiples of eight are where a hand-rolled mask
    /// goes wrong, and they are ordinary in a real network.
    func testAPrefixThatDoesNotFallOnAnOctetBoundary() {
        guard let subnet = IPv4Subnet(cidr: "10.1.2.0/23") else { return XCTFail("did not parse") }
        XCTAssertEqual(subnet.network, address(10, 1, 2, 0))
        XCTAssertTrue(subnet.contains(address(10, 1, 2, 0)))
        XCTAssertTrue(subnet.contains(address(10, 1, 3, 255)), "a /23 spans two /24s")
        XCTAssertFalse(subnet.contains(address(10, 1, 4, 0)))
        XCTAssertFalse(subnet.contains(address(10, 1, 1, 255)))
    }
}
