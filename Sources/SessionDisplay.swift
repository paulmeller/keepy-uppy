import SwiftUI
import AppKit
import Foundation

// `DefaultSessionKind` used to live here. It moved to
// `Shared/DefaultSessionKind.swift` so `Shared/TriggerRule.swift` and the
// agent's evidence loop can both see it — see that file's comment. What
// remains below is app-UI-only formatting with an AppKit (`NSWorkspace`)
// dependency, which must NOT move into `Shared/`: `Shared/` compiles into
// the daemon and CLI, and neither may gain an AppKit dependency.

func remainingTimeText(for session: Session, now: Date) -> String {
    switch session.kind {
    case .indefinite:
        return "Indefinite"
    case .duration(let until), .untilTime(let until), .lease(let until):
        let seconds = max(0, until.timeIntervalSince(now))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        return "\(minutes)m left"
    case .whileAppRunning(let bundleID):
        let name = appDisplayName(bundleID: bundleID)
        return "While \(name) is running"
    case .whileExternalDisplay:
        return "While an external display is connected"
    case .whileOnACPower:
        return "While on AC power"
    case .whileCPUBusy(let threshold):
        // The threshold is named because it is now the user's to pick
        // (`keepy-uppy on --while-cpu-busy 30`). "While the CPU is busy" was
        // written when nothing could choose one, and it renders two sessions
        // with different thresholds as the same row, in the one surface whose
        // job is to say why this Mac is awake.
        //
        // A percentage rather than the stored fraction, matching what was typed
        // — `Int` interpolation carries no locale, so there is no separator to
        // vary. Rounded rather than truncated so a threshold that arrived from
        // somewhere other than the CLI still reads as the nearest whole
        // percentage rather than one below it.
        return "While the CPU is at least \(Int((threshold * 100).rounded()))% busy"
    case .whileProcessRunning(let processName):
        return "While \(processName) is running"
    case .whileOnSchedule(let schedule):
        // The window rather than a countdown, deliberately. This row answers
        // "why is this Mac awake", and "Weekdays, 9:00 am to 6:00 pm" answers
        // it; "3h 12m left" would be true but would read as a timer somebody
        // set today, which is the one thing a standing rule is not.
        return "During \(schedule.describe())"
    case .whileVolumeMounted(let name):
        return "While \(name) is mounted"
    case .whileOnSubnet(let cidr):
        return "While on \(cidr)"
    case .whileVPNActive:
        return "While a VPN is connected"
    case .whileUSBDevicePresent(let vendorID, let productID):
        return "While \(usbDeviceDisplayName(vendorID: vendorID, productID: productID)) is attached"
    }
}

/// **Currently unreachable from the app.** Nothing outside the tests calls
/// this: the menu rebuild replaced the row it used to render
/// ("Indefinite — Started manually — Stop") with `menuStopLabel`, and the
/// automatic case is served by `menuAutomaticSuffix` below — which no longer
/// has a reachability problem of its own, but says the same words as a clause
/// rather than as a sentence, so this is not the function that grew a caller.
/// Kept, not deleted, on the same terms as before: something that renders an
/// origin as a standalone sentence is expected to want exactly this string, and
/// the note is here so a reader does not take its existence as evidence that
/// anything shows it today.
func originText(for session: Session) -> String {
    session.origin == .trigger ? "Started automatically" : "Started manually"
}

/// Best-effort friendly name for a bundle id, falling back to the id
/// itself when the app isn't installed/discoverable — this is display
/// text only, never used for matching logic.
func appDisplayName(bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let bundle = Bundle(url: url),
          let name = bundle.infoDictionary?["CFBundleName"] as? String
    else { return bundleID }
    return name
}

/// Best-effort friendly name for a USB device, falling back to
/// `0x05ac:0x024f` when it isn't plugged in or doesn't report one — the exact
/// bargain `appDisplayName(bundleID:)` makes for an app that isn't installed.
/// Display text only, never used for matching.
///
/// **The fallback is the common case, not the exception**, and that is what
/// makes it worth having: the whole point of a `.usbDevicePresent` rule is a
/// device that is *not* attached yet, so the Triggers list spends most of its
/// life rendering rules for absent devices. A row reading "0x05ac:0x024f" is
/// terse but honest and stays stable; a row reading "Unknown device" would tell
/// the user nothing about which rule they were looking at.
///
/// Enumerates on every call, as `appDisplayName` does its Launch Services
/// lookup — a full USB pass is 0.009 ms measured, so a menu rebuild does not
/// notice it.
func usbDeviceDisplayName(vendorID: UInt16, productID: UInt16) -> String {
    let wanted = USBDeviceID(vendorID: vendorID, productID: productID)
    guard case .attached(let devices) = IOKitUSBDeviceReader().read(),
          let name = devices.first(where: { $0.id == wanted })?.name
    else { return wanted.text }
    return name
}

// MARK: - Trigger rows

/// The picker row in the Add sheet — the *kind* on its own, before anything has
/// been typed into it.
///
/// These strings used to be the raw values of a parallel enum,
/// `AddTriggerSheet.ConditionKind` — the same arrangement as the one that left
/// three `SessionKind` cases unreachable from every client. (That was
/// `CLICommand.OnOption` and `DefaultSessionKind`, a different pair of lists
/// entirely; this picker never caused it. The resemblance is the point, not a
/// shared history.) They are here
/// instead for the reason `wakeModeSettingsTitle` is: user-facing copy belongs
/// on this side of the boundary, and a raw value is a wire name that `Shared/`
/// compiles into the daemon and the CLI, neither of which should carry Settings
/// prose. The picker now loops `TriggerConditionKind.allCases`, so a new
/// condition appears in it automatically and fails to compile *here* until
/// somebody writes its label.
func triggerConditionKindLabel(_ kind: TriggerConditionKind) -> String {
    switch kind {
    case .appLaunched: return "An app launches"
    case .externalDisplayConnected: return "An external display connects"
    case .acPowerConnected: return "Power is connected"
    case .processRunning: return "A process is running"
    case .appFrontmost: return "An app comes to the front"
    case .volumeMounted: return "A volume is mounted"
    case .onSubnet: return "This Mac is on a network"
    case .vpnActive: return "A VPN is connected"
    case .usbDevicePresent: return "A USB device is attached"
    case .onSchedule: return "A time of day comes round"
    }
}

/// The one thing this condition cannot see, said in the sheet where the rule is
/// being written rather than in a document nobody reads.
///
/// The observer identifies a VPN by asking macOS which of its **network
/// services** is a VPN — which is every VPN the system knows about, including
/// every NetworkExtension client and anything set up in System Settings. A
/// tunnel brought up by a command-line tool that never registers a service
/// (`wg-quick`, a bare `openvpn`, Tunnelblick) leaves nothing behind but a
/// `utun` interface, and matching on those is what makes the condition
/// permanently true on every Mac — see `VPNObserving`.
///
/// A stated limitation is fine; a silent one is not, and this is the silent
/// version's exact cost: a rule that looks correct, is correct, and never
/// fires, with nothing anywhere to say why.
/// What the network condition says to somebody who came here looking for a
/// Wi-Fi trigger — which is most of the people who will ever pick this row.
///
/// A Wi-Fi SSID condition was specified alongside this one and was **cut**. Two
/// measurements did it, both recorded in
/// `.superpowers/sdd/plan5-wifi-research.md`: an unauthorized
/// `CWInterface.ssid()` returns `nil` on a Mac that is demonstrably associated,
/// which is the same answer as "not on Wi-Fi at all"; and
/// `CLLocationManager`'s header states that an authorization request from
/// something that is not in use "will do nothing", which is precisely the
/// UI-less agent that would have to read it. See `NetworkAddressObserving`.
///
/// So this row *is* the Wi-Fi trigger, and nothing in the sheet says so. The
/// field wants `192.168.1.0/24`; the user is thinking "the office Wi-Fi". This
/// is the same failure `vpnDetectionLimitationNote` exists to prevent — a rule
/// that looks correct with an unstated limitation — and it gets the same
/// treatment, in the same place, at the moment the rule is being written.
///
/// It names Location Services, which nothing else in this app does. That is
/// deliberate and is not a nag: this sentence is the reason the app never has
/// to ask, and without it "why can't it just use the network's name?" has no
/// answer anywhere in the product.
///
/// The claim is scoped to Location Services rather than to permissions in
/// general, and that is not hedging. The app *does* ask for one thing — the
/// Login Items approval both background services need
/// (`backgroundServicesFootnote`) — so a flat "Keepy Uppy asks for no
/// permissions" would be contradicted by a sentence in the same Settings
/// window.
///
/// The last clause is not consolation. A `/24` matches the Mac's address on
/// that network however it got there, so a laptop that arrives on Wi-Fi and is
/// later docked to Ethernet keeps its session — which an SSID rule would have
/// dropped at the moment of docking, silently.
let subnetCoversWiFiNote = "This is how you name a Wi-Fi network here. Networks are matched by address block rather than by name, because macOS only reveals a Wi-Fi network's name to apps you've granted Location Services access, and Keepy Uppy never asks for that. Use “This Mac…” while you're on the network you want. A block also matches Ethernet on that same network, which a network name never could."

let vpnDetectionLimitationNote = "Detects VPNs macOS knows about — anything you set up in System Settings, and apps like Tailscale, Cloudflare WARP or your work VPN client. A tunnel started from the command line (wg-quick, openvpn, Tunnelblick) isn't visible to macOS as a VPN and won't be detected."

/// **A trigger starts a session; it does not bind that session's lifetime to
/// the condition** — unless `TriggerCondition.boundSessionKind` says it does.
/// `EvidenceLoopRunner` starts `rule.defaultKind`'s kind — `.indefinite`,
/// `.duration(...)` — and `sessionsToEnd` explicitly skips exactly those kinds,
/// so nothing ends the session when the condition stops being true. Wording that
/// implies otherwise ("while it's running") promises a stop that will never
/// come: plug a display in, unplug it, and an indefinite session keeps the Mac
/// awake forever. Every string here is phrased as the *starting event* for that
/// reason — except for a condition that binds, where "while" is the literal
/// truth, because `sessionKind(firing:now:)` starts the bound kind and
/// `sessionsToEnd` really does end it.
///
/// `.processRunning`, `.volumeMounted`, `.onSubnet`, `.vpnActive` and
/// `.usbDevicePresent` are the five such conditions today.
/// Which ones say "while" is pinned against `bindsSessionLifetime` in
/// `SessionDisplayTests`, not against a list of case names, so a ninth
/// condition cannot pick the wrong voice quietly.
///
/// **This is now the voice a rule gets when it has no stored effect**, which is
/// what keeps every assertion above true unchanged. A rule that chose the other
/// lifetime gets `triggerRuleTitle` below, which reads the same two tables in
/// the other order — because the failure this comment describes is symmetric.
/// "While Backup is mounted" over a rule that will actually run for four hours
/// is the identical broken promise, just written by a user instead of by a
/// developer.
func triggerConditionTitle(_ condition: TriggerCondition) -> String {
    if TriggerEffect.defaultLifetime(for: condition.kind) == .whileConditionHolds,
       let bound = triggerWhileTitle(condition) { return bound }
    return triggerStartEventTitle(condition)
}

/// The first line of a trigger row, in the voice the *rule* earns.
///
/// `triggerConditionTitle` answers for a condition alone, which is all the Add
/// sheet's picker has; this answers for a saved rule, which is the only thing
/// the list shows.
func triggerRuleTitle(_ rule: TriggerRule) -> String {
    if rule.effect.lifetime == .whileConditionHolds,
       let bound = triggerWhileTitle(rule.condition) { return bound }
    return triggerStartEventTitle(rule.condition)
}

/// Every condition as the *event* that starts a session — the voice for a rule
/// that runs for a duration and then stops regardless of the condition.
///
/// Exhaustive, so a tenth condition must be given both voices rather than
/// silently inheriting one.
func triggerStartEventTitle(_ condition: TriggerCondition) -> String {
    switch condition {
    case .appLaunched(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) launches"
    case .externalDisplayConnected: return "When an external display connects"
    case .acPowerConnected: return "When power is connected"
    case .processRunning(let processName): return "When \(processName) starts running"
    case .appFrontmost(let bundleID): return "When \(appDisplayName(bundleID: bundleID)) comes to the front"
    case .volumeMounted(let name): return "When \(name) is mounted"
    case .onSubnet(let cidr): return "When this Mac joins \(cidr)"
    case .vpnActive: return "When a VPN connects"
    case .usbDevicePresent(let vendorID, let productID):
        return "When \(usbDeviceDisplayName(vendorID: vendorID, productID: productID)) is attached"
    case .onSchedule(let schedule):
        return "When \(schedule.describe()) comes round"
    }
}

