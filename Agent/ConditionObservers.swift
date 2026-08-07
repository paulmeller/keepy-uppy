import Foundation
import AppKit
import CoreGraphics

// MARK: - Pure logic

/// Tracks whether CPU load has been below `threshold` continuously for at
/// least `sustainedFor` seconds. A single busy reading resets the clock —
/// this is what stops a momentary lull from ending a `whileCPUBusy`
/// session mid-job (spec §5).
struct CPUBusyWindow {
    let threshold: Double
    let sustainedFor: TimeInterval
    private var quietSince: Date?

    init(threshold: Double, sustainedFor: TimeInterval) {
        self.threshold = threshold
        self.sustainedFor = sustainedFor
    }

    mutating func record(busy: Double, at now: Date) {
        if busy < threshold {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
    }

    func isSustainedQuiet(at now: Date) -> Bool {
        guard let since = quietSince else { return false }
        return now.timeIntervalSince(since) >= sustainedFor
    }
}

// MARK: - Observing protocols (so the evidence loop in Task 4 never touches a framework)

protocol AppRunningObserving {
    func isRunning(bundleID: String) -> Bool
}

protocol DisplayObserving {
    func hasExternalDisplay() -> Bool
}

protocol CPUBusyObserving {
    /// Fraction 0...1, or nil if the sample could not be taken.
    func currentBusyFraction() -> Double?
}

// MARK: - Live implementations

struct SystemAppRunningObserver: AppRunningObserving {
    func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

struct SystemDisplayObserver: DisplayObserving {
    func hasExternalDisplay() -> Bool {
        // Built-in display, if present, is always id 0 on a MacBook; any
        // additional active display id means something external is
        // connected. The evidence loop already polls every 5s for the CPU
        // and app-running checks, so a plain count here on the same tick is
        // simpler than standing up a reconfiguration callback and gets the
        // same answer.
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return count > 1
    }
}

struct SystemCPUBusyObserver: CPUBusyObserving {
    func currentBusyFraction() -> Double? {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = cpuLoad.cpu_ticks
        let user = Double(ticks.0), system = Double(ticks.1), idle = Double(ticks.2), nice = Double(ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return 1.0 - (idle / total)
    }
}
