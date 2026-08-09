import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

/// `Shared/` is compiled into all four targets, so it cannot reach the
/// daemon's `helperLogger` (which lives in `Helper/`). Assertion transitions
/// are the one part of this file worth a log line of their own — they are the
/// mechanism a user can independently check with `pmset -g assertions`, and a
/// create that silently failed is otherwise invisible.
let powerLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "power")

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

// MARK: - Power assertions
//
// The second of the two mechanisms. Read `.superpowers/sdd/power-assertion-
// research.md` before changing anything here; the short version is:
//
//   `SleepDisabled` (above)          `IOPMAssertion` (below)
//   survives lid close: YES          survives lid close: NO (15/15 observed
//                                      clamshell sleeps happened with
//                                      sleep-preventing assertions live)
//   scope: one global boolean        scope: per-process, refcounted by the OS
//   privilege: root                  privilege: none
//   on holder death: PERSISTS        on holder death: auto-released
//     (across reboot, too)             (`powerd` logs it as `ClientDied`)
//   display sleep separately: no     display sleep separately: yes
//   API: undeclared SPI              API: public, headered
//
// They are complementary, not alternatives, and they are kept deliberately
// separate here rather than unified behind one abstraction: `setSleepDisabled`
// needs converge-to-safe-at-launch reconciliation *because* it persists, and
// assertions do not. Unifying would force the safer mechanism to inherit the
// more dangerous one's ceremony, and would hide exactly the asymmetry that has
// to stay visible.

/// The **only** two assertion types this project may use.
///
/// `kIOPMAssertionTypePreventSystemSleep` is deliberately absent and must stay
/// absent. Its own header says "Deprecated in 10.9. This assertion is not
/// supported in any OS X releases", and it was observed returning
/// `kIOReturnSuccess`, appearing in `pmset`'s per-process listing, and moving
/// **no** system-wide counter — it fails silently, which is the worst failure
/// mode available to a thing whose job is keeping a Mac awake.
/// `PowerAssertionTypeTests` pins that absence.
enum PowerAssertionType: String, CaseIterable, Equatable, Hashable {
    /// `PreventUserIdleSystemSleep`. "The display may dim and idle sleep …
    /// but the system may not idle sleep." The mode most long-running
    /// headless work actually wants.
    case preventIdleSystemSleep
    /// `PreventUserIdleDisplaySleep`. Note the header's own aside: "While the
    /// display is prevented from dimming, the system cannot go into idle
    /// sleep" — so this one *implies* the other rather than being orthogonal
    /// to it. `PowerPlan.reduce` still holds both explicitly; see there.
    case preventIdleDisplaySleep

    /// The IOKit type string.
    ///
    /// These constants are `#define … CFSTR("…")` macros, which Clang imports
    /// into Swift as plain `String` — *not* `CFString`, which is why the
    /// `as CFString` bridge lives at the call site rather than here. Verified
    /// by compiling `type(of: kIOPMAssertPreventUserIdleSystemSleep)`, which
    /// prints `String`.
    var ioKitType: String {
        switch self {
        case .preventIdleSystemSleep: return kIOPMAssertPreventUserIdleSystemSleep
        case .preventIdleDisplaySleep: return kIOPMAssertPreventUserIdleDisplaySleep
        }
    }

    /// The `AssertionName` handed to `IOPMAssertionCreateWithName`. This is
    /// free external observability — it is what a user (or the manual test
    /// checklist) sees in `pmset -g assertions`, so it is written to be read
    /// by a human looking for why their Mac will not sleep. Max 128 chars per
    /// the header.
    ///
    /// **ASCII only, deliberately.** The first version of these strings used
    /// an em dash and `pmset -g assertions` printed it as a replacement
    /// character:
    ///
    ///     pid 83699(probe): […] named: "Keepy Uppy <?> keeping the system awake"
    ///
    /// The name exists to be read in exactly that output, so it has to survive
    /// exactly that output.
    /// `PowerAssertionTypeTests.testAssertionNamesIdentifyTheAppAndSurvivePmsetOutput`
    /// pins the constraint.
    var assertionName: String {
        switch self {
        case .preventIdleSystemSleep: return "Keepy Uppy: keeping the system awake"
        case .preventIdleDisplaySleep: return "Keepy Uppy: keeping the display awake"
        }
    }
}