/// Every condition as an ongoing *state* — the voice for a rule whose session
/// really does end when the condition does — or `nil` where that lifetime is not
/// offered at all.
///
/// `nil` for exactly `.appFrontmost`, and the reason is
/// `TriggerCondition.candidateBoundSessionKind`'s: a session bound to what is in
/// front ends after an eleven-second glance at a browser. `SessionDisplayTests`
/// pins this against that table over `allCases`, so a condition that can bind
/// cannot end up with no way to say so.
func triggerWhileTitle(_ condition: TriggerCondition) -> String? {
    switch condition {
    case .appLaunched(let bundleID): return "While \(appDisplayName(bundleID: bundleID)) is running"
    case .externalDisplayConnected: return "While an external display is connected"
    case .acPowerConnected: return "While power is connected"
    case .appFrontmost: return nil
    case .processRunning(let processName): return "While \(processName) is running"
    case .volumeMounted(let name): return "While \(name) is mounted"
    case .onSubnet(let cidr): return "While this Mac is on \(cidr)"
    case .vpnActive: return "While a VPN is connected"
    case .usbDevicePresent(let vendorID, let productID):
        return "While \(usbDeviceDisplayName(vendorID: vendorID, productID: productID)) is attached"
    case .onSchedule(let schedule):
        // "While" rather than the more natural "During", because the row's
        // voice is load-bearing here: `testOnlyABindingConditionsTitleMaySayWhile`
        // reads this word to check the copy agrees with
        // `bindsSessionLifetime`. A condition that binds a lifetime and does
        // not say so is the drift that test exists to catch.
        return "While it's \(schedule.describe())"
    }
}

/// The second line of a trigger row: what starting it actually does.
///
/// A rule bound to its condition gets `triggerBoundEffectSubtitle` instead of the
/// duration phrase — `defaultKind` is stored on such a rule but ignored when it
/// fires, so describing it here would be describing a duration that will never
/// take effect.
///
/// The branch is keyed off the **rule's own lifetime**, not off the condition's
/// default, which is the whole of what Plan 8 Task 10 changed here: the same
/// condition now reads as timed under one rule and as bound under another, and
/// this row is where a user would first notice if it did not.
func triggerEffectSubtitle(_ rule: TriggerRule) -> String {
    if rule.effect.lifetime == .whileConditionHolds,
       let bound = triggerBoundEffectSubtitle(rule.condition) { return bound }
    return "Starts a session that keeps this Mac awake \(rule.defaultKind.durationPhrase)"
}

/// What a bound rule's row says instead of a duration, or `nil` for a condition
/// no rule may bind to.
///
/// Exhaustive, so a new condition must decide; and `SessionDisplayTests` pins
/// which branch it lands in against `candidateBoundSessionKind`, so "can bind but
/// has no sentence for it" is a test failure rather than a row that quietly
/// misdescribes what the daemon will do.
func triggerBoundEffectSubtitle(_ condition: TriggerCondition) -> String? {
    switch condition {
    case .appFrontmost:
        return nil
    case .appLaunched(let bundleID):
        return "Keeps this Mac awake until \(appDisplayName(bundleID: bundleID)) quits"
    case .externalDisplayConnected:
        return "Keeps this Mac awake until the display is disconnected"
    case .acPowerConnected:
        return "Keeps this Mac awake until power is disconnected"
    case .processRunning(let processName):
        return "Keeps this Mac awake until \(processName) exits"
    case .volumeMounted(let name):
        return "Keeps this Mac awake until \(name) is unmounted"
    case .onSubnet(let cidr):
        return "Keeps this Mac awake until it leaves \(cidr)"
    case .vpnActive:
        return "Keeps this Mac awake until the VPN disconnects"
    case .usbDevicePresent(let vendorID, let productID):
        return "Keeps this Mac awake until \(usbDeviceDisplayName(vendorID: vendorID, productID: productID)) is unplugged"
    case .onSchedule(let schedule):
        return "Keeps this Mac awake until \(schedule.describe()) ends"
    }
}

/// What the Add sheet says under the lifetime choice, once "while it lasts" is
/// the choice: there is no duration to pick, and a picker that was shown and
/// then discarded is worse than one that isn't there. This is the sentence that
/// goes where it would have been, so its absence is explained rather than merely
/// noticed.
///
/// **"— no duration to pick" is still exactly true**, and it is worth saying why,
/// because Plan 8 Task 10 turned the surrounding UI from "you have no choice"
/// into "you have a choice and this is it". The sentence describes the selection
/// the user is looking at, not the sheet: with "while it lasts" chosen there is
/// genuinely nothing to pick, and the duration picker is genuinely not shown.
/// Picking the other option brings it back.
///
/// Distinct from `triggerBoundEffectSubtitle` because it is read while the sheet
/// is still being filled in — the process name is typically empty — where the row
/// subtitle only ever describes a saved rule.
func triggerBindingFootnote(_ condition: TriggerCondition) -> String? {
    switch condition {
    case .appFrontmost:
        return nil
    case .appLaunched(let bundleID):
        // Empty is the ordinary state of this field while the sheet is open,
        // exactly as it is for the four below.
        let subject = bundleID.isEmpty ? "the app" : appDisplayName(bundleID: bundleID)
        return "Ends automatically when \(subject) quits — no duration to pick."
    case .externalDisplayConnected:
        return "Ends automatically when the display is disconnected — no duration to pick."
    case .acPowerConnected:
        return "Ends automatically when power is disconnected — no duration to pick."
    case .processRunning(let processName):
        let subject = processName.isEmpty ? "the process" : processName
        return "Ends automatically when \(subject) exits — no duration to pick."
    case .volumeMounted(let name):
        let subject = name.isEmpty ? "the volume" : name
        return "Ends automatically when \(subject) is unmounted — no duration to pick."
    case .onSubnet(let cidr):
        let subject = cidr.isEmpty ? "that network" : cidr
        return "Ends automatically when this Mac leaves \(subject) — no duration to pick."
    case .vpnActive:
        // No associated value, so nothing to fill in and no empty-field
        // variant: the sentence is the same before and after saving.
        return "Ends automatically when the VPN disconnects — no duration to pick."
    case .usbDevicePresent:
        // Deliberately unnamed, unlike the row subtitle above. This is read
        // while the sheet is still being filled in, and the value at that point
        // is whatever half-typed hex is in the field — which would render as
        // `0x0000:0x0000` before anything is chosen. "The device" is true at
        // every moment the sheet is open.
        return "Ends automatically when the device is unplugged — no duration to pick."
    case .onSchedule:
        // Unnamed for `.usbDevicePresent`'s reason: read while the sheet is
        // still being filled in, where the window may not yet have a day ticked
        // and would otherwise render as a schedule that can never fire.
        return "Ends automatically when the window closes — no duration to pick."
    }
}

// MARK: - The Add sheet's two new choices
//
// The sheet is a SwiftUI `body` and is not testable, so every string and every
// enablement predicate it reads lives here — the boundary this project already
// holds for `AddTriggerSheet.pickerError`, `InputField` and `subnetProblem`.

/// Whether the Add sheet offers the lifetime choice at all.
///
/// Keyed off `TriggerCondition.candidateBoundSessionKind` — the one table that
/// answers "could a rule on this condition bind to it?" — rather than off a
/// second list of case names. `.appFrontmost` is the only condition that answers
/// no, and offering it there would be offering a session that ends when you look
/// at another window.
func triggerLifetimeChoiceIsOffered(_ condition: TriggerCondition) -> Bool {
    condition.candidateBoundSessionKind != nil
}

/// Whether the Add sheet shows the duration picker.
///
/// It is not `!triggerLifetimeChoiceIsOffered(...)` and it is not
/// `chosen == .forDuration` either: it is what the rule will *actually* store,
/// via `TriggerEffect.chosen`, so the picker cannot be hidden for a rule that
/// will end up running for a duration anyway. That is the one way the two
/// controls could disagree, and it is the way that leaves a user with a duration
/// they never picked.
func triggerDurationPickerIsShown(chosen lifetime: TriggerLifetime,
                                  for condition: TriggerCondition) -> Bool {
    TriggerEffect.chosen(power: TriggerEffect.defaultPower, lifetime: lifetime,
                         for: condition).lifetime == .forDuration
}

/// The lifetime picker's own label.
let triggerLifetimeTitle = "Keep awake"

/// The lifetime picker's two rows. Deliberately short and condition-free: the
/// sentence naming what actually ends the session is `triggerBindingFootnote`,
/// directly beneath, and repeating the condition in the row label would be a
/// second set of words for the same fact.
func triggerLifetimeOptionLabel(_ lifetime: TriggerLifetime) -> String {
    switch lifetime {
    case .whileConditionHolds: return "While it lasts"
    case .forDuration: return "For a set time"
    }
}

/// The duration picker's label in the Add sheet.
///
/// It used to be "Keep awake", which `triggerLifetimeTitle` now carries — two
/// pickers stacked under one label is how a user comes to believe one of them
/// does nothing.
let triggerDurationTitle = "For how long"

/// The third line of a trigger row: what this rule asks of the machine, when
/// that is not what every trigger used to ask. `nil` for the default request, so
/// a list of ordinary rules gains no noise.
///
/// It reuses `wakeModeSettingsTitle` and `keepDisksAwakeSettingsTitle` rather
/// than describing the same three modes and the same toggle a second time. A
/// second set of words for one setting is how the Settings pane and this list
/// come to describe them differently.
func triggerPowerNote(_ power: PowerRequest) -> String? {
    guard power != TriggerEffect.defaultPower else { return nil }
    var parts: [String] = []
    if power.wakeMode != TriggerEffect.defaultPower.wakeMode {
        parts.append(wakeModeSettingsTitle(power.wakeMode))
    }
    if power.keepsDisksAwake { parts.append(keepDisksAwakeSettingsTitle) }
    // Unreachable-empty by construction: the guard above already established
    // that at least one axis differs from the default, and the default is
    // `.clamshell` with disks free, so at least one branch fires.
    return parts.joined(separator: " · ")
}

/// What the Triggers pane says when the store holds rules this build cannot
/// decode, or `nil` when it holds none.
///
/// `TriggerStore` keeps such a rule and writes it back untouched, so nothing is
/// lost — but it cannot be shown in the list, cannot be edited, and will not
/// fire while this build is the one running. Without this line the user sees a
/// pane that is missing a trigger they wrote, or, if every rule they have came
/// from the newer build, the "No Triggers" empty state telling them they have
/// none. Preserving the rule silently would fix the data loss and leave the
/// alarming part intact.
///
/// It says *kept* explicitly. The obvious reading of a missing trigger is that
/// something deleted it, and the second-obvious response is to recreate it —
/// which on the older build means writing a duplicate that the newer one will
/// then show twice.
func unreadableTriggerNotice(count: Int) -> String? {
    guard count > 0 else { return nil }
    if count == 1 {
        return "1 trigger was created by a newer version of Keepy Uppy. It can't be shown here and won't run on this version, but it has been kept — no need to recreate it."
    }
    return "\(count) triggers were created by a newer version of Keepy Uppy. They can't be shown here and won't run on this version, but they have been kept — no need to recreate them."
}

extension DefaultSessionKind {
    /// Reads as a continuation of a sentence, which `label` ("Indefinitely",
    /// "For 1 Hour") does not once dropped mid-phrase.
    var durationPhrase: String {
        switch self {
        case .indefinite: return "indefinitely"
        case .oneHour: return "for 1 hour"
        case .fourHours: return "for 4 hours"
        case .eightHours: return "for 8 hours"
        }
    }
}

// MARK: - Safety pane copy

func thermalSensitivityTitle(_ level: ThermalSensitivity) -> String {
    switch level {
    case .off: return "Never stop"
    case .cautious: return "Cautious"
    case .balanced: return "Balanced"
    case .permissive: return "Permissive"
    }
}

/// Written in terms of what the user will observe. The underlying levels
/// ("fair", "serious") are `SafetyEngine` jargon and mean nothing outside it.
func thermalSensitivityExplanation(_ level: ThermalSensitivity) -> String {
    switch level {
    case .off:
        return "Sessions keep running no matter how hot this Mac gets. Nothing here will stop them."
    case .cautious:
        return "Stops sessions as soon as this Mac gets warm and the fans pick up. Safest with the lid closed, and the most likely to interrupt a long build."
    case .balanced:
        return "Stops sessions once this Mac is genuinely throttling — hot enough that work has already slowed down. Recommended."
    case .permissive:
        return "Stops sessions only at critical temperature. Lets this Mac run hot for as long as it can before giving up."
    }
}

/// Reads the effective thresholds off `SafetyConfig` rather than restating
/// them, so the pane cannot drift from the engine that enforces them.
func batteryGuardFootnote(_ config: SafetyConfig) -> String {
    guard let open = config.effectiveBatteryCutoff(lidClosed: false) else {
        return "The battery guard is off. Sessions keep running on battery however low it gets."
    }
    let closed = config.effectiveBatteryCutoff(lidClosed: true) ?? open
    guard closed != open else {
        return "On battery, sessions stop at \(open)% so this Mac doesn't run flat while you're away."
    }
    return "On battery, sessions stop at \(open)% — or \(closed)% with the lid closed, where this Mac can't cool itself as well."
}

