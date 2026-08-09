import Foundation

/// The pair that identifies a *kind* of USB device: its USB-IF vendor ID and
/// the vendor's product ID.
///
/// **Not the device's name**, and that is the whole point. Names are neither
/// unique nor stable — two identical dongles have the same name, a hub and the
/// thing behind it can share one, plenty of devices report none at all, and a
/// firmware update can change it. `idVendor`/`idProduct` are in the device
/// descriptor, are what IOKit matches drivers on, and are the same two numbers
/// `lsupb`-style tools print. A rule written against them keeps working.
///
/// Lives in `Shared/` rather than beside the observer because three targets
/// need it and only one of them can see `Agent/`: the CLI parses `--while-usb`,
/// `SessionKind`/`TriggerCondition` carry it, and the agent matches on it.
struct USBDeviceID: Equatable, Hashable, Codable {
    let vendorID: UInt16
    let productID: UInt16

    init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Parses `05ac:024f`, and the same thing written any of the ways someone
    /// actually writes it: `0x05ac:0x024F`, `5ac:24f`, mixed case.
    ///
    /// `nil` for anything that is not two hexadecimal halves inside `UInt16`.
    /// Deliberately strict about the *shape* — one colon, both halves present,
    /// at most four digits each — because a value that will not match is worth
    /// refusing at the keyboard, where it is one keystroke to fix, rather than
    /// letting it sit in the trigger list looking correct and never firing.
    /// Same call `parseSubnet` and `parseCPUBusyPercentage` make.
    ///
    /// **Hexadecimal, always, with no decimal fallback**, which is the one
    /// thing worth knowing before reading a value back: `1452:591` is a legal
    /// parse (`0x1452:0x0591`) and is *not* the decimal reading of Apple's
    /// `05ac:024f`. There is nothing in the string to tell the two apart, so
    /// there is nothing to be clever with — hex is what every tool prints, and
    /// the Add sheet fills the field in from a picker so the question rarely
    /// arises.
    init?(text: String) {
        let halves = text.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2,
              let vendor = Self.hexValue(halves[0]),
              let product = Self.hexValue(halves[1])
        else { return nil }
        self.init(vendorID: vendor, productID: product)
    }

    private static func hexValue(_ text: Substring) -> UInt16? {
        var digits = text
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        // Four digits is the width of the field in the USB device descriptor,
        // so a fifth is not a big number, it is a typo.
        guard (1...4).contains(digits.count) else { return nil }
        return UInt16(digits, radix: 16)
    }

    /// How the pair is written wherever a name is not available: `0x05ac:0x024f`.
    ///
    /// Zero-padded to four digits so two devices always line up, and lowercase
    /// because that is what USB tooling prints. `String(format:)` with `%04x`
    /// carries no locale, so this is safe to put on the wire.
    var text: String { String(format: "0x%04x:0x%04x", vendorID, productID) }
}
