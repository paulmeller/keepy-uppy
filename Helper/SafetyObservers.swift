import Foundation
import IOKit

/// Everything the safety engine needs to see, behind a protocol so the
/// engine's tests never touch a framework.
protocol SafetyObserving {
    func thermalLevel() -> ThermalLevel
    func batteryState() -> BatteryState
    func isLidClosed() -> Bool
}

struct SystemSafetyObserver: SafetyObserving {
    func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    func batteryState() -> BatteryState { PowerControl.batteryState() }

    /// AppleClamshellState on IOPMrootDomain reports whether the lid is
    /// actually shut — the genuinely dangerous configuration, where the
    /// machine has no way to dump heat.
    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        else { return false }
        return property
    }
}