/// Says "on battery" because the number alone reads as wall clock, which is
/// what this backstop used to measure and no longer does. A user who reads "8
/// hours" beside a stepper and then watches a mains-powered session run for
/// three days has been told something false by a label that was only terse.
func maxSessionLengthLabel(_ config: SafetyConfig) -> String {
    let hours = Int((config.maxSessionDuration ?? 0) / 3600)
    return hours == 1 ? "1 hour on battery" : "\(hours) hours on battery"
}

// MARK: - Background service status

func serviceStatusTitle(_ state: OnboardingService.State) -> String {
    switch state {
    case .running: return "Running"
    case .needsApproval: return "Waiting for approval"
    case .notEnabled: return "Not enabled"
    }
}

/// Shape as well as colour: colour alone would carry the whole meaning for a
/// reader who can't distinguish green from orange.
func serviceStatusSymbol(_ state: OnboardingService.State) -> String {
    switch state {
    case .running: return "checkmark.circle.fill"
    case .needsApproval: return "exclamationmark.triangle.fill"
    case .notEnabled: return "xmark.circle.fill"
    }
}

func serviceStatusTint(_ state: OnboardingService.State) -> Color {
    switch state {
    case .running: return .green
    case .needsApproval: return .orange
    case .notEnabled: return .secondary
    }
}

/// Why this app wants a root daemon, said before it asks rather than after.
///
/// **This is the paragraph that decides whether a stranger installs this.** The
/// README makes the argument at length and nobody reads a README at the moment
/// they are being asked for an administrator password; "a new app wants root"
/// with no reason attached is a reasonable thing to refuse. So the reason is
/// here, on the pane with the button, and it is specific: what needs the
/// privilege, what does not get it, and what happens when the app goes away.
///
/// Returned as a string from a pure function, like every other line of copy in
/// this file, so it is greppable and testable rather than buried in a `body`.
func privilegeBoundaryExplanation() -> String {
    "Staying awake with the lid shut means changing a system-level power setting, "
    + "and macOS only lets a root process do that. Keepy Uppy installs one small "
    + "daemon for it — and nothing else runs with those privileges. The menu bar "
    + "app, the command line and the trigger watcher all run as you and ask the "
    + "daemon over XPC, each on its own connection that admits exactly one signed "
    + "bundle, so nothing else on this Mac can borrow it. The daemon forces sleep "
    + "back on at startup and if you delete the app, so uninstalling cannot leave "
    + "this Mac unable to sleep."
}

func backgroundServicesFootnote(_ state: OnboardingService.State) -> String {
    switch state {
    case .running:
        // Both are always-on by design: the agent's plist sets RunAtLoad and
        // KeepAlive, and the daemon has no idle exit. Claiming they "stop when
        // no session is running" (as this footer briefly did) is simply false,
        // and misdescribes two processes a user may be deciding whether to
        // trust.
        return "These stay running in the background so a trigger can start a session while you're away. Sleep is only held off while a session is actually active."
    case .needsApproval:
        return "macOS needs you to approve these in System Settings → General → Login Items & Extensions before they can run."
    case .notEnabled:
        return "Keepy Uppy can't keep this Mac awake until these are enabled."
    }
}

// MARK: - Notifications

/// The three toggles in General → Notifications.
///
/// The stop toggle is **scoped to the user's own sessions**, and that is not
/// pedantry: `listSessions` is unfiltered and a Mac can have more than one
/// person logged in, so "when this Mac stops being kept awake" is a claim about
/// the machine that this event cannot make — another account's session may be
/// holding it awake at the exact moment yours ends. The same union-sensitivity
/// argument as `menuLidCaveat`, and the label is worded so that it matches the
/// banner it switches on (`sessionNotificationCopy(for: .stoppedBeingKeptAwake)`)
/// rather than promising something wider than the banner delivers.
let notifyWhenStoppedTitle = "When nothing of yours is keeping this Mac awake"

let notifyWhenTriggerStartsTitle = "When a trigger starts a session"

/// The safety-stop toggle, and its footnote.
///
/// The pair exists because this control has to promise **exactly** what the
/// mechanism delivers and not a word more, and that takes two sentences. The
/// title says what it adds — which guard — and the footnote says the thing a
/// title cannot: that a reason is not always available.
///
/// Saying so is not a disclaimer, it is the feature's own honesty rule surfaced
/// where a user forms their expectation. There are three ways the reason can be
/// missing (a daemon too old to be asked, a record that aged out, and an ending
/// no guard was behind), all three end on the plain "your last session has
/// ended" sentence, and a user who was promised a reason every time would read
/// that plain banner as the app having *lost* one.
///
/// It also says which toggle covers the rest, because "sometimes you get the
/// other notification instead" is only actionable if you know that the other
/// notification has its own switch directly above.
let notifyWhenSafetyGuardStopsTitle = "When a safety guard stops your sessions"

let notifyWhenSafetyGuardStopsFootnote = "Names the guard that stopped them — too hot, low battery, or the time limit. A reason isn't always available: an older background service can't be asked for one, and neither can an ending no guard was behind. When there isn't one you get the plain notice above instead, if that one is switched on."

/// What the grant is, in one sentence per state.
///
/// Written over `NotificationAuthorization`, which is this project's own enum
/// precisely so that this can be an exhaustive `switch` — see that type for why
/// `.ephemeral` is absent (it is `API_UNAVAILABLE(macos)`) and `.unknown` is
/// present. A state without a sentence is a blank line under a toggle.
///
/// Each sentence names **the action that fixes it**, and the actions genuinely
/// differ: "you have not been asked" is fixed by the toggle in this very pane,
/// while "you said no" is fixed in System Settings and nowhere else. Copy that
/// treated the two as one would send half its readers to a pane with nothing to
/// change.
func notificationAuthorizationSentence(_ state: NotificationAuthorization) -> String {
    switch state {
    case .notDetermined:
        return "macOS hasn't been asked whether Keepy Uppy may notify you. Switching one of these on is what asks, and it only happens once."
    case .denied:
        return "macOS is blocking Keepy Uppy's notifications, so nothing will appear until you allow them in System Settings → Notifications."
    case .authorized:
        return "macOS is letting Keepy Uppy notify you."
    case .provisional:
        return "Keepy Uppy's notifications are being delivered quietly: they go straight to Notification Center, with no banner. You can change that in System Settings → Notifications."
    case .unknown:
        // Not a hypothetical to be shrugged at: `@unknown default` in
        // `NotificationAuthorization.init(_:)` is where a status added by a
        // future macOS lands, and the alternative to this sentence is a toggle
        // that is on with nothing beneath it.
        return "macOS reported a notification setting this version of Keepy Uppy doesn't recognise, so it can't say whether these will appear. Check Keepy Uppy in System Settings → Notifications."
    }
}

/// A sentence, and whether to offer the button beside it.
///
/// One value rather than two functions, on `CLIInstallPrompt`'s precedent: the
/// two decisions travel together, and a caller cannot take the sentence and
/// forget the affordance or offer the affordance without the sentence.
struct NotificationStatusNote: Equatable {
    let sentence: String
    /// `false` where System Settings is not where the fix is — offering to open
    /// a pane that has nothing to change on it is worse than offering nothing.
    let offersSystemSettings: Bool
}

/// What the pane says beneath the toggles, or `nil` when it should say nothing.
///
/// **`nil` while both toggles are off**, whatever the grant is. A user who has
/// not asked for notifications does not have a problem, and a pane that reports
/// one anyway is a nag — the difference between "degrade honestly" and "ask
/// again". `nil` when the grant is working, too: the toggle being on is already
/// the report.
///
/// Everything else is reported. That is the "on but doing nothing" failure
/// Plan 5 designed this affordance for, in the one place this project still has
/// a grant that can be refused: a toggle switched on, a banner that never
/// arrives, and nothing anywhere to say why.
func notificationStatusNote(state: NotificationAuthorization,
                            anyToggleOn: Bool) -> NotificationStatusNote? {
    guard anyToggleOn else { return nil }
    switch state {
    case .authorized:
        return nil
    case .notDetermined:
        // The fix is the toggle that was just switched on — the request either
        // has not completed or did not happen. System Settings may not even
        // have a Keepy Uppy row yet, since one appears when an app first asks.
        return NotificationStatusNote(sentence: notificationAuthorizationSentence(state),
                                      offersSystemSettings: false)
    case .denied, .provisional, .unknown:
        return NotificationStatusNote(sentence: notificationAuthorizationSentence(state),
                                      offersSystemSettings: true)
    }
}

/// The Notifications pane of System Settings.
///
/// **Verified on this machine rather than remembered.** `/System/Library/
/// ExtensionKit/Extensions/NotificationsSettings.appex`'s `Info.plist` carries
/// `CFBundleIdentifier = com.apple.Notifications-Settings.extension` and
/// `allowsXAppleSystemPreferencesURLScheme = true`, on macOS 26.2 (25C56) — so
/// the pane exists under exactly this identifier and opts in to this scheme. A
/// deep link that lands on the wrong pane is worse than a sentence telling the
/// user where to go, which is why this was checked before it shipped.
let notificationSettingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

/// **The two limitations, said once each, where the choice is made.**
///
/// 1. *Nothing is announced while Keepy Uppy is not running.* The app is the
///    notifier — it has the UI that can ask for the grant, the run loop that
///    can present, and a lifetime the user already understands — and none of
///    those is true of the UI-less LaunchAgent. So a `keepy-uppy` session that
///    ends overnight with the menu bar app quit produces no banner. That is the
///    honest trade rather than a defect: the alternative is a background agent
///    asking for a grant as a second, separately-refusable notification client.
///
/// 2. *Stopping a session yourself here is not announced, and stopping one from
///    a Terminal is.* The first is Plan 7 Task 6's suppression, without which
///    the commonest banner in the product would be the app explaining a click
///    back to the person who made it. The second follows from what the app
///    cannot see: a `keepy-uppy off` is indistinguishable from an expiry or a
///    condition ending.
///
///    **"or a safety guard ending it" used to be in that list and has been
///    removed**, because Plan 8 Task 6 made it false: a guard's stop is the one
///    ending the daemon now records a reason for, and the toggle below can name
///    it. Leaving the phrase in would have been this pane telling a user that
///    the control immediately beneath it cannot do what it says.
let notificationsSectionFootnote = "Keepy Uppy has to be running to tell you anything — a session that ends while the menu bar app is quit ends without a word. Stopping a session yourself in this menu is never announced, but stopping one with keepy-uppy off in a Terminal is: from here that looks the same as a session expiring or a condition ending."

/// Half of a **two-way** signpost. The three ways of being told a session ended
/// are split across two tabs, and an unsignposted split is how somebody
/// concludes a feature was removed. `sessionEndActionsNotificationsSignpost` is
/// the other half, and it exists because one-directional signposting only helps
/// the reader who happened to start on the right tab.
let notificationsTriggersSignpost = "To run a script or POST to a webhook when a session ends instead, see Settings → Triggers, under On Session End."

/// The Triggers tab's "On Session End" footer, moved here from
/// `TriggersSettingsTab` so that it is testable beside the line that now points
/// at it. The words are unchanged.
let sessionEndActionsFootnote = "Runs the script and/or POSTs to the webhook whenever any keep-awake session ends — manual, timed, trigger-started, or stopped by a safety guard."

/// The other half of the two-way signpost. See `notificationsTriggersSignpost`.
let sessionEndActionsNotificationsSignpost = "To be told on screen instead, see Settings → General, under Notifications."

// MARK: - Menu bar

/// The menu's first line: what is happening, in one glance, with no jargon.
///
/// It is a *label*, never a button. The previous menu made each session row
/// itself the stop button, with the verb buried at the end of
/// "Indefinite — Started manually — Stop" — so the one interactive thing in
/// the list read as a status line, and the two facts in front of the verb were
/// noise. Status and action are separate things now.
///
/// ## What "yours" counts, and the answer to the question Task 4 deferred
///
/// The rows with a Stop button. The parameter was `mine:` and counted
/// `app-<uid>` sessions alone; Plan 7 Task 3 asked whether it should mean
/// "belongs to your account" instead, and Plan 8 Task 4 asked again and left it
/// alone **explicitly deferring to this task**, on the grounds that the count
/// earns its meaning from the buttons directly beneath it and that the
/// authorization had to move first.
///
/// It has moved: `SessionIsolation.authorize` now lets the app stop this user's
/// own trigger-started sessions too, so those rows have buttons and this counts
/// them. The sentence is unchanged in *meaning* — "how many of these can I do
/// something about" — and it is the set underneath it that grew. It is still
/// not "belongs to your account": this user's `keepy-uppy on` session is theirs
/// and has no button, so counting it would put a number above a list where the
/// counted row cannot be acted on, which is the mismatch this rule exists to
/// avoid.
func menuStatusLine(yours: [Session], others: [Session], now: Date) -> String {
    let all = yours.count + others.count
    guard all > 0 else { return "Not keeping awake" }
    if all == 1, let only = (yours + others).first {
        return "Keeping awake — \(remainingTimeText(for: only, now: now).lowercased())"
    }
    if others.isEmpty { return "Keeping awake — \(all) sessions" }
    if yours.isEmpty { return "Keeping awake — \(all) sessions, none yours" }
    return "Keeping awake — \(all) sessions, \(yours.count) yours"
}