/// What the machine's power state should be, given the sessions that are
/// currently live: the pure reduction, and the piece that carries the safety
/// semantics.
///
/// ## The two axes
///
/// The spec frames clamshell as "a second axis, not a third enum value", while
/// `WakeMode` is a flat three-case enum. Both are right, at different layers,
/// and this type is where they meet:
///
/// - `WakeMode` is a **user-facing choice** — one radio button, one CLI flag,
///   one value on the wire. Three named points, not a 2×2 grid to fill in.
/// - `PowerPlan` is the **mechanism**, and there the two axes are real and
///   must not be conflated, because they are backed by different APIs with
///   different privilege, lifetime, and failure semantics:
///     - `assertions` — *how much idle sleep to prevent* (system only, or
///       system and display). Unprivileged, refcounted, auto-released.
///     - `sleepDisabled` — *may the lid be shut?* Root-only, global,
///       persistent across process death and reboot.
///
/// The three `WakeMode` cases are the three *reachable* points of that grid
/// for a single session; the fourth cell (display held awake **and** lid may
/// be shut) is a contradiction to ask for, because a shut lid sleeps the
/// display in hardware regardless. It is still reachable here, and correctly
/// so, as the *union* of two live sessions wanting different things — which is
/// precisely why the reduction, and not the enum, is where the axes have to
/// live.
struct PowerPlan: Equatable {
    /// Axis 1. At most one assertion of each type is ever held, no matter how
    /// many sessions want it — the OS refcounts per creation, so one
    /// assertion per session would only leak `IOPMAssertionID`s.
    let assertions: Set<PowerAssertionType>
    /// Axis 2. One global boolean with no refcount of its own, so it must be
    /// cleared exactly when the *last* clamshell session ends.
    let sleepDisabled: Bool

    /// No sessions: nothing held, and the Mac may sleep normally again.
    static let sleepAllowed = PowerPlan(assertions: [], sleepDisabled: false)

    /// The reduction: the set of `WakeMode`s wanted across all live sessions
    /// becomes the assertions to hold and whether the global setting is on.
    ///
    /// It is a **union**, so the strongest request wins on each axis
    /// independently and no session can weaken another's. Order-independent
    /// and duplicate-insensitive by construction.
    ///
    /// Two decisions worth stating outright, because neither is forced:
    ///
    /// 1. **Every live mode takes the system assertion**, including
    ///    `.clamshell` and including `.systemAndDisplay` (whose display
    ///    assertion already implies it). Holding it unconditionally makes the
    ///    system assertion's lifetime exactly "some session is live", which
    ///    removes a whole class of transition bug: shrinking from
    ///    `{.systemAndDisplay}` to `{.system}` can never open a window with
    ///    nothing held. It is also defence in depth for `.clamshell`, whose
    ///    real mechanism is root-only undeclared SPI that can fail — if
    ///    `setSleepDisabled` returns false, idle sleep is still prevented,
    ///    and `pmset -g assertions` still shows a user why. The redundancy
    ///    costs one assertion.
    /// 2. **`.clamshell` does not take the display assertion.** The lid is
    ///    shut; there is no display to hold awake, and asking would be a
    ///    contradiction rather than a harmless no-op.
    static func reduce<Modes: Sequence>(_ modes: Modes) -> PowerPlan
    where Modes.Element == WakeMode {
        var assertions: Set<PowerAssertionType> = []
        var sleepDisabled = false
        for mode in modes {
            assertions.insert(.preventIdleSystemSleep)
            if mode.holdsDisplayAwake { assertions.insert(.preventIdleDisplaySleep) }
            if mode.requiresSleepDisabled { sleepDisabled = true }
        }
        return PowerPlan(assertions: assertions, sleepDisabled: sleepDisabled)
    }
}

