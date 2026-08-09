import Foundation
import AppKit
import CoreGraphics
import SystemConfiguration

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

// MARK: - Live implementations
//
// The observer protocols these conform to, and the `ConditionReading` /
// `CPUBusyReading` types they answer with, are declared together in
// Shared/ConditionObserving.swift — Shared/ is compiled into every target,
// including the daemon and CLI, which must not gain this file's
// AppKit/CoreGraphics dependency.

struct SystemAppRunningObserver: AppRunningObserving {
    func isRunning(bundleID: String) -> ConditionReading {
        let running = NSWorkspace.shared.runningApplications
        // `runningApplications` always contains at least this process, so an
        // empty list is not "nothing is running" — it is Launch Services
        // failing to answer. Reporting that as `.absent` would end every live
        // `.whileAppRunning` session at once.
        guard !running.isEmpty else { return .undetermined }
        return ConditionReading(running.contains { $0.bundleIdentifier == bundleID })
    }
}

/// The app the user is actually looking at.
///
/// Two separate reads can fail here, and both of them mean "I could not
/// tell" rather than "you switched away":
///
/// * **`frontmostApplication` is `nil`.** This is the one that matters, and
///   it is not a theoretical failure mode: the screen being locked, the
///   login window being up, or another user being switched in all produce
///   `nil` while the app in question is still exactly where it was. Reading
///   that as `.absent` would let a locked screen answer a question about
///   window order.
/// * **`runningApplications` is empty.** The same guard, and the same
///   argument, as `SystemAppRunningObserver` above: that list always
///   contains at least this process, so empty is Launch Services failing to
///   answer rather than a Mac with nothing running.
///
/// A frontmost app that exists and is a *different* one is `.absent`,
/// including one with no bundle identifier at all — an app that has no
/// identifier is definitely not the identifier the rule named.
struct SystemFrontmostAppObserver: FrontmostAppObserving {
    func isFrontmost(bundleID: String) -> ConditionReading {
        let workspace = NSWorkspace.shared
        guard !workspace.runningApplications.isEmpty else { return .undetermined }
        guard let frontmost = workspace.frontmostApplication else { return .undetermined }
        return ConditionReading(frontmost.bundleIdentifier == bundleID)
    }
}

struct SystemDisplayObserver: DisplayObserving {
    func hasExternalDisplay() -> ConditionReading {
        // Built-in display, if present, is always id 0 on a MacBook; any
        // additional active display id means something external is
        // connected. The evidence loop already polls every 5s for the CPU
        // and app-running checks, so a plain count here on the same tick is
        // simpler than standing up a reconfiguration callback and gets the
        // same answer.
        //
        // The `CGError` was previously discarded, which turned a failed
        // enumeration into a count of 0 and therefore into "the external
        // display was unplugged" — the same collapse of "don't know" into
        // "no" that `ConditionReading` exists to prevent.
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return .undetermined }
        return ConditionReading(count > 1)
    }
}

/// One reading of the kernel's CPU tick counters, which are cumulative since
/// boot and therefore say nothing on their own — only the difference between
/// two of them describes what the CPU is doing now. See
/// `SystemCPUBusyObserver`.
struct CPUTickSample: Equatable {
    /// Ticks spent idle since boot.
    let idle: Double
    /// Ticks spent in any state since boot: user + system + idle + nice.
    let total: Double
}

/// Taking a sample, split out from differencing two of them, for the same
/// reason `ProcessTableReading` is split from the matching built on it: the
/// arithmetic — including the three cases that must come back
/// `.undetermined` rather than "idle" — is then testable without a live
/// kernel, and exactly.
protocol CPUTickSampling {
    /// `nil` when the sample could not be taken at all.
    func sample() -> CPUTickSample?
}

struct HostStatisticsCPUTickSampler: CPUTickSampling {
    func sample() -> CPUTickSample? {
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
        return CPUTickSample(idle: idle, total: user + system + idle + nice)
    }
}

