import Foundation

enum ThermalLevel: Int, Comparable, Codable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

enum SafetyReason: String, Equatable, Codable {
    case thermal, lowBattery, maxDuration
}

enum SafetyOutcome: Equatable {
    case none
    case warn(reason: SafetyReason, actAt: Date)
    case stopAll(reason: SafetyReason)
}

struct SafetyConfig {
    var thermalGuardEnabled: Bool
    /// nil disables the guard.
    var batteryCutoff: Int?
    /// nil disables the backstop.
    var maxSessionDuration: TimeInterval?
    var lidClosedStricter: Bool
    var gracePeriod: TimeInterval
    var cooldown: TimeInterval
    /// Percentage points above the cutoff the battery must recover before
    /// triggers are released again.
    var batteryHysteresis: Int

    static let `default` = SafetyConfig(
        thermalGuardEnabled: true,
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
    let config: SafetyConfig
    private var pendingWarning: (reason: SafetyReason, actAt: Date)?
    private var suppressedSince: Date?
    private var suppressionReason: SafetyReason?

    init(config: SafetyConfig) { self.config = config }

    /// True while a trigger-driven start must not be honoured. Manual starts
    /// are always allowed; this only gates automation (spec §7).
    var triggersSuppressed: Bool { suppressedSince != nil }

    mutating func evaluate(_ inputs: SafetyInputs) -> SafetyOutcome {
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
        // Only the first breach starts the cooldown clock. If we reset it on
        // every repeat breach while already suppressed, a still-active
        // condition (or one that keeps re-triggering just below full
        // recovery) would push the clock forward forever and suppression
        // would never release — the exact fight-the-user bug this engine
        // exists to prevent (spec §7).
        if suppressedSince == nil {
            suppressedSince = now
        }
        suppressionReason = reason
        return .stopAll(reason: reason)
    }

    private func breach(_ inputs: SafetyInputs) -> SafetyReason? {
        if config.thermalGuardEnabled {
            let limit: ThermalLevel = (inputs.lidClosed && config.lidClosedStricter)
                ? .fair : .serious
            if inputs.thermal >= limit { return .thermal }
        }
        if let cutoff = config.batteryCutoff, inputs.onBattery,
           let level = inputs.batteryPercentage {
            let effective = (inputs.lidClosed && config.lidClosedStricter) ? cutoff + 5 : cutoff
            if level <= effective { return .lowBattery }
        }
        if let maximum = config.maxSessionDuration, let age = inputs.oldestSessionAge,
           age >= maximum {
            return .maxDuration
        }
        return nil
    }

    private mutating func releaseSuppressionIfClear(_ inputs: SafetyInputs) {
        guard let since = suppressedSince, let reason = suppressionReason else { return }
        guard inputs.now.timeIntervalSince(since) >= config.cooldown else { return }

        let recovered: Bool
        switch reason {
        case .thermal:
            recovered = inputs.thermal == .nominal
        case .lowBattery:
            guard let cutoff = config.batteryCutoff else { recovered = true; break }
            recovered = (inputs.batteryPercentage ?? 100) >= cutoff + config.batteryHysteresis
        case .maxDuration:
            recovered = (inputs.oldestSessionAge ?? 0) < (config.maxSessionDuration ?? .infinity)
        }

        if recovered {
            suppressedSince = nil
            suppressionReason = nil
        }
    }
}
