import Foundation

// MARK: - The observer contract, shared between the agent's evidence loop
// (Agent/EvidenceLoop.swift) and the pure trigger evaluator
// (Shared/TriggerRule.swift). Declared here, not in
// Agent/ConditionObservers.swift, because Shared/ compiles into every
// target — including the daemon and CLI — which must not gain those live
// implementations' AppKit/CoreGraphics dependency. The live implementations
// (SystemAppRunningObserver, SystemDisplayObserver,
// SystemProcessRunningObserver, SystemCPUBusyObserver) stay in
// Agent/ConditionObservers.swift.

/// One observation of a condition, including the answer a `Bool` return type
/// could not express: "I could not tell."
///
/// The third case is safety-critical, not stylistic. `sessionsToEnd`
/// (Agent/EvidenceLoop.swift) ends a live session when its condition stops
/// holding, and ending a session is what lets the Mac go to sleep. While
/// these observers returned `Bool`, a failed *observation* — a `sysctl` that
/// came back `ENOMEM` under process churn, a display list that could not be
/// enumerated, a Launch Services query that answered nothing — was
/// indistinguishable from a confident "the condition is false", so a
/// momentary inability to look put the Mac to sleep in the middle of the
/// build the session existed to protect.
///
/// The rule the rest of the codebase enforces on top of this type:
///
/// * `sessionsToEnd` ends a session only on a *confident negative*
///   (`.absent`). This is the safety-critical half — an observer that cannot
///   answer must not be able to sleep a Mac.
/// * `triggersToFire` (Shared/TriggerRule.swift) starts a session only on a
///   *confident positive* (`.present`).
///
/// `.undetermined` therefore does nothing at all, which is the only reading
/// that is safe in both directions. Six more triggers are planned (Wi-Fi
/// SSID, VPN, IP address, USB/Bluetooth device, mounted volume, frontmost
/// app); every one of them has a read that can fail, and every one of them
/// inherits this rule for free rather than re-deriving it — a failed SSID
/// read reads as "I don't know", not as "you left the network."
enum ConditionReading: Equatable {
    /// The condition definitely holds right now.
    case present
    /// The condition definitely does not hold right now. The *only* reading
    /// that may end a live session.
    case absent
    /// The observation failed. Says nothing about the condition itself.
    case undetermined

    /// For observers whose underlying read cannot fail, or that have already
    /// separated their failure path out.
    init(_ holds: Bool) { self = holds ? .present : .absent }

    /// Confident positive: the only reading that may start a session.
    var isConfidentlyPresent: Bool { self == .present }

    /// Confident negative: the only reading that may end one.
    var isConfidentlyAbsent: Bool { self == .absent }
}

/// The CPU analogue of `ConditionReading`. CPU-busy is a measurement rather
/// than a yes/no, so the determined case carries its value — but the failure
/// case means exactly what `.undetermined` means above, and `sessionsToEnd`
/// treats it the same way: a sample that could not be taken is not a quiet
/// CPU, and must not end a `.whileCPUBusy` session.
enum CPUBusyReading: Equatable {
    /// Fraction of CPU time that was not idle, 0...1.
    case busy(fraction: Double)
    /// The sample could not be taken.
    case undetermined
}

protocol AppRunningObserving {
    func isRunning(bundleID: String) -> ConditionReading
}

protocol DisplayObserving {
    func hasExternalDisplay() -> ConditionReading
}

/// Unlike `AppRunningObserving`, which matches a bundle ID against
/// `NSWorkspace.runningApplications`, this matches a plain executable name
/// (e.g. `claude`, `codex`) against the live process table — for CLI tools
/// that have no bundle ID or `NSRunningApplication` entry at all. Exact-name
/// matching only: no path, no arguments. A generic name (`pi`, `agent`) can
/// therefore match an unrelated process of the same name — the Settings UI
/// warns on the two presets where that's a realistic risk.
///
/// Conformers are expected to be cheap to make and to live for exactly one
/// evidence-loop tick, because enumerating the process table is not cheap
/// (~530 entries for one uid here) and every rule and every session on a tick
/// asks the same question. `EvidenceLoopRunner` makes one per tick and lets
/// `SystemProcessRunningObserver` memoize its single read inside that
/// lifetime — a cache that cannot go stale, because the object holding it
/// does not outlive the tick that made it.
protocol ProcessRunningObserving {
    func isRunning(processName: String) -> ConditionReading
}

/// Lives here with the other three rather than in
/// Agent/ConditionObservers.swift (where it used to sit, on the grounds that
/// nothing outside the agent evaluates CPU-busy conditions) so that the whole
/// observer contract — all four protocols and both reading types — is one
/// file you can read end to end. The protocol itself has no framework
/// dependency; only `SystemCPUBusyObserver` does, and that stays in the agent.
protocol CPUBusyObserving {
    func currentBusy() -> CPUBusyReading
}