/// The fraction of CPU time spent non-idle **since the previous sample**.
///
/// ## The bug this replaces
///
/// `host_statistics64(HOST_CPU_LOAD_INFO)` returns tick counters that are
/// cumulative since boot, so the obvious `1.0 - idle / total` is the
/// machine's *lifetime average*, not its current load. That is what shipped,
/// and it does not move: measured on this 16-core Mac, `0.1660` with the
/// machine idle and `0.1662` immediately after pinning every core for two
/// seconds — a swing of 0.0002 across the whole width of the range the number
/// is supposed to describe. Differencing two samples over the same two seconds
/// gives `0.0506` quiet and `0.9969` busy.
///
/// So `.whileCPUBusy` was decided by the machine's uptime rather than by its
/// CPU: against a threshold above the lifetime average, every such session
/// ends 120s in no matter how hard the machine is working; against one below
/// it, no such session ever ends at all.
///
/// ## Why this is a class, and why there is exactly one of it
///
/// A delta needs a predecessor, so this carries state between calls — which
/// makes its lifetime part of its contract, in the *opposite* direction from
/// `SystemProcessRunningObserver` above:
///
/// * `SystemProcessRunningObserver` is rebuilt **every tick**, *because* its
///   memoized process-table read must not outlive the tick that took it.
///   `EvidenceLoopRunner` therefore holds a `() -> ProcessRunningObserving`
///   factory for it.
/// * This one is built **once**, for the agent's whole life, *because* its
///   previous sample must outlive the tick that took it. `EvidenceLoopRunner`
///   holds it in a plain `let` and calls it exactly once per tick, into
///   `ObserverSet.cpuBusy` — a pre-taken reading rather than an observer,
///   precisely so that no per-session question can take a second sample and
///   collapse every other session's measurement interval to nothing.
///
/// `final class` is load-bearing rather than stylistic: `CPUBusyObserving`
/// declares `currentBusy()` non-mutating, so a `struct` could not update
/// `previous` at all, and a `mutating` variant would have its update thrown
/// away on every copy — including the copy made when `EvidenceLoopRunner`
/// stores it as a `CPUBusyObserving` existential.
///
/// ## What "I could not measure" means here
///
/// Three paths return `.undetermined`, and by the rule documented on
/// `ConditionReading` each therefore does nothing at all — it cannot end a
/// session and cannot start one, and `SessionEvidence.recordAndCheckCPUEnd`
/// leaves the 120s sustained-quiet window untouched:
///
/// 1. **The very first reading after launch**, which has no predecessor. This
///    is the one that matters most: `0` here would be indistinguishable from
///    a genuinely idle CPU and would start the quiet clock of every live
///    `.whileCPUBusy` session the instant the agent restarted. The loop gets
///    a real number five seconds later.
/// 2. **No elapsed ticks** (`Δtotal <= 0`). Two samples inside one kernel tick
///    period legitimately measure nothing, and `0 / 0` is not "idle".
/// 3. **A failed sample.** Here the previous sample is deliberately *kept*
///    rather than dropped, so the next successful sample measures the whole
///    span across the gap instead of spending a second tick with no
///    predecessor.
///
/// Case 2 also absorbs counter wraparound, which is not hypothetical: the
/// fields are `natural_t` (`UInt32`) and, measured here, advance at 1599
/// ticks/second in aggregate across 16 cores — about 31 days of uptime to
/// wrap. A wrap drives both deltas negative, so it costs exactly one tick.
/// The clamp then keeps anything else the kernel might hand back inside
/// 0...1, so `CPUBusyWindow` never compares a threshold against a number that
/// is not a fraction.
final class SystemCPUBusyObserver: CPUBusyObserving {
    private let sampler: CPUTickSampling
    private var previous: CPUTickSample?

    init(sampler: CPUTickSampling = HostStatisticsCPUTickSampler()) {
        self.sampler = sampler
    }

