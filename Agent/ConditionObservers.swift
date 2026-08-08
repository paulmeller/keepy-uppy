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
//
// AppRunningObserving and DisplayObserving live in Shared/ConditionObserving.swift,
// not here: Task 5's triggersToFire(...) needs them too, and Shared/ is compiled
// into every target, including the daemon and CLI, which must not gain this
// file's AppKit/CoreGraphics dependency. CPUBusyObserving stays here — nothing
// outside the agent evaluates CPU-busy conditions.

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

/// The first process-enumeration code in this repo — `SystemAppRunningObserver`
/// above only ever sees GUI apps registered with Launch Services, which the
/// CLI coding-assistant tools this exists for (`claude`, `codex`, `pi`, the
/// Cursor CLI's `agent`, Google Antigravity's `agy`) never are: no bundle ID,
/// no `NSRunningApplication` entry.
///
/// Matches `kinfo_proc.kp_proc.p_comm` — a fixed, `MAXCOMLEN`-length C array
/// holding the unqualified executable name, no path, no arguments — against
/// `processName` exactly. On a `sysctl` failure this returns `false` rather
/// than logging, matching `SystemDisplayObserver`/`SystemAppRunningObserver`
/// above: the evidence loop polls every 5s, and a transient failure here
/// should read as "not currently observed running," not spam the log.
struct SystemProcessRunningObserver: ProcessRunningObserving {
    func isRunning(processName: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return false }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = size
        guard sysctl(&mib, UInt32(mib.count), &procs, &actualSize, nil, 0) == 0 else { return false }

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride
        return procs[0..<actualCount].contains { proc in
            var comm = proc.kp_proc.p_comm
            let name = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
            return name == processName
        }
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
