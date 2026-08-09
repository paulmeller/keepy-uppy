import Foundation

/// A CIDR block, and whether an address is inside it. Pure integer arithmetic —
/// no interfaces, no sockets, no network — which is why it lives here and not
/// beside the `getifaddrs` reader in `Agent/`.
///
/// That split is what makes `.onSubnet` the one Plan 5 trigger whose matching
/// is pinnable exactly: `Tests/IPv4SubnetTests.swift` covers the parsing and
/// the containment on both edges of a block, on a machine with no network at
/// all, and `SystemNetworkAddressObserver` is left with one job — turn
/// `getifaddrs` into a set of addresses.
///
/// A bare address (`192.168.1.50`) is accepted and means `/32`, because that is
/// what someone typing one address means and refusing it would be pedantry.
///
/// IPv4 only. `AF_INET6` is not read and a v6 address is not accepted here —
/// `TriggerCondition.subnetProblem` says so in words, rather than letting the
/// UI take a v6 address and quietly never match it.
struct IPv4Subnet: Equatable {
    /// The block's base address in host byte order, with every host bit
    /// already cleared: `192.168.1.50/24` and `192.168.1.0/24` are the same
    /// value, because they describe the same block and a user will type the
    /// former.
    let network: UInt32
    /// 0...32.
    let prefixLength: UInt8

    init?(cidr: String) {
        // `omittingEmptySubsequences: false` on purpose: "192.168.1.1/" and
        // "/24" must be refused, and dropping the empty piece would turn the
        // first into a bare address and the second into a bare prefix.
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        let prefix: UInt32
        if parts.count == 2 {
            guard let value = Self.decimal(parts[1], maxDigits: 2), value <= 32 else { return nil }
            prefix = value
        } else {
            prefix = 32
        }

        guard let address = Self.address(parts[0]) else { return nil }
        prefixLength = UInt8(prefix)
        network = address & Self.mask(prefix)
    }

    func contains(_ address: UInt32) -> Bool {
        address & Self.mask(UInt32(prefixLength)) == network
    }

    /// `/0` is special-cased rather than left to the shift: `~0 << 32` is a
    /// shift by the full width of the type, which is not the zero mask anyone
    /// expects it to be.
    private static func mask(_ prefixLength: UInt32) -> UInt32 {
        prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
    }

    private static func address(_ text: Substring) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let number = decimal(octet, maxDigits: 3), number <= 255 else { return nil }
            value = value << 8 | number
        }
        return value
    }

    /// Deliberately stricter than `UInt32(String)`, which accepts a leading
    /// `+` and (with a locale-independent but still surprising reach) other
    /// forms nobody types into a network field. Digits only, so
    /// `192.168.1.+1` and `192.168.1.1 ` are refused rather than silently
    /// meaning something. `maxDigits` also keeps the accumulation below
    /// overflow without a wider type.
    private static func decimal(_ text: Substring, maxDigits: Int) -> UInt32? {
        guard !text.isEmpty, text.count <= maxDigits,
              text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(text)
    }
}