    func currentBusy() -> CPUBusyReading {
        guard let sample = sampler.sample() else { return .undetermined }
        let last = previous
        // Updated even when the delta below is unusable, so that a wrapped or
        // same-tick pair costs one reading rather than every reading after it.
        previous = sample
        guard let last else { return .undetermined }
        let idleDelta = sample.idle - last.idle
        let totalDelta = sample.total - last.total
        guard totalDelta > 0 else { return .undetermined }
        return .busy(fraction: min(1, max(0, 1.0 - idleDelta / totalDelta)))
    }
}

// MARK: - Process table

/// The result of one pass over the process table: every name a
/// `.processRunning` rule could match, or an explicit admission that the
/// table could not be read. `.unavailable` is what becomes
/// `ConditionReading.undetermined`, and is the reason this is an enum rather
/// than an optional set nobody would remember to check.
enum ProcessTableReadResult: Equatable {
    case names(Set<String>)
    case unavailable
}

/// Reading the process table, split out from matching against it so that the
/// matching (and its memoization) is testable without a live kernel, and so
/// one read serves every rule and every session on a tick.
protocol ProcessTableReading {
    func read() -> ProcessTableReadResult
}

/// The first process-enumeration code in this repo — `SystemAppRunningObserver`
/// above only ever sees GUI apps registered with Launch Services, which the
/// CLI coding-assistant tools this exists for (`claude`, `codex`, `pi`, the
/// Cursor CLI's `agent`, Google Antigravity's `agy`) never are: no bundle ID,
/// no `NSRunningApplication` entry.
///
/// ## What counts as a process's "name"
///
/// The union of three strings per process:
///
/// 1. `kinfo_proc.kp_proc.p_comm` — what this originally matched, and alone.
/// 2. the last path component of the executable path, and
/// 3. the last path component of `argv[0]`,
///
/// both from `KERN_PROCARGS2`. Matching `p_comm` alone is why the flagship
/// `claude` preset never fired: npm installs Claude Code as a `claude`
/// symlink to `claude.exe`, the kernel takes `p_comm` from the resolved
/// binary, and so `p_comm` is `claude.exe` while `claude` is only ever
/// `argv[0]`. Measured against 16 live Claude Code sessions on the author's
/// Mac: `claude -> false`, `claude.exe -> true`. Every `node`/`bun`-wrapped
/// CLI has the same shape — `pi` ships as a `#!/usr/bin/env node` script, so
/// its `p_comm` is `node` and only `argv[0]` ever says `pi`.
///
/// The union, rather than `argv[0]` alone, because the two fail in different
/// places and cover for each other: `KERN_PROCARGS2` can be refused for an
/// individual process (in which case that process still contributes its
/// `p_comm`), and a process that rewrites its own `argv` — which is exactly
/// how `pi` comes to say `pi` — can lose the name it was launched under. The
/// union is also a strict superset of the old behaviour, so no rule that
/// used to match stops matching.
///
/// A pleasant side effect: `p_comm` is a `MAXCOMLEN`-length array, so it
/// truncates any name over 16 characters and a longer name could never match.
/// The executable path and `argv[0]` are not truncated, so that limit is gone
/// — verified against a 31-character binary name, which matches in full.
///
/// ## Scope and failure
///
/// Scoped to the current effective uid (`KERN_PROC_UID`), matching how the
/// rest of the codebase reasons about ownership (`Session.ownerUID`): with
/// `KERN_PROC_ALL` another user's `claude` held *your* session awake.
///
/// A failure to enumerate is reported as `.unavailable`, never as "nothing is
/// running" — see `ConditionReading` for the whole argument.
struct SysctlProcessTableReader: ProcessTableReading {
    /// The kernel sizes a `KERN_PROC` fetch from the process count it sees at
    /// sizing time and hands back barely any headroom — measured on this Mac,
    /// repeatedly: `sized 731 slots, actual 726 slots — headroom 5 slots`.
    /// If more than that many processes appear between the sizing call and
    /// the fetching call, the fetch returns `ENOMEM`. Process churn is
    /// exactly what a coding CLI produces, so this is not a rare race: during
    /// a real `xcodebuild`, the old exact-sized single-shot fetch failed on
    /// **21 of 4,000 polls (0.53%)** and the observed headroom fell as low as
    /// 4 slots, against **0 failures in 20,000 idle polls**.
    ///
    /// Two independent defences, because a failure here used to end a live
    /// session and now merely degrades it to `.undetermined`:
    ///
    /// * **Over-allocate.** Ask for the sized count plus generous slack, so
    ///   the race needs hundreds of new processes rather than six. The slack
    ///   doubles on each retry.
    /// * **Retry.** Re-size and re-fetch, because the race is transient by
    ///   construction.
    ///
    /// Measured with both, under the same real `xcodebuild` churn: 0 failures
    /// in 4,000 polls, and no poll ever needed its second attempt.
    static let attempts = 3
    /// Floor for the over-allocation, for the degenerate case of a tiny
    /// process table where `sized / 2` would be a handful of slots.
    static let minimumSlack = 128

