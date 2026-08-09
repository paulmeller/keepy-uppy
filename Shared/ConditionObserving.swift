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

/// Whether a named app is the one the user is *looking at*, which is a
/// strictly stronger fact than `AppRunningObserving`'s and a much more
/// fragile one — it changes every time a window is switched.
///
/// That fragility is why nothing binds a session's lifetime to it (see
/// `TriggerConditionKind.bindsSessionLifetime`), and it is also why the
/// `.undetermined` case here is not a formality. `frontmostApplication` is
/// `nil` whenever no app owns the front: the screen is locked, the login
/// window is up, another user is switched in. None of those means "you
/// switched away from Xcode", and none of them may start a session.
protocol FrontmostAppObserving {
    func isFrontmost(bundleID: String) -> ConditionReading
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
///
/// The one conformer requirement that is not visible in the signature, and is
/// the exact opposite of `ProcessRunningObserving`'s above: **CPU busy is a
/// rate, so a conformer is stateful and must outlive the tick**. There is no
/// instantaneous "how busy is the CPU" to read — the kernel only offers
/// counters cumulative since boot, so the answer is a difference between two
/// readings taken at two times, and dividing a single reading yields the
/// machine's lifetime average instead (which is what shipped, and what
/// `SystemCPUBusyObserver` documents in full). Two consequences:
///
/// * `currentBusy()` is deliberately **non-mutating**, which forces a
///   conformer to be a reference type. A `struct` would lose its previous
///   sample on every copy, including the copy taken when it is stored as this
///   existential, and would then never have a predecessor at all.
/// * It must be called **exactly once per tick**, by one long-lived instance.
///   That is why `ObserverSet.cpuBusy` is a pre-taken `CPUBusyReading` rather
///   than a `CPUBusyObserving`: asking twice in a tick would not give two
///   sessions two answers, it would give the second one a measurement over an
///   interval of nearly zero and leave the first's interval truncated.
protocol CPUBusyObserving {
    func currentBusy() -> CPUBusyReading
}

/// Every fact one evidence-loop tick needs, in one value.
///
/// `triggersToFire` and `sessionsToEnd` each took one parameter per observer.
/// Four was tolerable. Plan 5 adds six conditions, which would make both
/// signatures ten parameters long and would make all six per-trigger tasks edit
/// the same two lines — six conflicts over nothing, in diffs that are supposed
/// to be readable.
///
/// A plain struct, not a protocol: the call sites want values, the tests want to
/// substitute one member and leave the rest harmless, and nothing needs to swap
/// the whole bundle for another implementation.
///
/// Note the deliberate asymmetry. Most members are *observers*, asked a question
/// per rule or per session. Two are pre-taken *readings*: `acPower`, because
/// `PowerControl.batteryState()` lives in `Shared/` and the runner already reads
/// it once a tick, and `cpuBusy`, because a CPU sample is a delta between two
/// points in time (see `SystemCPUBusyObserver`) and so must be taken exactly
/// once per tick by something that outlives the tick. Folding those two into
/// observers would either re-read them per session or hide state where its
/// lifetime is not obvious. They stay readings, and this comment is why.
///
/// Two rules this type exists under, both of which protect the tri-state
/// contract documented on `ConditionReading` above:
///
/// 1. **No member may have a default value.** Every member is stated at every
///    construction site, so adding the seventh, eighth or ninth observer is a
///    compile error everywhere it needs to be answered for rather than a silent
///    substitution of somebody else's idea of harmless. `Session` has exactly
///    three defaulted fields and they have caused four separate defects by
///    being omittable without a compile error; this bundle will not repeat it.
/// 2. **Members are readings and observers, never `Bool`.** Bundling the
///    arguments together must not become the place a tri-state collapses into
///    two states. `.undetermined` survives the trip through this struct
///    untouched, and the only things that ever narrow it are
///    `isConfidentlyPresent` (may start a session) and `isConfidentlyAbsent`
///    (may end one).
struct ObserverSet {
    var appRunning: AppRunningObserving
    var display: DisplayObserving
    var processRunning: ProcessRunningObserving
    var frontmostApp: FrontmostAppObserving
    var acPower: ConditionReading
    var cpuBusy: CPUBusyReading
}