/// The menu's sweep row, named for **what it actually ends**.
///
/// It said "Stop all mine" while `.thisApp` was the only group with a Stop
/// button, so "mine" and "everything above me with a button" were the same set.
/// Plan 8 Task 5 separated them: this user's trigger sessions gained per-row
/// buttons and the status line above counts them as "yours", but the sweep is
/// still `stopAllSessions(all: false)`, which the daemon scopes to `app-<uid>`
/// (`SessionIsolation.sessionsToStop`, where the decision not to widen it is
/// argued). "Stop all mine" would therefore promise more than it delivers, in a
/// menu that now says "3 sessions, 3 yours" directly above it.
///
/// The wording deliberately matches `HotKeyAction.stopAppSessions`'s label
/// ("Stop sessions started from the menu"), because they end exactly the same
/// set and two names for one scope is how a user concludes one of them is
/// broken.
let menuStopAllLabel = "Stop all started from this menu"

/// Verb first, so the row is visibly a thing you can do. With exactly one
/// stoppable session there is nothing to disambiguate, so it says the plain
/// thing rather than quoting a description back at you.
///
/// The parameter was `isOnlyOneOfMine`, back when the stoppable set and "this
/// app's own sessions" were the same list. Plan 8 Task 5 separated them — this
/// user's trigger sessions are stoppable and are not this app's — and the
/// question the label actually asks is "is this the only row with a button",
/// which is what the caller now passes. Getting it wrong is not cosmetic in
/// either direction: "Stop keeping awake" above a second Stop row claims to end
/// something it will not.
///
/// The wake-mode tag is appended *here*, not composed by the view, for the
/// same structural reason `Session.renewed(until:)` lives next to the stored
/// properties: a row that has to remember to concatenate a suffix is a row
/// that will one day forget, and a forgotten mode tag is invisible — it looks
/// exactly like a lid-safe session. `menuAutomaticSuffix` stays separate
/// because it is genuinely optional trim; this is not.
///
/// The tagged single-session row names a **noun** — "Stop this session (lid
/// open only)", not "Stop keeping awake (lid open only)". A parenthetical after
/// a bare imperative attaches to the verb, so the latter can be read as "stop
/// only while the lid is open", which is a statement about the button rather
/// than about the session. The multi-session form below never had the problem,
/// because its parenthetical follows a quoted description. The untagged label
/// is left exactly as it was: it is the overwhelmingly common case, it has no
/// parenthetical to misparse, and "annotate the exception, not the rule" means
/// a user who never opens Settings sees the menu unchanged.
func menuStopLabel(for session: Session, isOnlyOneOfYours: Bool, now: Date) -> String {
    let tag = menuWakeModeSuffix(session.wakeMode)
    guard !isOnlyOneOfYours else {
        return (tag.isEmpty ? "Stop keeping awake" : "Stop this session") + tag
    }
    return "Stop “\(remainingTimeText(for: session, now: now).lowercased())”" + tag
}

/// Origin earns a mention only when it is surprising. "Started manually" on a
/// session you started by hand is noise; "started automatically" on one that
/// appeared by itself is the whole story.
///
/// **It fired for the first time in Plan 7 Task 3, and the reason it took three
/// plans is worth keeping.** It was written appended to `mine` alone — sessions
/// owned by `app-<uid>` — while the only thing that produces
/// `origin == .trigger` is the agent, and the daemon stamps `owner` from the
/// accepting listener's role, so a trigger session is owned by `agent-<uid>`
/// and landed in the other bucket, whose rows had no suffix at all. It was
/// called on every menu rebuild and returned `""` every time. An automatic
/// session read `Indefinite — started elsewhere`, character for character like
/// the CLI's or another user's.
///
/// `menuSessionGroup` is what closed that: the row for a session this user's
/// own trigger rule started is built from this function rather than from a
/// second copy of its three words. It is still belt-and-braces there — that
/// group is only ever reached with `origin == .trigger` — which is the point:
/// no row can claim a session was automatic while the session's own field says
/// otherwise.
///
/// It reads as a provenance clause rather than a parenthetical
/// (`" — started automatically"`, not `" (started automatically)"`) because
/// every row it now lands in has the shape `"<kind> — <provenance>"`; see
/// `MenuCopyTests.testTheAutomaticMentionIsShapedLikeEveryOtherProvenanceClause`
/// for the argument.
///
/// ## Why this asks `origin` alone, and is not a third copy of the rule
///
/// `Session.startedByTrigger(forUserID:)` is the one place the "this user's own
/// rule started it" conjunction is written, and this function deliberately does
/// **not** call it. It is a renderer, not a decision, and its two call sites
/// supply the ownership half in the two different ways that are correct for
/// them:
///
/// * `menuSessionLabel`'s `.yoursAutomatic` row has already been through
///   `menuSessionGroup`, so the whole conjunction holds before this is reached;
///   the `origin` check here is the belt-and-braces described above.
/// * `MenuContent`'s `mine` rows are `app-<uid>` — this app's own sessions, the
///   only ones it can stop. Corroborating `origin` there would be checking
///   whether we believe ourselves: the daemon's listener admits `app-<uid>` only
///   for a binary meeting `SigningRequirement`, so `origin` on such a session is
///   a genuine Keepy Uppy describing a session it started, not a claim by a
///   client that might be lying. Requiring `owner == agent-<uid>` there would
///   make the call provably constant-empty and delete the case
///   `DaemonConnection.startSession`'s `origin` parameter exists to allow.
///
/// The failure mode the conjunction defends against — a `cli-<uid>` session
/// asserting `.trigger` and being described as automatic — cannot reach either
/// call site, because `menuSessionGroup` sends it to `.yoursCommandLine`.
func menuAutomaticSuffix(for session: Session) -> String {
    session.origin == .trigger ? " — started automatically" : ""
}

/// Which row a live session gets in the menu, decided in exactly one place.
///
/// The menu used to ask one question — "is this session mine?" — and it got the
/// answer wrong for the only sessions nobody starts by hand. `owner` is
/// `<role>-<uid>` (`ClientRole.clientID(forUserID:)`), so a session started by a
/// trigger rule this user wrote is owned by `agent-<uid>`, failed an equality
/// test against `app-<uid>`, and rendered as "started elsewhere": the same row,
/// word for word, as a session belonging to another human being on a shared Mac.
///
/// **Two independent axes, so four combinations, so every one of them is
/// written out.** *Whose account* is `ownerUID`, which the daemon fills in from
/// the peer's audit credentials; *which client* is `owner`, which it stamps from
/// the listener that accepted the connection. Both are server-derived and
/// unforgeable — neither is asserted by the client (`ClientRole`'s doc comment;
/// `HelperService.startSession`). The combination nobody named is "this user's,
/// not this app's, and not a trigger", and it gets `.yoursOtherClient` rather
/// than falling into whichever branch happens to be last.
enum MenuSessionGroup: Equatable, CaseIterable {
    /// Started by this app, for this user. Stoppable by ownership — the rule
    /// that has always applied, and the one every other client is held to.
    ///
    /// It was "the only group with a stop button" until Plan 8 Task 5;
    /// `.yoursAutomatic` below is now the second, and the *only* second, for
    /// the reasons `SessionIsolation.authorize` sets out. It is also the only
    /// group `stopAllSessions(all: false)` sweeps, which is why the menu's
    /// sweep row names this set rather than claiming "all mine".
    case thisApp
    /// This user's, started by one of their own trigger rules.
    ///
    /// **The second group with a stop button, as of Plan 8 Task 5** (spec §4's
    /// one exception). Stoppable one row at a time, never by a sweep and never
    /// by the global hot key: ending a session a rule of yours started is a
    /// decision made about a session you can see.
    case yoursAutomatic
    /// This user's, started by `keepy-uppy` in a terminal.
    case yoursCommandLine
    /// This user's, from a client this build cannot name — a role added after
    /// it shipped, or a session whose `owner` and `ownerUID` disagree about
    /// which user they mean.
    ///
    /// **Unreachable today**, in the same sense `menuAutomaticSuffix` was for
    /// three plans: `ClientRole` has exactly three cases and the daemon derives
    /// both fields from one connection. It exists so that the reason a
    /// `cli-<uid>` session says "command line" is that its owner says `cli` —
    /// not that it was whatever was left over. A partition written as
    /// "app / trigger / else foreign / else command line" would tell the user
    /// that a future Shortcuts extension started their session from a terminal
    /// they never opened.
    case yoursOtherClient
    /// Another account's, whichever of its clients started it.
    case anotherUsers
}

/// - Parameter userID: `getuid()` in the app; a literal in the tests, which is
///   the only way to describe a second user at all.
///
/// **`origin` is checked, but never on its own.** It is one of the fields
/// `HelperProtocol.startSession` documents as client-chosen: the daemon
/// overwrites `id`, `owner`, `ownerUID` and `startedAt` and passes this one
/// through, so `origin == .trigger` is a session's self-description, not a fact
/// the daemon established. `owner == agent-<uid>` is the corroborating half, and
/// it is the unforgeable one. Requiring both costs nothing today — the agent is
/// the only thing that sends `.trigger`, and it is the only thing that can
/// connect on the agent service — and it keeps the "started automatically" row
/// from being something any client of this user can ask for by setting a field.
///
/// (Task 3's brief called for `origin` alone, on the argument that it is the
/// honest field for the question. The research finding earlier in this plan is
/// the reason it is a conjunction instead: the honest field is also the one
/// nothing verifies. The two disagree only for sessions no shipped client can
/// produce, and every one of those has a defined home below.)
func menuSessionGroup(for session: Session, userID: UInt32) -> MenuSessionGroup {
    guard session.ownerUID == userID else { return .anotherUsers }
    // Matched against `ClientRole`'s own formatter rather than by stripping a
    // `"app-"` prefix here: `Shared/ClientIdentity.swift` owns that format, and
    // a second place spelling it is a second place to get it wrong.
    switch ClientRole.allCases.first(where: { $0.clientID(forUserID: userID) == session.owner }) {
    case .app:
        return .thisApp
    case .agent:
        // `startedByTrigger` re-checks the two clauses the lines above have
        // already established, which is deliberate: it is the single definition
        // of this rule, and since Plan 8 Task 5 the *daemon* enforces the same
        // one (`SessionIsolation.authorize`). A second hand-written conjunction
        // here would be the copy that gets loosened without the other noticing —
        // and the symptom would be a Stop button on a row the daemon refuses.
        return session.startedByTrigger(forUserID: userID) ? .yoursAutomatic : .yoursOtherClient
    case .cli:
        // Deliberately not conditioned on `origin`. A `cli-<uid>` session did
        // come from the command line whatever it says about itself, and that is
        // what this row claims.
        return .yoursCommandLine
    case nil:
        return .yoursOtherClient
    }
}

// MARK: - Where "this user's own trigger rule started this session" went
//
// `Session.startedByTrigger(forUserID:)` was defined here, as
// `menuSessionGroup(...) == .yoursAutomatic`, with a doc comment arguing it
// belonged in `Sources/` because "nothing in the daemon, the CLI or the agent
// asks this question".
//
// **Plan 8 Task 5 made that false, so it moved to `Shared/Session.swift`.**
// Spec §4's one exception — the app may stop a session this user's own trigger
// rules started — is enforced by `SessionIsolation.authorize` inside the root
// daemon, and the daemon cannot see `Sources/` at all (`project.yml`: the
// helper target compiles `Helper` + `Shared`). The definition moved down rather
// than being copied across, and the weld flipped with it: `menuSessionGroup`'s
// `.agent` branch now asks the predicate, where the predicate used to ask the
// group. Same one rule, in the one place both the daemon that enforces it and
// the menu that draws it can reach.
//
// This note is kept rather than deleted for the reason the file keeps all of
// them: the next reader looking for the rule beside the grouping should find
// out where it went and why, not an absence.