    private static let procStride = MemoryLayout<kinfo_proc>.stride

    func read() -> ProcessTableReadResult {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        for attempt in 1...Self.attempts {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { continue }

            let sized = size / Self.procStride
            let slack = max(Self.minimumSlack, sized / 2) << (attempt - 1)
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: sized + slack)
            var actualSize = procs.count * Self.procStride
            guard sysctl(&mib, UInt32(mib.count), &procs, &actualSize, nil, 0) == 0 else { continue }

            return .names(Self.names(in: procs, count: actualSize / Self.procStride))
        }
        return .unavailable
    }

    private static func names(in procs: [kinfo_proc], count: Int) -> Set<String> {
        var names = Set<String>()
        names.reserveCapacity(count * 2)
        // One buffer, reused for every process: `KERN_ARGMAX` is a megabyte,
        // and allocating that per process would dominate the whole read.
        var buffer = [CChar](repeating: 0, count: argMax)
        for index in 0..<count {
            let proc = procs[index]
            names.insert(commName(of: proc))
            // A process that exits between the enumeration and this read just
            // contributes its `p_comm`; that is a per-process shortfall, not a
            // failure to read the table, so it must not become `.unavailable`.
            if let (executablePath, argv0) = argNames(pid: proc.kp_proc.p_pid, buffer: &buffer) {
                names.insert(lastPathComponent(executablePath))
                names.insert(lastPathComponent(argv0))
            }
        }
        return names
    }

    private static func commName(of proc: kinfo_proc) -> String {
        var comm = proc.kp_proc.p_comm
        return withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// `KERN_PROCARGS2`'s layout is `argc`, then the NUL-terminated
    /// executable path, then alignment NULs, then `argv[0]`. Both strings
    /// before `argv[1]` are what this needs, and both come out of the one
    /// call.
    private static func argNames(pid: Int32, buffer: inout [CChar]) -> (String, String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The buffer is reused across processes, so everything past `size` is
        // the *previous* process's arguments. Plant a terminator so a string
        // that runs to the very end of this process's region stops there
        // rather than reading on into them — or past the allocation.
        buffer[min(size, buffer.count - 1)] = 0
        return buffer.withUnsafeBufferPointer { buf -> (String, String)? in
            guard let base = buf.baseAddress.map(UnsafeRawPointer.init) else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let pathStart = MemoryLayout<Int32>.size          // skip argc
            var offset = pathStart
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size, offset > pathStart else { return nil }
            let executablePath = String(cString: base.advanced(by: pathStart).assumingMemoryBound(to: CChar.self))
            while offset < size && bytes[offset] == 0 { offset += 1 }  // alignment NULs
            guard offset < size else { return nil }
            let argv0 = String(cString: base.advanced(by: offset).assumingMemoryBound(to: CChar.self))
            return (executablePath, argv0)
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()
}

// MARK: - Mounted volumes

/// The result of one enumeration of the mounted volumes: every name a
/// `.volumeMounted` rule could match, or an explicit admission that the list
/// could not be read. The same shape, and the same reason, as
/// `ProcessTableReadResult`.
enum MountedVolumeReading: Equatable {
    case names(Set<String>)
    case unavailable
}

/// Reading the volume list, split out from matching against it so the
/// matching (and its memoization) is testable with no real disk, and so one
/// enumeration serves every rule and every session on a tick.
protocol MountedVolumeReader {
    func read() -> MountedVolumeReading
}

/// `FileManager.mountedVolumeURLs` plus one `volumeName` lookup per volume.
///
/// **`.skipHiddenVolumes` is load-bearing, not tidiness.** Without it this
/// machine reports twelve volumes — `VM`, `Preboot`, `Update`, `xART`,
/// `iSCPreboot`, `Hardware`, two simulator runtimes, a cryptex — none of
/// which a user has ever seen in Finder, and any of which a rule could then
/// name. With it, the same read reports two: `Macintosh HD` and whatever is
/// actually plugged in. Measured, both ways, with a test image mounted. It
/// also keeps the Add sheet's picker and this observer looking at one list,
/// so the sheet cannot offer a volume the observer will never match.
///
/// **An empty array is `.unavailable`, and that is deliberate.** `/` is
/// always mounted and is never hidden, so "no volumes at all" is not a Mac
/// with nothing plugged in — it is an enumeration that failed. Reporting it
/// as `.names([])` would read as a confident "your backup drive is gone" and
/// would end every live `.whileVolumeMounted` session at once. This is the
/// line a later reader will want to "simplify"; it is the same argument as
/// `SystemAppRunningObserver`'s empty-list guard.
struct MountedVolumeURLsReader: MountedVolumeReader {
    func read() -> MountedVolumeReading {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes])
        else { return .unavailable }
        guard !urls.isEmpty else { return .unavailable }
        // A single volume that will not answer for its own name is a
        // per-volume shortfall, not a failure to read the list — exactly as a
        // process that exits mid-enumeration still contributes its `p_comm`.
        return .names(Set(urls.compactMap {
            (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        }))
    }
}

/// Answers `.volumeMounted` questions from a single volume enumeration.
///
/// Memoized for the same reason, and with the same safety-by-construction, as
/// `SystemProcessRunningObserver`: there is no way to clear the cache because
/// `EvidenceLoopRunner` builds a new observer every tick, so the cache's
/// lifetime *is* the tick.
final class SystemMountedVolumeObserver: MountedVolumeObserving {
    private let reader: MountedVolumeReader
    private var thisTick: MountedVolumeReading?

    init(reader: MountedVolumeReader = MountedVolumeURLsReader()) {
        self.reader = reader
    }

    func isMounted(volumeName: String) -> ConditionReading {
        let result = thisTick ?? reader.read()
        thisTick = result
        switch result {
        case .names(let names): return ConditionReading(names.contains(volumeName))
        case .unavailable: return .undetermined
        }
    }
}

// MARK: - Network addresses

/// The result of one pass over this Mac's interfaces: every IPv4 address it
/// currently holds, in host byte order, or an admission that the interface
/// list could not be read.
///
/// **An empty set is a real answer here, unlike the two readings above**, and
/// the difference is worth stating because the three observers look
/// interchangeable. `/` is always mounted and this process is always in
/// `runningApplications`, so an empty list from either of those is a failed
/// enumeration. But a Mac with Wi-Fi switched off and no cable really does
/// hold no non-loopback IPv4 address, and that is precisely "you are not on
/// that subnet" — a confident negative, correctly ending a
/// `.whileOnSubnet` session. Only `getifaddrs` itself failing is
/// `.unavailable`.
enum NetworkAddressReading: Equatable {
    case addresses(Set<UInt32>)
    case unavailable
}

/// Reading the interface list, split out from the subnet matching for the
/// reason `ProcessTableReading` is: the matching is then testable with no
/// network at all — see `IPv4Subnet` and its tests — and one read serves
/// every rule and session on a tick.
protocol NetworkAddressReader {
    func read() -> NetworkAddressReading
}

/// `getifaddrs(3)`: POSIX, present since forever, no entitlement, no
/// permission prompt, no framework to link. That is the whole reason
/// `.onSubnet` exists as the permission-free alternative to a Wi-Fi SSID
/// trigger, which needs Location Services on modern macOS.
///
/// What is skipped, and why:
///
/// * **`IFF_LOOPBACK`** — 127.0.0.1 is present on every Mac that has ever
///   booted, so a rule naming `127.0.0.0/8` would otherwise hold a Mac awake
///   forever, and a `/0` rule would match on a machine with no network at all.
/// * **anything not `IFF_UP | IFF_RUNNING`** — an interface that is
///   configured but not actually carrying traffic (a cable unplugged, Wi-Fi
///   associated but down) still reports its last address, which is exactly
///   the "you are still on the home network" claim this must not make.
/// * **anything that is not `AF_INET`** — link-layer and IPv6 entries share
///   the list. IPv6 is not silently ignored at the *rule* level: the Add
///   sheet refuses a v6 address with a sentence saying so
///   (`TriggerCondition.subnetProblem`).
///
/// `freeifaddrs` is paired with the one successful `getifaddrs` on every
/// path, including the early return, by a `defer` placed immediately after
/// the guard. This runs every 5 seconds for as long as the agent lives, so a
/// leak here is not a one-off.
struct GetifaddrsNetworkAddressReader: NetworkAddressReader {
    func read() -> NetworkAddressReading {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return .unavailable }
        defer { freeifaddrs(head) }

        var addresses = Set<UInt32>()
        var cursor = head
        while let entry = cursor {
            let interface = entry.pointee
            cursor = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_LOOPBACK == 0,
                  flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            // `s_addr` is network byte order; `IPv4Subnet` works in host order
            // so that its arithmetic reads the way the dotted quad does.
            addresses.insert(UInt32(bigEndian: raw))
        }
        return .addresses(addresses)
    }
}

