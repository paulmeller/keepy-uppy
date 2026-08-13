import Foundation

enum ThermalLevel: Int, Comparable, Codable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Why a safety guard ended every session on this Mac.
///
/// ## `CaseIterable` — sanctioned now, having been declined once, and for a
/// different job
///
/// Plan 7's review contemplated this conformance (Task 12, item 13: *"plus
/// `SafetyReason: CaseIterable` if Task 6 chose to sanction it"*) and Plan 7
/// Task 6 **declined** it. That refusal was right for the job it was offered:
/// the conformance was wanted so a test could assert that no notification
/// string contains a `SafetyReason`, and `Sources/SessionNotifications.swift`
/// records at length why that test is vacuous — the raw values below
/// (`thermal`, `lowBattery`, `maxDuration`) are tokens no user-facing sentence
/// contains, so it passes today *and* would pass on copy reading "Your Mac was
/// overheating".
///
/// It earns its place here doing a **different job**, and the earlier refusal
/// should read as superseded rather than reversed by accident. Two callers need
/// to enumerate reasons, and neither is a string search:
///
/// 1. `Tests/SessionTests.swift` sends one `SafetyStopRecord` per reason over a
///    real XPC round trip, written over `allCases`, so a fourth reason cannot
///    escape the wire proof by nobody remembering to add it.
/// 2. `Sources/SessionNotifications.swift` welds this enum to the
///    reason-carrying notification events as a **bijection** checked over
///    `allCases` in both directions — the same weld `SessionKind.Family` has
///    with the CLI's flags and `TriggerConditionKind` has with its own pair. A
///    fourth reason then fails a test instead of quietly having no banner.
///
/// Both are "every case must be accounted for somewhere else", which is exactly
/// what `CaseIterable` is for and what a hand-written list of three is not.
enum SafetyReason: String, Equatable, Codable, CaseIterable {
    case thermal, lowBattery, maxDuration
}

enum SafetyOutcome: Equatable {
    case none
    case warn(reason: SafetyReason, actAt: Date)
    case stopAll(reason: SafetyReason)
}

/// A named cutoff rather than a raw `ThermalLevel`, because thermal states are
/// jargon in a Settings UI — "cautious/balanced/permissive" is a real choice a
/// user can make; "serious vs. critical" is not.
enum ThermalSensitivity: String, Codable, CaseIterable {
    case off, cautious, balanced, permissive

    /// nil means the guard is disabled.
    func limit(lidClosed: Bool) -> ThermalLevel? {
        switch self {
        case .off: return nil
        case .cautious: return lidClosed ? .fair : .serious
        case .balanced: return lidClosed ? .serious : .critical
        case .permissive: return .critical
        }
    }
}

struct SafetyConfig: Codable, Equatable {
    // `.balanced` is the deliberate default. `.fair` only means fans are
    // audible, so a sustained build with the lid shut reaches it within
    // minutes — defaulting there would stop the very sessions this product
    // exists to sustain, reading as "the feature is broken" rather than "the
    // guard worked". `.serious` (lid closed) means the machine is actually
    // throttling, a real signal; users wanting maximum caution can opt into
    // `.cautious` explicitly.
    var thermalSensitivity: ThermalSensitivity
    /// nil disables the guard.
    var batteryCutoff: Int?
    /// nil disables the backstop.
    var maxSessionDuration: TimeInterval?
    /// Still governs the battery cutoff: tighter while the lid is genuinely
    /// shut and the machine cannot breathe.
    var lidClosedStricter: Bool

    /// Percentage points added to `batteryCutoff` while the lid is shut.
    /// Named once here because both `breach(_:)` and the Settings pane need
    /// it: the pane tells the user the effective threshold, and a literal
    /// duplicated across that boundary would keep printing the old number
    /// after the engine changed, with no compile error and no failing test.
    static let lidClosedMargin = 5

    /// The cutoff actually applied for a given lid state, or nil when the
    /// guard is off entirely.
    func effectiveBatteryCutoff(lidClosed: Bool) -> Int? {
        guard let batteryCutoff else { return nil }
        return (lidClosed && lidClosedStricter) ? batteryCutoff + Self.lidClosedMargin : batteryCutoff
    }
    var gracePeriod: TimeInterval
    var cooldown: TimeInterval
    /// Percentage points above the cutoff the battery must recover before
    /// triggers are released again.
    var batteryHysteresis: Int

    static let `default` = SafetyConfig(
        thermalSensitivity: .balanced,
        batteryCutoff: 10,
        maxSessionDuration: 8 * 3600,
        lidClosedStricter: true,
        gracePeriod: 60,
        cooldown: 300,
        batteryHysteresis: 5
    )
}

struct SafetyInputs {
    let thermal: ThermalLevel
    let batteryPercentage: Int?
    let onBattery: Bool
    let lidClosed: Bool
    let oldestSessionAge: TimeInterval?
    let now: Date
}

/// Pure reducer. No I/O, no clock of its own — every input including `now`
/// arrives in `SafetyInputs`, so all of this is testable instantly.
struct SafetyEngine {
    var config: SafetyConfig
    private var pendingWarning: (reason: SafetyReason, actAt: Date)?
    private var suppressionReason: SafetyReason?
    /// When the triggering condition most recently began looking recovered.
    /// Reset to nil whenever conditions breach again, so a still-active (or
    /// flapping-just-below-recovery) condition can never accumulate a stale
    /// head start on the cooldown clock.
    private var recoveredSince: Date?