/// The row for a session **this app cannot stop**.
///
/// One shape, `"<kind> — <provenance>"`, with only the provenance varying: the
/// kind leads because it is the answer to "why is this Mac awake", and the
/// provenance is the qualifier.
///
/// ## Which groups this still renders, and why they are still not buttons
///
/// It used to be "every group but `.thisApp`", on the flat argument that
/// `SessionIsolation` scopes every stop to the caller's own sessions. **Plan 8
/// Task 5 made half of that false and the rest more specific**, so this is now a
/// record of the change rather than the original claim:
///
/// * `.thisApp` — a button, by ownership, as it always was.
/// * `.yoursAutomatic` — **a button since Task 5.** Spec §4 gained one
///   exception: the app may stop a session this same user's own trigger rules
///   started (`SessionIsolation.authorize`). `MenuContent` renders these with
///   `menuStopLabel` + `menuAutomaticSuffix`, exactly like an app-started
///   automatic session, so the two read as one kind of row.
/// * `.yoursCommandLine` — still not a button. The owner is `cli-<uid>`: this
///   user's, but another client's work, with its own way out (`keepy-uppy off`).
///   The amendment deliberately excludes it, because `origin` is client-chosen
///   and a terminal saying "trigger" is a claim rather than a fact.
/// * `.yoursOtherClient` — still not a button. This build cannot even name the
///   client, so it cannot be the app's business to end its sessions.
/// * `.anotherUsers` — still not a button, and the boundary that must never
///   move: the amendment is a uid comparison, so another account's sessions are
///   exactly as untouchable as before.
///
/// All three of those are still refused by `SessionIsolation`, so a button
/// there would still be a button that silently does nothing — which remains
/// worse than a line of text.
///
/// **No row explains why it is not a button.** The absence is the existing,
/// deliberate signal; a row that states its own limits on every rebuild is the
/// per-row accumulation the menu was rebuilt to remove. That limitation belongs
/// in the README.
func menuSessionLabel(for session: Session, group: MenuSessionGroup, now: Date) -> String {
    let provenance: String
    switch group {
    case .thisApp:
        // Not a row this function renders. It is answered rather than trapped
        // because a `fatalError` in a menu rebuild would be a crash on the one
        // path that has to survive anything the daemon sends, and the kind on
        // its own is still true of the session.
        provenance = ""
    case .yoursAutomatic:
        provenance = menuAutomaticSuffix(for: session)
    case .yoursCommandLine:
        provenance = " — started from the command line"
    case .yoursOtherClient:
        // Says only what is known: this user's, and not from anything this
        // build can name. Guessing "the command line" here is the failure this
        // group exists to prevent.
        provenance = " — started by another part of Keepy Uppy"
    case .anotherUsers:
        // Was "started elsewhere", back when this row covered another account's
        // session, this user's own command-line session and this user's own
        // trigger, and had to be vague enough to be true of all three. Now that
        // the other two have rows of their own, it can say the thing it means.
        // It discloses nothing new: the kind text in front of it is that
        // session's own description and was always shown.
        provenance = " — started by another user"
    }
    return remainingTimeText(for: session, now: now) + provenance
        + menuWakeModeSuffix(session.wakeMode)
}

/// The stored defaults are what these rows will actually start, so a default
/// that is not the ordinary one is named on the button that acts on it — the
/// same argument that put the CLI's caveat on stderr at the moment the flag is
/// typed, rather than in a README. It costs nothing in the overwhelmingly
/// common case, where both tags are empty.
///
/// **Both tags share one parenthetical.** "Keep awake for 1 hour (lid open only)
/// (disks stay awake)" is the accumulation this menu was rebuilt to remove;
/// "(lid open only, disks stay awake)" is one qualifier about one button.
func menuStartLabel(_ kind: DefaultSessionKind, wakeMode: WakeMode,
                    keepsDisksAwake: Bool) -> String {
    let tags = [menuWakeModeTag(wakeMode), menuDiskTag(keepsDisksAwake)].compactMap { $0 }
    guard !tags.isEmpty else { return "Keep awake \(kind.durationPhrase)" }
    return "Keep awake \(kind.durationPhrase) (\(tags.joined(separator: ", ")))"
}

/// What a **start** row says about the stored disk default, or `nil` when it is
/// off — which is the default, so most menus never see it.
///
/// It appears on start rows and **nowhere else**, and the asymmetry with
/// `menuWakeModeTag` is the decision worth writing down, because "why does my
/// live session's row not say it is holding disks awake?" is a question somebody
/// will ask.
///
/// A start row is a promise about what the button is *about to do*, and the
/// stored default is exactly what it will do. A session row is a description of
/// **one session**, and `menuWakeModeTag`'s rule is that such a row may never
/// make a claim about the machine. The lid tag survives that rule because a
/// session really does individually give up surviving a lid close. This axis has
/// no per-session meaning at all: holding disks out of idle does nothing *to*
/// the session, only to the machine, and the machine holds the assertion if
/// **any** live session asked. A per-session disk badge would therefore be a
/// machine claim on a row that means "this session" — the exact error the lid
/// tag was scoped to avoid. `pmset -g assertions` is where the machine-wide
/// truth lives, and it names the row and the holder.
///
/// There is deliberately no machine-wide disk line beside `menuLidCaveat`
/// either. That line exists because a lid close *loses work* when nothing holds
/// it; disks spinning is a battery cost with no work at risk, and a permanent
/// second line in the status region for it fails the same "annotate the
/// exception, not the rule" test.
func menuDiskTag(_ keepsDisksAwake: Bool) -> String? {
    keepsDisksAwake ? "disks stay awake" : nil
}

// MARK: - Wake mode

/// How a session's `WakeMode` reads in a menu row — `nil` for the mode that
/// needs no explanation.
///
/// **Annotate the exception, not the rule.** `.clamshell` is the default, the
/// strongest mode, and what every session started by this app, by a trigger,
/// or by an unflagged `keepy-uppy on` is. A badge on all of those would be a
/// badge on nearly every row of a menu that was rebuilt this week precisely
/// because each row carried too much.
///
/// What the tag says is the **lid**, not the display, and that is not a
/// stylistic choice. `.clamshell` and `.system` are *identical* in what they
/// do to the screen — neither takes `preventIdleDisplaySleep`
/// (`PowerPlan.reduce`) — so a tag reading "display may sleep" on a `.system`
/// session would imply a difference from the default that does not exist. The
/// only thing `.system` gives up relative to the default is surviving a lid
/// close, and `.systemAndDisplay` gives up the same thing and additionally
/// holds the screen on.
///
/// It is a statement about **this session**, never about the machine: the
/// daemon unions every live session's mode, so a concurrent `.clamshell`
/// session keeps the Mac awake lid-shut regardless. The machine-wide fact has
/// its own line — `menuLidCaveat(for:)` — computed from the union.
func menuWakeModeTag(_ mode: WakeMode) -> String? {
    switch mode {
    case .clamshell: return nil
    case .system: return "lid open only"
    case .systemAndDisplay: return "screen on, lid open only"
    }
}

/// `menuWakeModeTag` as something a row can concatenate unconditionally.
func menuWakeModeSuffix(_ mode: WakeMode) -> String {
    guard let tag = menuWakeModeTag(mode) else { return "" }
    return " (\(tag))"
}

// MARK: - Changing a running session's mode, from the menu

/// The one extra row a live session can earn: **the label and the request
/// together**, or `nil` when this session gets no such row.
///
/// One value rather than a `label` function beside a `request` function, because
/// those are two lists that must agree — "which rows are offered" and "what
/// clicking one sends" — and the disagreement would be invisible: a row that
/// appeared where it should not, or that sent a request other than the one it
/// named. Here the view cannot draw a row without holding the request it will
/// send, and cannot send a request no row named.
struct MenuPowerPromotion: Equatable {
    let label: String
    let request: PowerRequest
}

/// **One row, only on the exception, and only in the direction that cannot take
/// anything away.**
///
/// Plan 7 rebuilt this menu to remove per-row accumulation and forbids submenus,
/// so a three-way mode picker per session row is out. What is offered instead is
/// a single row that appears exactly where a session gives something up, and the
/// rule for *when* is `menuWakeModeTag`'s own — annotate the exception, not the
/// rule — so a user whose sessions are all lid-safe sees the menu unchanged.
///
/// ## Which sessions get it, and the correction to the brief that produced this
///
/// The brief said "a session whose mode is **not** `.clamshell`". That is one
/// mode too many, and the extra one is not a promotion at all:
///
/// * `.system` → `.clamshell` is a **strict gain**. Both hold idle system sleep
///   off and neither holds the display (`PowerPlan.reduce`), so the only
///   difference is that the session starts surviving a lid close. Nothing is
///   given up, so a misclick costs nothing.
/// * `.systemAndDisplay` → `.clamshell` is a **trade**: it gains the lid and
///   *loses* the display assertion, because no single `WakeMode` holds both —
///   the shut lid sleeps the display in hardware, so `.clamshell` asking for it
///   would be a contradiction. That is a real limitation of the three-point
///   enum, and a one-line menu row cannot honestly describe a trade without
///   growing the second clause this menu was rebuilt to remove. So it is not
///   offered, and the mode's own tag goes on saying what the session is.
///
/// The CLI expresses both, flag by flag, at a keyboard where the caveat is
/// printed beside the change — which is where a trade belongs.
///
/// **No demotion from here, in any direction.** Promotion cannot lose a user's
/// work; a demotion by misclick can, and this is a menu that opens under the
/// cursor. `keepy-uppy mode` does both.
///
/// ## What the label may claim
///
/// The **session**, never the machine. The daemon unions every live session's
/// request, so a concurrent `.clamshell` session from another client already
/// holds this Mac lid-shut regardless of what this row does — which makes any
/// machine-wide phrasing here false exactly when two sessions are live.
/// `menuLidCaveat` is the one line allowed to speak about the Mac.
///
/// The quoted form follows `menuStopLabel`'s, and for its reason: with more than
/// one row a person can act on, a bare "this session" names nothing.
///
/// - Parameter isOnlyOneOfYours: whether this is the only session with rows of
///   its own — the same question `menuStopLabel` asks, so the two rows for one
///   session agree about whether they need to name it.
func menuPowerPromotion(for session: Session, isOnlyOneOfYours: Bool,
                        now: Date) -> MenuPowerPromotion? {
    // Exhaustive, so a fourth `WakeMode` has to be given an answer here rather
    // than inheriting one — and the answer is a question about power semantics
    // ("is `.clamshell` strictly stronger than this?"), which is exactly the
    // kind a `default` must not answer on somebody's behalf.
    switch session.wakeMode {
    case .clamshell, .systemAndDisplay:
        return nil
    case .system:
        break
    }
    let subject = isOnlyOneOfYours
        ? "this session"
        : "“\(remainingTimeText(for: session, now: now).lowercased())”"
    return MenuPowerPromotion(
        label: "Make \(subject) survive a lid close",
        // **The whole request, with the disk axis carried across.** The verb
        // sets what the session asks for, so sending `keepsDisksAwake: false`
        // here would silently switch off something the session asked for and
        // nobody clicked on.
        request: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: session.keepsDisksAwake))
}

/// Why nothing happened when that row was clicked: the daemon on this Mac is too
/// old to be asked at all, so the app did not ask.
///
/// It shares its remedy with `SessionPowerSkew.note` because it shares its cause
/// — a root LaunchDaemon left running by the copy of the app that was replaced —
/// and the sentence is named once, there, rather than typed twice.
let menuPowerChangeUnavailableNote =
    "This Mac's background service can't change a session that's already running. "
    + SessionPowerSkew.olderDaemonRemedy

/// Why nothing happened when the daemon *was* asked and said no.
///
/// It ends by saying what is still true, which is the part that matters: the
/// daemon rolls a refused change back before replying, so the session is running
/// exactly as it was rather than in some state nobody can name.
let menuPowerChangeRefusedNote =
    "This Mac wouldn't make that change, so the session is still running the way it was."

/// The one machine-wide claim the menu is allowed to make, and the one surface
/// that can honestly make it.
///
/// `keepy-uppy on` knows only the session it is starting, so its caveat had to
/// be scoped to that session or be false whenever a second session was live.
/// The menu holds the **whole** list — every client's, every user's — so it can
/// answer the question that actually matters ("if I shut the lid now, does this
/// stop?") by running the daemon's own reduction over the same input the daemon
/// uses. Deriving it from `PowerPlan.reduce` rather than from any one session,
/// or from a hand-written "are they all non-clamshell" test, is what keeps the
/// menu and the mechanism from drifting.
///
/// `nil` when nothing is being kept awake (there is no guarantee to qualify)
/// and when the plan does hold the lid (the expected case, which says nothing).
func menuLidCaveat(for sessions: [Session]) -> String? {
    guard !sessions.isEmpty else { return nil }
    // `\.power`, the whole request, rather than `\.wakeMode`: this line runs the
    // daemon's own reduction over the daemon's own input, and the moment it
    // reconstructs a partial request it stops being the same computation.
    guard !PowerPlan.reduce(sessions.map(\.power)).sleepDisabled else { return nil }
    return "Closing the lid will still let this Mac sleep."
}

// MARK: - The stored default session kind