/// Answers `.onSubnet` questions from a single interface enumeration.
///
/// Memoized with the tick's lifetime, exactly as
/// `SystemProcessRunningObserver` and `SystemMountedVolumeObserver` are: no
/// invalidation logic, because `EvidenceLoopRunner` builds a new one every
/// tick and the cache therefore cannot go stale.
final class SystemNetworkAddressObserver: NetworkAddressObserving {
    private let reader: NetworkAddressReader
    private var thisTick: NetworkAddressReading?

    init(reader: NetworkAddressReader = GetifaddrsNetworkAddressReader()) {
        self.reader = reader
    }

    func isOnSubnet(_ subnet: IPv4Subnet) -> ConditionReading {
        let result = thisTick ?? reader.read()
        thisTick = result
        switch result {
        case .addresses(let addresses): return ConditionReading(addresses.contains(where: subnet.contains))
        case .unavailable: return .undetermined
        }
    }
}

// MARK: - VPN

/// The result of one look at this Mac's network services: the identifiers of
/// every configured VPN service that is currently carrying traffic, or an
/// admission that the configuration database could not be read.
///
/// **An empty set is a real answer**, exactly as it is for
/// `NetworkAddressReading` and unlike `MountedVolumeReading`: a Mac with no
/// VPN configured, or with one configured and disconnected, genuinely has no
/// VPN up, and that is a confident "the tunnel is down" that correctly ends a
/// `.whileVPNActive` session. There is no always-present member here to make
/// emptiness impossible, the way `/` is for volumes and this process is for
/// `runningApplications`. Only the copy itself failing is `.unavailable`.
///
/// Service *identifiers* rather than a bare `Bool` so that a test can see
/// which service answered, and so that a failure message can name it.
enum VPNServiceReading: Equatable {
    case liveServiceIDs(Set<String>)
    case unavailable
}