    /// Battery time the current run of sessions has spent, and the reading it
    /// was last measured from.
    ///
    /// The backstop is a budget of *battery* time rather than wall clock,
    /// because the risk it guards against is a forgotten session flattening a
    /// battery or cooking a closed laptop in a bag — neither of which a
    /// mains-powered Mac is doing. Timing wall clock instead ended the exact
    /// session `keepy-uppy on` exists to hold open.
    ///
    /// It has to be *accrued* rather than measured from an unplug instant, for
    /// the failure either alternative produces:
    ///
    /// - Gating a wall-clock check on `onBattery` stops everything the moment
    ///   the charger leaves a Mac that has been plugged in all day, since
    ///   `age >= maximum` is already true. A guard that fires on unplugging is
    ///   worse than no guard, because it fires exactly when the user is leaving.
    /// - Restarting the clock on each unplug means a laptop that touches a
    ///   charger occasionally never reaches the backstop at all.
    ///
    /// Like `pendingWarning` and `recoveredSince`, this is engine-local and so
    /// starts fresh if the daemon restarts under a live session. That is the
    /// existing behaviour of every other clock here, not a new gap.
    private var batteryTimeAccrued: TimeInterval = 0
    private var batteryClockLastRead: Date?

    init(config: SafetyConfig) { self.config = config }

    /// True while a trigger-driven start must not be honoured. Manual starts
    /// are always allowed; this only gates automation (spec §7).
    var triggersSuppressed: Bool { suppressionReason != nil }

    mutating func evaluate(_ inputs: SafetyInputs) -> SafetyOutcome {
        advanceBatteryClock(inputs)
        releaseSuppressionIfClear(inputs)

        guard let reason = breach(inputs) else {
            pendingWarning = nil
            return .none
        }

        // The lid being shut means nobody can see a warning, so acting late
        // to display one is exactly backwards.
        let warningIsPointless = inputs.lidClosed
        if warningIsPointless || reason == .maxDuration {
            return stop(reason: reason, at: inputs.now)
        }

        if let pending = pendingWarning, pending.reason == reason {
            return inputs.now >= pending.actAt
                ? stop(reason: reason, at: inputs.now)
                : .warn(reason: reason, actAt: pending.actAt)
        }

        let actAt = inputs.now.addingTimeInterval(config.gracePeriod)
        pendingWarning = (reason, actAt)
        return .warn(reason: reason, actAt: actAt)
    }

    private mutating func stop(reason: SafetyReason, at now: Date) -> SafetyOutcome {
        pendingWarning = nil
        suppressionReason = reason
        // A breach just happened, so by definition recovery isn't in
        // progress right now.
        recoveredSince = nil
        return .stopAll(reason: reason)
    }

    /// Accrues battery time between readings, and only between readings: a
    /// stretch the engine never saw is a stretch nobody can vouch for.
    private mutating func advanceBatteryClock(_ inputs: SafetyInputs) {
        // Nothing to time, and the next run must start from zero rather than
        // inherit a spent budget.
        guard inputs.oldestSessionAge != nil else {
            batteryTimeAccrued = 0
            batteryClockLastRead = nil
            return
        }
        guard inputs.onBattery else {
            // Pause, keeping what has been spent.
            batteryClockLastRead = nil
            return
        }
        if let last = batteryClockLastRead {
            batteryTimeAccrued += inputs.now.timeIntervalSince(last)
        }
        batteryClockLastRead = inputs.now
    }

    private func breach(_ inputs: SafetyInputs) -> SafetyReason? {
        if let limit = config.thermalSensitivity.limit(lidClosed: inputs.lidClosed),
           inputs.thermal >= limit {
            return .thermal
        }
        if inputs.onBattery, let level = inputs.batteryPercentage,
           let effective = config.effectiveBatteryCutoff(lidClosed: inputs.lidClosed) {
            if level <= effective { return .lowBattery }
        }
        if let maximum = config.maxSessionDuration, inputs.onBattery,
           batteryTimeAccrued >= maximum {
            return .maxDuration
        }
        return nil
    }

    /// Cooldown release must be anchored to when conditions *recovered*, not
    /// to when the episode began. Anchoring to episode start inverts the risk
    /// profile: a long, severe episode would already have outlived the
    /// cooldown by the time it finally cooled, so triggers would re-arm on
    /// the very first good reading with no settling time, while a brief
    /// episode waits the full period regardless of how mild it was.
    private mutating func releaseSuppressionIfClear(_ inputs: SafetyInputs) {
        guard let reason = suppressionReason else { return }

        guard recovered(reason, inputs) else {
            recoveredSince = nil
            return
        }

        let since = recoveredSince ?? inputs.now
        recoveredSince = since
        if inputs.now.timeIntervalSince(since) >= config.cooldown {
            suppressionReason = nil
            recoveredSince = nil
        }
    }

    private func recovered(_ reason: SafetyReason, _ inputs: SafetyInputs) -> Bool {
        switch reason {
        case .thermal:
            return inputs.thermal == .nominal
        case .lowBattery:
            guard let cutoff = config.batteryCutoff else { return true }
            // Plugging in removes the danger outright, regardless of what
            // the percentage happens to read.
            if !inputs.onBattery { return true }
            // Must strictly clear the threshold. With defaults the
            // lid-closed breach threshold (cutoff + 5 = 15) and this
            // recovery threshold (cutoff + hysteresis = 15) coincide at
            // exactly 15%; `>=` would let the engine consider itself
            // recovered while still breaching, releasing and immediately
            // re-breaching in the same evaluation.
            return (inputs.batteryPercentage ?? 100) > cutoff + config.batteryHysteresis
        case .maxDuration:
            // Mirrors `breach`: plugging in removes the danger outright, and
            // otherwise the budget has to have actually come back — which it
            // does when the stopped sessions leave and `advanceBatteryClock`
            // resets the accrual.
            if !inputs.onBattery { return true }
            return batteryTimeAccrued < (config.maxSessionDuration ?? .infinity)
        }
    }
}