/// The preference the General pane writes, the menu reads and the hot key reads
/// again: a raw `DefaultSessionKind` in `PreferencesSuite`, read back with a
/// fallback rather than a failure.
///
/// **It arrived third, and that is the whole of why it is here.** The two types
/// below were each written to name a key once, and each says why: two files
/// that never call each other agree on a string, and a typo in either is not a
/// compile error and not a crash — it is a Settings pane that appears to work
/// while the reader goes on reading the old value. This key was the standing
/// exception both of them pointed at, a bare `"defaultSessionKind"` in
/// `MenuContent`, `SettingsView` and `MenuDefaultStart.init(readingFrom:)` —
/// the last of which sits inside a type whose entire doc comment is about the
/// menu and the hot key not drifting. So the comment that used to record the
/// gap now records the fix, in the same way Plan 7 rewrote General's adjacency
/// comment into a record of the move rather than deleting it.
///
/// The *value* `"defaultSessionKind"` is not free to change: it has shipped, so
/// renaming it forgets every existing user's choice rather than migrating it.
/// `DefaultSessionKindPreferenceTests.testTheKeyIsTheOneAlreadyOnDisk` is the
/// only literal copy left, and exists to say so.
///
/// The fallback is `.indefinite` on the reasoning `DefaultWakeModePreference`
/// gives for `.clamshell`: absence must not silently take something away, and a
/// session that ends at a time nobody chose is exactly that. It is named once
/// here because it had three spellings before — two `@AppStorage` starting
/// values and `MenuDefaultStart`'s inline `?? .indefinite`.
enum DefaultSessionKindPreference {
    static let key = "defaultSessionKind"

    /// Used both as the `@AppStorage` starting value and as the landing place
    /// for a value this build does not recognise.
    static let fallback = DefaultSessionKind.indefinite
    static var defaultRawValue: String { fallback.rawValue }

    static func kind(rawValue: String) -> DefaultSessionKind {
        DefaultSessionKind(rawValue: rawValue) ?? fallback
    }
}

// MARK: - The stored default wake mode

/// The preference Settings writes and the menu reads, arranged exactly like
/// `DefaultSessionKindPreference`'s: a raw value in `PreferencesSuite`, read
/// back with a fallback rather than a failure.
///
/// It is named here, once, for the reason `PreferencesSuite` itself is: two
/// files that never call each other agree on a string, and a typo in either is
/// not a compile error and not a crash — it is a Settings pane that appears to
/// work while the menu goes on reading the old value. This was the first of the
/// three to be named that way; the session-kind key above was the last, and its
/// doc comment records why it took a third preference to close.
///
/// The fallback is `.clamshell` on exactly the CLI's reasoning: absence must
/// mean the strongest mode, because every other choice silently weakens the
/// sessions of everyone who never opened Settings.
enum DefaultWakeModePreference {
    static let key = "defaultWakeMode"

    /// Used both as the `@AppStorage` starting value and as the landing place
    /// for a value this build does not recognise.
    static let fallback = WakeMode.clamshell
    static var defaultRawValue: String { fallback.rawValue }

    static func mode(rawValue: String) -> WakeMode {
        WakeMode(rawValue: rawValue) ?? fallback
    }
}

/// The order the Settings picker offers the modes in — default first, as the
/// menu's start list also leads with the stored default. `WakeMode.allCases`
/// is declaration order, which puts the default last; pinning the display
/// order here rather than reordering the enum keeps a presentation decision
/// out of `Shared/`, where the daemon and CLI compile.
let wakeModeSettingsOrder: [WakeMode] = [.clamshell, .system, .systemAndDisplay]

/// The wake-mode picker's own label, in **both** places one appears: the Display
/// pane and the Add-trigger sheet.
///
/// Named once for the reason `keepDisksAwakeSettingsTitle` is: two controls that
/// select the same three modes and are labelled differently teach a user they are
/// different settings.
let wakeModePickerTitle = "Keeps this Mac awake"

/// The picker row. Named for what the user gets, not for the mechanism: the
/// raw values are camelCase wire strings, and "assertion" and "SleepDisabled"
/// are implementation vocabulary that mean nothing in a Settings window.
func wakeModeSettingsTitle(_ mode: WakeMode) -> String {
    switch mode {
    case .clamshell: return "Even with the lid closed"
    case .system: return "Only with the lid open"
    case .systemAndDisplay: return "Only with the lid open, screen on"
    }
}

/// The section footer, which changes with the selection — the same shape as
/// `thermalSensitivityExplanation`, for the same reason: a picker of three
/// short phrases can distinguish the options but cannot explain their
/// consequences.
///
/// Note which direction each sentence points. "Keeps this Mac awake even after
/// you shut the lid" is a *positive* claim about a `.clamshell` session and is
/// unconditionally true, because the daemon's union can only ever strengthen
/// it. "This Mac will sleep" would be a *negative* claim, and negatives are
/// union-sensitive — false the moment any other client holds a clamshell
/// session. So every negative below is scoped to "a session in this mode",
/// exactly as `WakeMode.lidCloseCaveat` is in the CLI.
func wakeModeSettingsExplanation(_ mode: WakeMode) -> String {
    switch mode {
    case .clamshell:
        return "The default, and the only mode that survives a lid close: a session in this mode keeps this Mac awake after you shut the lid. The screen is still free to sleep on its own — a closed lid turns it off anyway."
    case .system:
        return "Holds off idle sleep while the lid is open and leaves the screen free to sleep, which is usually what a long unattended job wants. A session in this mode does not survive a lid close; only the default does."
    case .systemAndDisplay:
        // "for a dashboard or a progress window you want to be able to glance
        // at" used to end the first sentence, and it was a promise about what
        // you can *see* that nothing underwrites. The mechanism is
        // `kIOPMAssertPreventUserIdleDisplaySleep`, whose header promises
        // exactly two things — the display does not dim, the display does not
        // turn off on the idle timer — both of them facts about the panel's
        // power state. A screensaver leaves the panel lit and the dashboard
        // invisible, which satisfies every measured effect of the assertion
        // and defeats the promise entirely.
        //
        // Measured in `.superpowers/sdd/plan6-display-sleep-research.md`:
        // `HIDIdleTime` — the free, unprivileged HID idle counter — climbed
        // 43.275 s over 43 wall-clock seconds *while the assertion was held*.
        // So the assertion demonstrably does not stop the idle clock.
        //
        // What it does NOT say, deliberately: that a screensaver can still
        // start. That is an inference about `loginwindow`, whose behaviour
        // nobody here has observed, and it fails in the expensive direction —
        // a published "we cannot do this" that turns out to be wrong is a
        // capability we told people we lacked. The sentence to add if the
        // manual checklist item ever confirms it is written out in that
        // research document, ready to drop in immediately below. Removing an
        // unsupported claim needs no new evidence; adding a negative one does.
        return "Holds the screen on as well as holding off idle sleep: the display won't dim or sleep on its idle timer while a session in this mode runs. A session in this mode does not survive a lid close; only the default does."
    }
}

/// Whose sessions this actually governs, and **when**. Three of the four
/// clients ignore it: `keepy-uppy on` chooses per invocation with a flag, and a
/// trigger-started session carries its rule's own `TriggerEffect.power`.
///
/// **The trigger clause changed in Plan 8 Task 10 and the old one was a
/// promise.** It read "an automatic trigger always keeps this Mac awake with the
/// lid closed", which was true while `Agent/EvidenceLoopRunner.swift` hardcoded
/// `wakeMode: .clamshell`. A rule can now ask for either of the other two modes
/// in the Add sheet, so the unconditional version would tell a user their
/// lid-open trigger survives a lid close. It still says "lid closed", because
/// that is still what a rule gets when nobody changes it
/// (`TriggerEffect.defaultPower`) and it is still the positive fact that stays
/// true under the union — what it no longer says is "always".
///
/// "from now on" is not filler, and the clause after it changed in Plan 8 Task
/// 9. Nothing **in this pane** reaches a running session — moving this picker
/// still cannot — and someone who switches it to the lid-closed mode expecting
/// their live `.system` session to follow will shut the lid on a Mac that then
/// sleeps. That is the failure this sentence heads off, and it costs a few words.
///
/// What it may no longer say is *"a session's mode is fixed when it starts"*,
/// which is what this comment used to say and what the note implied. Task 8 made
/// it false: a running session can be switched to the lid-closed mode from the
/// menu (`menuPowerPromotion`) or with `keepy-uppy mode`. So the note points at
/// the thing that *can* reach a running session instead of leaving a reader to
/// conclude that nothing can — a nudge that sends someone to the surface that
/// solves their problem is strictly better than one that tells them there isn't
/// one. Two surfaces still tell the truth about what is in force right now (that
/// session's own tag in the menu, and `menuLidCaveat`).
let wakeModeSettingsScopeNote = "Sessions you start from the menu from now on use this. A session that's already running keeps the mode it started with, though the menu can switch one to lid-closed. The command line picks a mode per session with its own flags, and each trigger carries its own choice — new triggers keep this Mac awake with the lid closed unless you change it when you add one."

// MARK: - The stored disk default

/// The preference the Settings toggle writes and the menu reads.
///
/// It takes the **naming discipline** from `DefaultWakeModePreference` — the key
/// named once, the fallback named once — and nothing else. The reason that
/// discipline exists is that two files which never call each other agree on a
/// string, and a typo in either is not a compile error and not a crash: it is a
/// Settings pane that appears to work while the menu goes on reading the old
/// value.
///
/// It deliberately has **no unrecognised-value machinery**, because a `Bool`
/// cannot have one. `DefaultWakeModePreference.mode(rawValue:)` exists because a
/// `String` read back from `UserDefaults` can match no `WakeMode` case;
/// `UserDefaults.bool(forKey:)` returns `false` for an absent key and for a
/// non-boolean value alike, and there is no third thing it can be. A
/// `keepsDisksAwake(rawValue:)` here would be a fallback for a state that does
/// not exist.
///
/// The fallback is `false` — the opposite direction from
/// `DefaultWakeModePreference`'s, on purpose, and the same direction as
/// `Session`'s decode default and the CLI's absent flag. Absence must not
/// *weaken* a promise anybody already relies on (hence `.clamshell` there), and
/// must not *manufacture* one nobody asked for (hence `false` here).
/// Which pair of menu bar glyphs to draw.
///
/// A choice at all because a menu bar is a shared, crowded space with the
/// user's own taste in it, and because the balloon — which is the app's whole
/// visual idea — is exactly the kind of thing somebody either likes or wants
/// gone. Amphetamine has offered custom icons for years; this is the cheap
/// version of that, and the cheap version is most of the value.
///
/// **Every case is a filled/outline pair, and that is the load-bearing part.**
/// The menu bar's one job here is to answer "is this Mac being held awake"
/// without being clicked, and it answers by being full or empty. An option that
/// broke that — one glyph for both states, or two unrelated glyphs — would be a
/// preference that quietly removes the feature, so the type cannot express one.
enum MenuBarIconStyle: String, CaseIterable, Identifiable, Codable {
    case balloon, sun, moon, cup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balloon: return "Balloon"
        case .sun: return "Sun"
        case .moon: return "Moon"
        case .cup: return "Cup"
        }
    }

    /// The SF Symbol for each state. Named `active`/`idle` rather than
    /// `filled`/`outline` because that is what they mean; `.moon` inverts the
    /// visual convention (a *filled* moon reads as night, so the active glyph
    /// is the one with rays) and a name describing the drawing rather than the
    /// state would make that arm look like a bug.
    func symbol(active: Bool) -> String {
        switch self {
        case .balloon: return active ? "balloon.fill" : "balloon"
        case .sun: return active ? "sun.max.fill" : "sun.max"
        case .moon: return active ? "moon.stars.fill" : "moon"
        case .cup: return active ? "cup.and.saucer.fill" : "cup.and.saucer"
        }
    }
}

let menuBarIconSettingsTitle = "Menu bar icon"

/// Says what the icon *means*, not what it looks like — the picker already
/// shows that. Whichever pair is chosen, full means held awake and empty means
/// not, and that is the only thing a reader needs to carry away.
let menuBarIconSettingsFootnote =
    "Filled while something is keeping this Mac awake, outlined when nothing is."

enum MenuBarIconStylePreference {
    static let key = "menuBarIconStyle"
    static let fallback = MenuBarIconStyle.balloon
    static var defaultRawValue: String { fallback.rawValue }

    /// The same shape as every other raw-value reader here: an unknown string —
    /// a style written by a newer build, or a hand-edited plist — falls back
    /// rather than crashing or drawing nothing.
    static func style(rawValue: String) -> MenuBarIconStyle {
        MenuBarIconStyle(rawValue: rawValue) ?? fallback
    }
}

enum DefaultKeepDisksAwakePreference {
    static let key = "defaultKeepDisksAwake"

    /// Used both as the `@AppStorage` starting value and as the answer for
    /// anyone who has never opened this pane.
    static let fallback = false
}

/// The toggle's label. Names the effect, not the mechanism: "assertion" and
/// "PreventDiskIdle" are `pmset` vocabulary.
let keepDisksAwakeSettingsTitle = "Keep attached disks awake"