/// Reading the network-service list, split out from the yes/no for the reason
/// `NetworkAddressReader` is: the decision is then testable with no VPN, no
/// network and no `configd` at all, and one read serves every rule and session
/// on a tick.
protocol VPNServiceReader {
    func read() -> VPNServiceReading
}

/// `SCDynamicStore`: no entitlement, no permission prompt, no dialog, and —
/// measured — 0.355 ms for the whole read.
///
/// ## What it asks
///
/// Two queries, joined:
///
/// 1. `Setup:/Network/Service/<id>/Interface` for every service, keeping the
///    ones whose `Type` is a VPN type. macOS models a VPN as a network service
///    exactly like Wi-Fi, so this is the system's *own* answer to "which of
///    these is a VPN" rather than a guess from an interface name.
/// 2. `State:/Network/Service/<id>/IPv4` and `/IPv6` for those services only.
///    The `State:` domain is liveness: it appears when the tunnel comes up and
///    is gone when it goes. Measured on the machine this was written on, four
///    configured-but-not-attached services (a dock, a USB Ethernet adapter, an
///    iPhone) had no `State:` entry at all, while the one connected VPN had
///    both.
///
/// ## Two roads not taken, and why
///
/// **`getifaddrs` for `utun*`.** The obvious read, and permanently true: this
/// Mac carries nine `utun` interfaces, all `UP,POINTOPOINT,RUNNING`, of which
/// one is the VPN. See `VPNObserving`.
///
/// **`State:/Network/Service/<id>/VPN` → `Status`.** It works — the value is
/// `7` while connected — but `7` is not a documented number.
/// `SCNetworkConnectionPPPStatus` puts `Connected` at **8** and
/// `NegotiatingNetwork` at 7, so the store publishes an internal enum that the
/// public API renumbers on the way out, and the values it takes while
/// *disconnected* were never observed. "Does this VPN service hold an address"
/// needs no enum and means the same thing.
///
/// **`SCNetworkConnectionGetStatus`, the documented API, is unusable here** and
/// this is the trap worth naming: `SCNetworkConnectionCreateWithServiceID`
/// blocks for **~290 ms** on any service that is not a live network
/// connection. Looping the nine services on this Mac costs **2.3 seconds**, on
/// a 5-second tick, on the main actor. It was used to *corroborate* this
/// reader (it and `scutil --nc list` both independently agreed) and is not in
/// the shipping path.
struct SCDynamicStoreVPNServiceReader: VPNServiceReader {
    /// The interface types that make a network service a VPN.
    ///
    /// `PPP`, `IPSec` and `L2TP` are `kSCNetworkInterfaceType*` constants;
    /// `VPN` is the type every NetworkExtension-based VPN reports and has no
    /// public constant, which is stated here rather than hidden behind one.
    /// `PPTP` is deprecated by Apple and costs nothing to keep.
    static let vpnInterfaceTypes: Set<String> = ["VPN", "PPP", "IPSec", "L2TP", "PPTP"]