/// The IOKit calls `PowerAssertions` makes, behind a seam.
///
/// The seam exists so the create/release *bookkeeping* — the part that leaks
/// `IOPMAssertionID`s when it is wrong — can be tested without a test ever
/// creating a real system assertion. A unit test that fails between create and
/// release would leave the machine awake after the run.
protocol PowerAssertionBackend {
    /// Returns the new assertion's id, or `nil` if the create failed.
    func create(type: PowerAssertionType, name: String) -> IOPMAssertionID?
    /// Returns whether the release succeeded.
    func release(_ id: IOPMAssertionID) -> Bool
}

struct IOKitPowerAssertionBackend: PowerAssertionBackend {
    func create(type: PowerAssertionType, name: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type.ioKitType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            powerLogger.error("IOPMAssertionCreateWithName(\(type.ioKitType)) failed: \(result)")
            return nil
        }
        return id
    }

    func release(_ id: IOPMAssertionID) -> Bool {
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            powerLogger.error("IOPMAssertionRelease(\(id)) failed: \(result)")
        }
        return result == kIOReturnSuccess
    }
}

/// Holds at most one assertion of each type and converges that set on demand.
///
/// Stateful on purpose: the live `IOPMAssertionID`s *are* the state, which is
/// why this is an owned instance rather than another static namespace like
/// `PowerControl`. The daemon owns one for its whole lifetime.
///
/// **Not thread-safe.** It is confined to `DaemonRuntime`'s serial queue, the
/// same confinement `applyLocked`'s name already advertises for the session
/// engines.
///
/// Explicit release is the plan, not a nicety. Assertions are reaped when the
/// holding process dies (verified by SIGKILL — the assertion vanished with no
/// chance to run cleanup), but that only fires on *process* death. A session
/// that ends while the daemon keeps running still needs a real
/// `IOPMAssertionRelease`, or assertions accumulate for the daemon's lifetime.
final class PowerAssertions {
    private let backend: PowerAssertionBackend
    private var held: [PowerAssertionType: IOPMAssertionID] = [:]

    init(backend: PowerAssertionBackend = IOKitPowerAssertionBackend()) {
        self.backend = backend
    }

    deinit { releaseAll() }

    /// What is actually held right now, for the daemon's own logging and for
    /// tests. Deliberately not a status source for users: assertions are
    /// advisory ("IOKit power assertions are suggestions and OS X may not
    /// honor them"), so `pmset -g assertions` is the truth about the machine
    /// and this is only the truth about what we asked for.
    var heldTypes: Set<PowerAssertionType> { Set(held.keys) }

    /// Converge the held set to `wanted`. Idempotent: calling it twice with
    /// the same set creates nothing the second time.
    ///
    /// Returns `false` if any wanted assertion could not be created, so the
    /// daemon can treat a failed apply the same way it already treats a failed
    /// `setSleepDisabled`. A failed create simply leaves that type unheld, so
    /// the next apply retries it.
    ///
    /// Creates run before releases so a transition never passes through a
    /// moment with strictly less held than either the old or new set.
    @discardableResult
    func apply(_ wanted: Set<PowerAssertionType>) -> Bool {
        var succeeded = true

        for type in PowerAssertionType.allCases
        where wanted.contains(type) && held[type] == nil {
            if let id = backend.create(type: type, name: type.assertionName) {
                held[type] = id
                powerLogger.log("Assertion held: \(type.ioKitType) (id \(id))")
            } else {
                succeeded = false
                powerLogger.error("Assertion NOT held: \(type.ioKitType) could not be created")
            }
        }

        for type in PowerAssertionType.allCases where !wanted.contains(type) {
            // Remove first, then release. The stored id is cleared whether or
            // not the release succeeds, so nothing can ever release the same
            // id twice: `IOPMAssertionID` is an opaque handle and whether
            // `powerd` recycles them was never established, so a stale id is
            // treated as unsafe to reuse rather than merely useless.
            guard let id = held.removeValue(forKey: type) else { continue }
            let ok = backend.release(id)
            powerLogger.log("Assertion released: \(type.ioKitType) (id \(id)), success=\(ok)")
        }

        return succeeded
    }

    /// Drop everything. Routed through `apply` so the two teardown paths
    /// cannot drift apart.
    func releaseAll() { _ = apply([]) }
}
