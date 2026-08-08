import Foundation
import IOKit
import IOKit.ps

enum SleepState: Equatable {
    case disabled
    case enabled
    case unknown
}

enum PowerSource: Equatable {
    case battery
    case acPower
    case unknown
}

extension PowerSource {
    /// "Is AC power present?" as a tri-state, so that `.unknown` — IOKit
    /// declining to answer, which `PowerControl.batteryState()` returns
    /// whenever `IOPSCopyPowerSourcesInfo` or `IOPSCopyPowerSourcesList`
    /// fails — cannot collapse into "on battery."
    ///
    /// The agent already had this mapping written out inline for evaluating
    /// `.acPowerConnected` triggers. The daemon did not, and that was a real
    /// defect with real consequences: `DaemonRuntime.tickLocked` tested
    /// `battery.source != .acPower` and, on a match, applied
    /// `.acPowerDisconnected`, which **ends every `.whileOnACPower`
    /// session**. So a single failed power read ended sessions and let the
    /// Mac sleep, with the machine still plugged in — precisely the bug the
    /// tri-state observer contract exists to prevent, in the one component
    /// that had never been converted. Both now go through this one property,
    /// so they cannot drift apart again.
    ///
    /// See `ConditionReading` for the rule this feeds: only `.absent` may
    /// end a session, only `.present` may start one, `.undetermined` does
    /// neither.
    var acPowerReading: ConditionReading {
        switch self {
        case .acPower: return .present
        case .battery: return .absent
        case .unknown: return .undetermined
        }
    }
}

struct BatteryState: Equatable {
    let percentage: Int?
    let source: PowerSource
}

enum PowerControl {
    // MARK: - Sleep setting (privileged write, unprivileged read)

    private static let sleepDisabledKey = "SleepDisabled" as CFString

    static func sleepDisabled() -> Bool {
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (settings["SleepDisabled"] as? Bool) ?? false
    }

    /// Requires root. Returns true on success.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value = (disabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        return IOPMSetSystemPowerSetting(sleepDisabledKey, value) == kIOReturnSuccess
    }

    // MARK: - Battery (public API)

    static func batteryState() -> BatteryState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryState(percentage: nil, source: .unknown)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            return parseBattery(from: description)
        }
        // No battery (desktop Mac): report AC without a percentage.
        return BatteryState(percentage: nil, source: .acPower)
    }

    /// Pure half, split out so battery logic is testable without hardware.
    static func parseBattery(from description: [String: Any]) -> BatteryState {
        let source: PowerSource
        switch description[kIOPSPowerSourceStateKey as String] as? String {
        case kIOPSBatteryPowerValue: source = .battery
        case kIOPSACPowerValue: source = .acPower
        default: source = .unknown
        }

        var percentage: Int?
        if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
           let max = description[kIOPSMaxCapacityKey as String] as? Int,
           max > 0 {
            percentage = Int((Double(current) / Double(max) * 100).rounded())
        }

        return BatteryState(percentage: percentage, source: source)
    }
}