    /// `[^/]+` rather than `.*` so the pattern cannot also match a deeper key
    /// (`…/Interface/Something`), which would put a non-identifier in the
    /// third path component.
    private static let interfacePattern = "Setup:/Network/Service/[^/]+/Interface"

    func read() -> VPNServiceReading {
        guard let store = SCDynamicStoreCreate(nil, "au.com.workwireless.keepy-uppy" as CFString, nil, nil)
        else { return .unavailable }
        // `nil` is the copy failing; an empty dictionary is "asked, and there
        // is nothing" — verified, and the whole reason this can distinguish a
        // Mac with no VPN from a read that did not happen.
        guard let interfaces = SCDynamicStoreCopyMultiple(
            store, nil, [Self.interfacePattern] as CFArray) as? [String: Any]
        else { return .unavailable }

        let vpnServiceIDs = interfaces.compactMap { key, value -> String? in
            guard let entity = value as? [String: Any],
                  let type = entity[kSCPropNetInterfaceType as String] as? String,
                  Self.vpnInterfaceTypes.contains(type),
                  let id = Self.serviceID(inKey: key)
            else { return nil }
            return id
        }
        guard !vpnServiceIDs.isEmpty else { return .liveServiceIDs([]) }

        // Both families, because a VPN handing out only an IPv6 address is up.
        let livePatterns = vpnServiceIDs.flatMap {
            ["State:/Network/Service/\($0)/IPv4", "State:/Network/Service/\($0)/IPv6"]
        }
        guard let live = SCDynamicStoreCopyMultiple(store, livePatterns as CFArray, nil) as? [String: Any]
        else { return .unavailable }
        return .liveServiceIDs(Set(live.keys.compactMap(Self.serviceID(inKey:))))
    }