/// The footer, saying both true things — what it does, and what it cannot do.
///
/// The limitation is not optional garnish. "Keep attached disks awake" reads
/// like a promise about *your* drive, and the mechanism cannot make one: the
/// assertion is system-wide, there is no per-device assertion in public API at
/// all, and what it suspends is macOS's own `disksleep` timer, which an
/// enclosure's firmware neither reads nor obeys. See
/// `.superpowers/sdd/plan6-drive-alive-research.md`, which grepped four
/// `pwr_mgt` headers for a device-scoped assertion and found one hit: a
/// notification API deprecated in 10.9.
///
/// It also does not claim to *wake* anything. Apple's own doc comment: "This
/// assertion doesn't increase a disk's power state (it just prevents that device
/// from idling)" — a drive already parked when the session starts stays parked,
/// and Keepy Uppy does not do the I/O the header suggests for getting it back,
/// because reading arbitrary user volumes from a background daemon is a
/// different feature with a different risk profile.
///
/// This sentence lives here rather than on the CLI's stderr deliberately. See
/// `CLI/main.swift`'s note beside `lidCloseCaveat` for the argument: a warning
/// that fires on every use of a scriptable flag is one people learn to skip, and
/// this one is wrong on a Mac with only internal storage.
let keepDisksAwakeSettingsFootnote = "Attached disks stay spun up while the session runs, so an external drive doesn't park itself mid-job. It's system-wide rather than per-drive — every attached disk, not one you pick — and it can't overrule a drive's own firmware: an enclosure that decides for itself when to spin down still will. A drive that's already parked when a session starts stays parked."

/// Whose sessions this governs, and when — the same three facts
/// `wakeModeSettingsScopeNote` states for the picker directly above it, because
/// the two controls answer the same question about the same thing and a reader
/// must not have to infer that the scope carries over.
///
/// "from now on" is not filler here either: **nothing in this pane** reaches a
/// running session. That clause is deliberately about the pane and not about the
/// session, because since Plan 8 Task 8 "a session's request is fixed when it
/// starts" would be false — `keepy-uppy mode` sets a running session's whole
/// request, this axis included. The note's own mention of the command line
/// therefore covers it already, which is why the sentence itself did not have to
/// change and the note above it did: the menu's promote row is a *wake-mode* row
/// and offers nothing on this axis, so there is nothing here to point a reader
/// at that the existing clause does not.
///
/// **The trigger clause did have to change, in Plan 8 Task 10.** It read "an
/// automatic trigger never asks for it", which was true while
/// `Agent/EvidenceLoopRunner.swift` hardcoded `keepsDisksAwake: false`. The Add
/// sheet now offers the same toggle per rule, so the unconditional version would
/// be telling a user that a machine-wide effect they had just switched on could
/// not happen. It still says a trigger does not follow *this* setting, which is
/// the fact the sentence is for.
let keepDisksAwakeSettingsScopeNote = "Sessions you start from the menu from now on use this. The command line asks per session with \(keepDisksAwakeFlag), and an automatic trigger asks only if the rule that starts it does — new triggers don't unless you say so when you add one."

// MARK: - The CLI & Advanced pane

// `advancedSettingsPlaceholder` lived here — the sentence the tab showed while
// it had no controls in it, so that an empty pane could not be mistaken for one
// that failed to draw. The tab has a control now, and a placeholder that says
// "nothing to set up here yet" above an Install button is worse than no
// placeholder at all. Its two tests went with it.

/// The one-line answer to "is `keepy-uppy` on my `PATH`?", for each of the five
/// things that can be at that path.
///
/// Every sentence names the path. The pane is read by somebody who is about to
/// go and look, and "Installed" on its own does not say *where* — which is the
/// entire question when the machine has two copies of the app, or a Homebrew
/// build, or a link left behind by a version that was dragged to the Trash.
///
/// The three sentences for states this app will not touch say so in the same
/// voice and give the reason, because "won't" without a reason reads as a
/// failure. It is not a failure: another product's binary at that name is that
/// product's, and a link this app cannot prove is its own is not its to delete.
func cliInstallStatusSentence(_ state: CLIInstallState, linkPath: String) -> String {
    switch state {
    case .notInstalled:
        return "Not installed. Nothing is at \(linkPath), so typing keepy-uppy in Terminal won't find it."
    case .installed:
        return "Installed. \(linkPath) points at this copy of Keepy Uppy."
    case .linkedElsewhere(let target):
        return "\(linkPath) already points at \(target), which isn't this copy of Keepy Uppy. Keepy Uppy won't change a link it didn't make."
    case .dangling(let target):
        return "\(linkPath) points at \(target), which no longer exists — usually a copy of Keepy Uppy that was moved or deleted. Keepy Uppy won't replace a link it can't prove is its own."
    case .occupied:
        return "Something that isn't a symlink is already at \(linkPath). Keepy Uppy won't touch it."
    }
}

/// The command a user pastes into a root shell — **the one string in this pane
/// whose exact characters matter to a machine rather than to a person.**
///
/// `mkdir -p` first, because `/usr/local/bin` may be absent and `/usr/local` is
/// not user-writable either, so the directory cannot be created separately
/// without the same privilege.
///
/// Plain `ln -s`, with no `-f`. It fails loudly if something is already at that
/// path, which is the correct behaviour and the same rule the app itself
/// follows: never overwrite silently. The `-f` variant exists in
/// `cliReplaceCommand` below and is offered only for the one state where this
/// app has already told the user what is there.
///
/// Every path goes through `shellSingleQuoted`. The bundle name contains a
/// space today and could contain a `$` or a backtick tomorrow, and a shell
/// splits an unquoted `/Applications/Keepy Uppy.app/…` into two words — which
/// installs a link named `Keepy` pointing at nothing, from a command the user
/// ran as root.
func cliInstallCommand(binaryPath: String, linkPath: String) -> String {
    let directory = (linkPath as NSString).deletingLastPathComponent
    return "sudo mkdir -p \(shellSingleQuoted(directory))"
        + " && sudo ln -s \(shellSingleQuoted(binaryPath)) \(shellSingleQuoted(linkPath))"
}

/// Replacing a link that points at nothing.
///
/// `-h` is not optional garnish next to `-f`: `ln -sf` onto a symlink that
/// points at a **directory** creates the new link *inside* that directory
/// instead of replacing it, which for a dangling link is a coin toss decided by
/// what used to be at the other end.
func cliReplaceCommand(binaryPath: String, linkPath: String) -> String {
    "sudo ln -sfh \(shellSingleQuoted(binaryPath)) \(shellSingleQuoted(linkPath))"
}

func cliRemoveCommand(linkPath: String) -> String {
    "sudo rm \(shellSingleQuoted(linkPath))"
}

/// A sentence and, usually, a command: what the pane shows after a click that
/// did not simply work.
struct CLIInstallPrompt: Equatable {
    let note: String
    /// `nil` when there is nothing safe to hand over.
    let command: String?
}

/// What to say after an install attempt, or `nil` when the refreshed status
/// sentence has already said it.
///
/// `.installed` and `.alreadyInstalled` return `nil` on purpose: the sentence
/// above the button now reads "Installed. … points at this copy of Keepy Uppy",
/// which is both the outcome and the evidence, and a second line congratulating
/// the user is noise.
func cliPrompt(after result: CLIInstallResult) -> CLIInstallPrompt? {
    switch result {
    case .installed, .alreadyInstalled:
        return nil
    case .needsPrivilege(let command):
        return CLIInstallPrompt(note: cliNeedsRootToInstallNote, command: command)
    case .blocked:
        return CLIInstallPrompt(note: cliPathChangedNote, command: nil)
    case .createdButNotVerified:
        return CLIInstallPrompt(note: cliUnverifiedNote, command: nil)
    }
}

func cliPrompt(after result: CLIRemoveResult) -> CLIInstallPrompt? {
    switch result {
    case .removed, .nothingToRemove:
        return nil
    case .needsPrivilege(let command):
        return CLIInstallPrompt(note: cliNeedsRootToRemoveNote, command: command)
    case .refused:
        return CLIInstallPrompt(note: cliPathChangedNote, command: nil)
    case .removedButStillThere:
        return CLIInstallPrompt(note: cliUnverifiedNote, command: nil)
    }
}

/// Why the button did not work, said as a fact about the directory rather than
/// as an apology.
///
/// It is the **expected** outcome on a stock Mac, not an error: `/usr/local/bin`
/// is `root:wheel drwxr-xr-x` on every Mac nobody has chowned, so this is the
/// branch nearly every user reaches. Wording it as a failure would make the
/// ordinary path read as something going wrong.
let cliNeedsRootToInstallNote = "That directory belongs to root, so only an administrator can add to it. Paste this into Terminal to finish — it's the same link, made by you rather than by Keepy Uppy:"

let cliNeedsRootToRemoveNote = "That directory belongs to root, so only an administrator can remove from it. Paste this into Terminal:"

/// Offered for a dangling link, which is the one occupied state where nothing
/// is at risk: the thing the link points at is already gone.
let cliReplaceDanglingNote = "To point it at this copy instead:"

/// The state changed between the pane reading it and the button being pressed —
/// another admin, another copy of the app, a Terminal window. Rare, and it must
/// not be silent, because the button appeared to do nothing.
let cliPathChangedNote = "Something else is at that path now, so nothing was changed. The line above is what's there."

/// The should-be-unreachable one. It exists because the alternative is
/// believing a call that returned without throwing, which is the failure this
/// project has shipped three times.
let cliUnverifiedNote = "Keepy Uppy made the change and then read the path back, and what's there isn't what it wrote. Nothing further was changed."

/// What installing buys, in the pane that is read immediately before somebody
/// goes and tries it.
func cliInstallSectionFootnote(linkPath: String) -> String {
    "Installing puts a symlink at \(linkPath) — the first entry in every Mac's default PATH — so keepy-uppy works by name in any new Terminal window. Nothing is copied: the link points into this app bundle, so it follows the app when you update it, and breaks if you move it."
}

/// **The claim this pane is most likely to be read as making, and cannot.**
///
/// Task 4's research measured it rather than reasoned about it, by reproducing
/// sshd's environment exactly — its compiled `PATH`, an otherwise empty
/// environment, and this user's login shell run non-interactively and
/// non-login, which is precisely what `ssh host 'cmd'` does:
///
///     $ env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" /bin/zsh -c 'echo $PATH'
///     /Users/…/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
///
/// No `/usr/local/bin`. `/etc/ssh/sshd_config:6` says sshd was compiled with
/// that `PATH`; `/etc/zshenv` does not exist; `/etc/zprofile` runs
/// `path_helper` but is scoped to **login** shells; `PermitUserEnvironment` is
/// off by default and `AcceptEnv` does not accept `PATH`. So the bare name
/// fails over ssh today and **still fails after this feature ships**.
///
/// (`~/.zshenv` *is* sourced by that shell and can add to the `PATH` — that is
/// where `.cargo/bin` above comes from. It is the user's file and this app does
/// not write it, which is why the sentence below offers the two forms that need
/// nothing edited rather than suggesting an edit.)
///
/// The pane says so itself rather than leaving it to the README, because this
/// is the surface a user reads immediately before trying exactly that command.
let cliRemoteInvocationNote = "It doesn't make ssh mac-mini 'keepy-uppy on' work. A command sent over ssh runs in a non-login shell whose PATH is /usr/bin:/bin:/usr/sbin:/sbin — /usr/local/bin isn't on it, whatever is installed there. Either of these does work:"

/// The two forms, built rather than written out, so the second one names the
/// bundle the user is actually running.
///
/// Both are quoted by construction. The second nests a double-quoted remote
/// word inside a single-quoted local one, which is the only arrangement that
/// survives the space in `Keepy Uppy.app` on both sides of the connection.
func cliRemoteInvocationForms(binaryPath: String) -> [String] {
    [
        // A login shell, so `/etc/zprofile` runs `path_helper` and
        // `/usr/local/bin` lands on the PATH. Measured working.
        "ssh mac-mini " + shellSingleQuoted("zsh -lc " + shellDoubleQuoted("keepy-uppy on --for 8h")),
        // The absolute path, which needs nothing installed at all — the form
        // `README.md` already gives headless users for `setup`.
        "ssh mac-mini " + shellSingleQuoted(shellDoubleQuoted(binaryPath) + " on --for 8h"),
    ]
}

/// The two verbs the link cannot serve, said here because the alternative is a
/// user discovering it from a command that appears to have worked.
///
/// See `CLIBundleGuard` for the measurement and for the refusal this sentence
/// is describing. The last clause is the important one: the CLI does not merely
/// fail through the link, it declines to answer, because the failure mode it is
/// declining to produce is `reset` reporting "Daemon: not registered" with exit
/// status 0 while the daemon is still registered and still running.
let cliSetupThroughLinkNote = "keepy-uppy setup and keepy-uppy reset are the two commands the link can't serve. Both have to find the app bundle they were started from, and a link in /usr/local/bin isn't inside one — so they refuse through the link instead of reporting a result they can't stand behind. Run those with the full path above."

// MARK: - The stored shortcuts, and what the recorder says about them