    /// The identifier out of `<domain>:/Network/Service/<id>/<entity>`.
    /// Internal so the tests can pin the parse without reaching a live store.
    ///
    /// The shape is checked rather than assumed, even though every key reaching
    /// this comes from a pattern that already fixes it. Taking the fourth
    /// component of *any* key would read `State:/Network/Global/IPv4` as the
    /// service "IPv4" — a plausible-looking identifier that matches nothing,
    /// which is exactly how this observer would come to answer `.absent` on a
    /// Mac whose VPN is up, and end every `.whileVPNActive` session on it.
    static func serviceID(inKey key: String) -> String? {
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4, components[1] == "Network", components[2] == "Service"
        else { return nil }
        let id = String(components[3])
        return id.isEmpty ? nil : id
    }
}

/// Answers `.vpnActive` questions from a single network-service read.
///
/// Memoized with the tick's lifetime, exactly as `SystemNetworkAddressObserver`
/// and the two before it are: no invalidation logic, because
/// `EvidenceLoopRunner` builds a new one every tick and the cache therefore
/// cannot go stale.
final class SystemVPNObserver: VPNObserving {
    private let reader: VPNServiceReader
    private var thisTick: VPNServiceReading?

    init(reader: VPNServiceReader = SCDynamicStoreVPNServiceReader()) {
        self.reader = reader
    }

    func isVPNActive() -> ConditionReading {
        let result = thisTick ?? reader.read()
        thisTick = result
        switch result {
        case .liveServiceIDs(let ids): return ConditionReading(!ids.isEmpty)
        case .unavailable: return .undetermined
        }
    }
}

/// Answers `.processRunning` questions from a single process-table read.
///
/// The table is ~530 entries for one uid and costs a few milliseconds to
/// enumerate; before this, `sessionsToEnd` and `triggersToFire` between them
/// enumerated it once per rule *and* once per session, every 5 seconds. One
/// instance answers every question on a tick from one read.
///
/// The memoization is safe by construction rather than by discipline: this
/// object holds no invalidation logic and offers no way to clear its cache,
/// because `EvidenceLoopRunner` makes a new one every tick. The cache's
/// lifetime *is* the tick, so it cannot be forgotten about and go stale.
final class SystemProcessRunningObserver: ProcessRunningObserving {
    private let reader: ProcessTableReading
    private var thisTick: ProcessTableReadResult?

    init(reader: ProcessTableReading = SysctlProcessTableReader()) {
        self.reader = reader
    }

    func isRunning(processName: String) -> ConditionReading {
        let result = thisTick ?? reader.read()
        thisTick = result
        switch result {
        case .names(let names): return ConditionReading(names.contains(processName))
        case .unavailable: return .undetermined
        }
    }
}