/// The two global shortcuts as they are stored, arranged like
/// `DefaultWakeModePreference`: read back with a documented answer rather than
/// a failure, and the key named exactly once.
///
/// **It does not name the keys itself.** `HotKeyAction.preferenceKey` already
/// does, and a second spelling here would be the very failure that discipline
/// exists to prevent — two files agreeing on a string, with a typo in either
/// producing a recorder that appears to work above a shortcut that never
/// registers. So this type is only about the *value*: how a binding becomes a
/// string, and what an unreadable one means.
///
/// **Unset is the documented answer, and this is the one preference in the app
/// that could not have any other.** `DefaultWakeModePreference` falls back to
/// `.clamshell` and `DefaultKeepDisksAwakePreference` to `false`, because an
/// unrecognised value still has to produce *some* session. An unrecognised
/// shortcut does not: it can simply not exist, and the alternative — falling
/// back to a plausible combination — arms a global keystroke the user never
/// chose, on the one surface that gives no feedback when it fires.
enum HotKeyPreference {
    /// Delegates, deliberately. Here so a call site reads as one preference
    /// type rather than reaching into `HotKeyAction` for the key and into this
    /// type for the value.
    static func key(for action: HotKeyAction) -> String { action.preferenceKey }

    /// The binding stored for `action`, or `nil` for unset — which includes
    /// never written, written empty by the Clear button, and written with
    /// something this build cannot parse. All three mean "no shortcut", and
    /// they must, because the difference between them is invisible to the
    /// person looking at the row.
    static func binding(for action: HotKeyAction, in defaults: UserDefaults) -> HotKeyBinding? {
        guard let stored = defaults.string(forKey: action.preferenceKey) else { return nil }
        return HotKeyBinding(storedForm: stored)
    }

    /// `nil` removes the key. The recorder's Clear button instead writes an
    /// empty string, because it holds the value through `@AppStorage`, which
    /// has no way to express absence — `binding(for:in:)` reads both back as
    /// unset, and `HotKeyPreferenceTests` pins that they agree.
    static func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction,
                           in defaults: UserDefaults) {
        guard let binding else { return defaults.removeObject(forKey: action.preferenceKey) }
        defaults.set(binding.storedForm, forKey: action.preferenceKey)
    }

    /// Everything currently set, in the shape `HotKeyCenter.apply` takes.
    /// Actions with no shortcut are absent rather than present-and-nil, so
    /// "nothing is bound" is the empty dictionary and the centre registers
    /// nothing at all.
    static func allBindings(in defaults: UserDefaults) -> [HotKeyAction: HotKeyBinding] {
        var bindings: [HotKeyAction: HotKeyBinding] = [:]
        for action in HotKeyAction.allCases {
            if let binding = binding(for: action, in: defaults) { bindings[action] = binding }
        }
        return bindings
    }
}

/// What each shortcut will actually do, under its row.
///
/// The stop row's second sentence is the one that earns this function. Its
/// label already says "sessions started from the menu", but a label is read as
/// a name and a name is read charitably: somebody who has a trigger rule
/// running will read "stop" and expect their Mac to be released. It will not
/// be — `stopAllSessions(all: false)` scopes to `app-<uid>`, and their trigger
/// session is `agent-<uid>` — and the shortcut will look broken rather than
/// scoped. Saying it here costs one clause and is the only warning available,
/// because a global keystroke pressed in another app shows nothing at all.
///
/// **Its last clause used to read "the menu's own Stop button reaches exactly
/// the same set", and Plan 8 Task 5 made that false.** The menu gained a Stop
/// button on this user's trigger-started sessions (spec §4's one exception);
/// the shortcut did not, deliberately — see `SessionIsolation.sessionsToStop`
/// for why a sweep behind a silent global keystroke is the wrong home for that
/// widening. So the sentence now says where the trigger sessions *can* be
/// stopped instead of claiming the two surfaces agree. A user reading this row
/// after seeing that button would otherwise conclude one of the two is broken.
func hotKeyActionExplanation(_ action: HotKeyAction) -> String {
    switch action {
    case .startDefaultSession:
        return "Starts the same session the first row of the menu starts, with whatever you've chosen in General and Display."
    case .stopAppSessions:
        return "Stops the sessions you started from this menu. Sessions started by a trigger rule or from the command line keep running — a trigger's session has its own Stop button in the menu, one at a time."
    }
}

/// Why a shortcut that is set is not currently working.
///
/// Every case names what to do next. A row that reports a number and offers no
/// action is a row that reads as the app being broken, and this is a feature
/// whose whole risk is looking broken when it is merely conflicted.
func hotKeyRegistrationFailureSentence(_ failure: HotKeyRegistrationFailure) -> String {
    switch failure {
    case .unusableBinding(let problem):
        // The recorder's own sentence, not a second wording of it: one
        // rejection described two ways is two bugs waiting to disagree.
        return problem
    case .alreadyTaken:
        // `eventHotKeyExistsErr`, and it means precisely one thing: another
        // `RegisterEventHotKey` client holds this combination exclusively.
        // Deliberately not phrased as "macOS is using it" — that is the case
        // this API is silent about, and `hotKeySystemConflictWarning` covers it.
        return "Another app has already claimed this shortcut for itself, so macOS won't send it here. Pick a different combination."
    case .refused(let status):
        return "macOS wouldn't register this shortcut (error \(status)). Pick a different combination."
    case .noEventHandler(let status):
        return "Keepy Uppy couldn't start listening for shortcuts (error \(status)). Its shortcuts won't work until you quit and open it again."
    }
}

/// **The standing note, always visible near the recorder, and the most
/// important sentence in this pane.**
///
/// `kEventHotKeyExclusive` turns exactly one conflict into an error: another
/// `RegisterEventHotKey` client holding the same combination exclusively. It is
/// silent about the conflict people actually hit. An app that takes the key
/// another way — an event tap, a non-exclusive registration, its own frontmost
/// handling — is invisible from here: the call returns `noErr`, the row shows a
/// shortcut that is set, and the key never arrives. Measured in
/// `HotKeyRegistrationTests`, where ⌘Space registers cleanly with no error at
/// all.
///
/// So this is not an apology and it is not padding. It is the only accurate
/// description of what this API can promise, and without it a silently dead
/// shortcut looks like the app being broken rather than like a collision the
/// user can fix in five seconds by choosing another key.
///
/// It says "can't tell" rather than implying detection, because an error row
/// appearing *sometimes* is what teaches a reader that its absence means
/// success — and here its absence means nothing of the kind.
let hotKeySilentConflictNote = "If another app already uses a combination, Keepy Uppy can't tell: the shortcut will look set here and then quietly do nothing. macOS gives no way to find out. If a shortcut you've set never works, that's almost certainly why — pick a different one."

/// Shown when the combination is one of macOS's own — the part of "already
/// taken" that *is* knowable, because `CopySymbolicHotKeys` enumerates them.
///
/// Carefully not worded as a failure. Nothing failed: `RegisterEventHotKey`
/// returned `noErr` and the registration is live. The window server simply
/// consumes the key before any registration is consulted, so it never arrives.
/// Calling this an error would teach the reader that the *absence* of an error
/// means the shortcut works, which is the inference this whole pane is trying
/// to prevent.
let hotKeySystemConflictWarning = "macOS uses this shortcut itself, so it will never reach Keepy Uppy. Pick a different combination, or change the macOS one in System Settings ▸ Keyboard ▸ Keyboard Shortcuts."

/// The section footer.
///
/// It says the one thing that makes a global shortcut different from a menu
/// shortcut, and it is the **only** place a user can learn it — because the
/// menu deliberately does not show these bindings. See `MenuContent`, where
/// that decision is written out.
let hotKeyShortcutsSectionFootnote = "These work in any app, whether or not the Keepy Uppy menu is open. Leave one unset and it does nothing."

/// The placeholder in a row with no shortcut. Named here rather than written
/// into the view, so the tests above and the pane cannot disagree about what
/// "unset" looks like.
let hotKeyUnsetPlaceholder = "Not set"

// MARK: - Diagnostics

/// What this app has been able to establish about the daemon, and the only
/// input the Diagnostics copy takes.
///
/// **`.unasked` is a case rather than an initial `.unreachable`**, for the
/// reason `AppDelegate` drops the first `$sessions` value it sees: an empty
/// answer nobody asked for is not the same fact as an answer that came back
/// empty. Collapsing the two would put a fault report on screen, for a
/// perfectly healthy daemon, every time this pane appeared — for as long as one
/// XPC round trip takes, which is exactly long enough to be seen.
enum DaemonReachability: Equatable {
    /// Between the pane appearing and the first reply, and never afterwards.
    case unasked
    /// Asked, and nothing answered.
    case unreachable
    /// Asked, and the daemon said this — verbatim, whatever it said.
    case reachable(version: String)
}

/// The value beside "Background service".
///
/// It never judges what it was told. "Up to date" would be this app's opinion
/// in the one row whose job is to carry the daemon's own words into a bug
/// report; the sentence below the rows is where an opinion belongs.
func daemonVersionRowValue(_ reachability: DaemonReachability) -> String {
    switch reachability {
    case .unasked: return "Checking…"
    case .unreachable: return "Not answering"
    case .reachable(let version): return version
    }
}

/// The sentence beneath the two version rows — four states, four sentences.
///
/// The mismatch branch is the reason this section is worth having, and the
/// reason `bundleVersionText` includes the build number: a daemon and an app of
/// different vintages is not a hypothetical but the *normal* state of a Mac
/// between an in-place update and its next restart, and nothing else in the
/// product can see it.
///
/// It says the mismatch is survivable, because it is: `Session` crosses the
/// wire as JSON in both directions and an unrecognised key is ignored
/// (`HelperProtocol.startSession`), which is precisely the property that makes
/// a mixed-vintage pair keep working. Reporting a difference without that
/// clause turns a normal state into an alarm.
///
/// It does not say survivable is free, because that property cuts both ways.
/// The key an old daemon ignores is a request the caller made and does not get
/// (`SessionPowerSkew`), and a verb it predates is refused outright by
/// `DaemonCapability` rather than sent — the CLI's `mode`, the menu's promote
/// row. Sessions run; some newer options do not, and the sentence has to carry
/// both halves or it is an alarm in the other direction.
func daemonDiagnosticsSentence(_ reachability: DaemonReachability, appVersion: String) -> String {
    switch reachability {
    case .unasked:
        return "Asking the background service which version it is."
    case .unreachable:
        // Scoped to this app, not to the Mac. The daemon may be perfectly
        // alive and serving a `keepy-uppy` session while this one connection is
        // broken, so "nothing can keep this Mac awake" would be a claim this
        // side of the connection is in no position to make.
        return "Keepy Uppy isn't getting an answer from its background service, so this app can't start or stop sessions until it does. Settings → General, under Background Services, answers a different question — whether the service is registered — so it can say Running while this says otherwise. The log below is where the reason will be."
    case .reachable(let version) where version == appVersion:
        return "The background service is answering, and it's the same build as this app."
    case .reachable(let version):
        return "The background service is answering, but it's version \(version) while this app is \(appVersion). That's usually a service left running by the copy of Keepy Uppy that was replaced when this one was installed; restarting this Mac starts the new one. Sessions still work, though some newer options are refused or silently ignored until then."
    }
}

/// The subsystem every logger in this project is under —
/// `au.com.workwireless.keepy-uppy` in the app and in `Shared/`, `….helper` in
/// the daemon, `….agent` in the agent — so the prefix below reaches all of
/// them and an equality predicate would reach one.
let diagnosticsLogSubsystemPrefix = "au.com.workwireless.keepy-uppy"

/// **The one string in this section whose exact characters matter to a machine
/// rather than to a person**, and the same command `README.md` already asks bug
/// reporters for. `DiagnosticsCopyTests` reads that file and compares, rather
/// than trusting two places to keep saying the same thing.
///
/// Single-quoted around the double quotes `log` requires: unquoted, a shell
/// eats the inner quotes and `log` rejects the predicate.
let diagnosticsLogCommand =
    "log show --predicate 'subsystem BEGINSWITH \"\(diagnosticsLogSubsystemPrefix)\"'"

/// The section footer.
///
/// It names `<private>` because the redaction is the first thing a bug reporter
/// will hit and the easiest to mistake for a broken log. Measured while this
/// section was written: over the previous two days on this machine, 346 of the
/// lines that command returns carry `<private>` where a value should be —
/// including every "Accepted connection from …" the daemon writes. macOS
/// redacts non-`public` interpolations in `log show` output, and nothing this
/// app can do at the console changes that.
///
/// It does not suggest `sudo`. `log show` needs no privilege for these
/// subsystems — verified by running exactly this command as this user — and
/// telling somebody to paste a root command they do not need is how a habit of
/// pasting root commands starts.
let diagnosticsSectionFootnote = "Everything Keepy Uppy has written to the system log — the menu bar app, the background service, the agent and the command line together. Paste it into Terminal; add --last 1h to narrow it down. It's the useful thing to attach to a bug report. Some values come back as <private>: that's macOS redacting them, not a gap in the log."
