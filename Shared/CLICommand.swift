import Foundation

/// A plain parse-failure message. `Result`'s `Failure` type parameter
/// requires `Error` conformance, which bare `String` lacks — this exists
/// only to satisfy that without retroactively conforming `String` itself
/// to `Error` (an anti-pattern flagged and removed elsewhere in this
/// project for the same reason).
struct CLIParseError: Error, Equatable {
    let message: String
}

enum StopTarget: Equatable {
    case own
    case all
    case session(String)
}

enum CLICommand: Equatable {
    /// `kind` and `power` are independent axes, and every combination of them
    /// is legal: `kind` says *when the session ends*, `power` says *what it
    /// asks of the machine while it lasts*.
    ///
    /// `power` is a whole `PowerRequest` rather than a wake mode and a flag
    /// beside it, for the reason `PowerPlan.reduce` takes one: a case that
    /// carries the axes separately is a case somebody rebuilds with one of them,
    /// and the omission is silent. It also means the *next* axis costs nothing
    /// at this layer — every pattern match that binds the request keeps working,
    /// and every one that names an axis stops compiling until it is answered.
    case on(kind: SessionKind, persistence: SessionPersistence, power: PowerRequest)
    case off(StopTarget)
    /// Changes what a session **already running** asks of this Mac, without
    /// restarting it — which is the point, since restarting loses whatever the
    /// session's lifetime was bound to.
    ///
    /// It carries the whole `PowerRequest`, exactly as `on` does and for the
    /// same reason, and it names one session: there is no `--all` here, and no
    /// bare form. `off`'s absent target means "all of mine" because stopping
    /// everything you own is a coherent thing to ask for; changing the mode of
    /// every session you own at once is not something anybody sits down to type,
    /// and the *shape* of that mistake would be a sweep nobody named.
    case mode(session: String, power: PowerRequest)
    case status(json: Bool)
    case sessions
    /// Fires the configured "on session end" script/webhook immediately —
    /// meant to be wired into a CLI coding-assistant tool's own completion
    /// hook (Claude Code's `SessionEnd`, Codex's `hooks.json`, etc.), so it
    /// fires at real task-completion precision instead of waiting for the
    /// Agent's next 5s poll to notice a process exited. Deliberately does
    /// NOT talk to the daemon — see `CLI/main.swift`'s handling of this case
    /// for why it's a pure local action, run before the XPC connection is
    /// even attempted.
    case finished(tool: String?)
    case setup
    /// Tears down both background-service registrations. The recovery path
    /// for a daemon launchd has wedged: a stale or unresolvable job
    /// definition in the system domain cannot be replaced by re-running
    /// `setup` (registering an already-registered service does not evict the
    /// loaded job), and `launchctl bootout system/...` needs root. Going
    /// through `SMAppService.unregister()` lets `smd` do the privileged
    /// eviction on the user's behalf, so recovering never requires sudo.
    case reset
}

/// Named once: the command list appears in both failure messages below, and
/// adding a verb should not mean remembering to update two strings.
///
/// **Internal rather than `private` since Plan 8 Task 9**, and for the reason it
/// was named once in the first place: there was a *third* copy of it, spelled out
/// as a literal in `CLIInstallationTests`' "the installed link runs" assertion,
/// and adding `mode` broke it. That test does not care what the verbs are — it
/// runs the link with no arguments and reads stderr as proof the entry resolves
/// to a runnable binary — so it now reads this instead of a copy of it, and a
/// ninth verb changes one line.
let cliUsage = "usage: keepy-uppy on|off|mode|status|sessions|finished|setup|reset"

/// Pure: no I/O, no XPC, no process exit — fully testable. `now` is
/// injected so duration parsing can be tested without depending on the
/// wall clock.
func parseCLIArguments(_ args: [String], now: Date = Date()) -> Result<CLICommand, CLIParseError> {
    guard let command = args.first else { return .failure(CLIParseError(message: cliUsage)) }
    let rest = Array(args.dropFirst())

    switch command {
    case "on":
        return parseOn(rest, now: now)
    case "off":
        return parseOff(rest)
    case "mode":
        return parseMode(rest)
    case "status":
        return parseStatus(rest)
    case "sessions":
        return parseVerbWithNoOptions(rest, verb: "sessions", command: .sessions)
    case "finished":
        return parseFinished(rest)
    case "setup":
        return parseVerbWithNoOptions(rest, verb: "setup", command: .setup)
    case "reset":
        return parseVerbWithNoOptions(rest, verb: "reset", command: .reset)
    default:
        return .failure(CLIParseError(message: "unknown command '\(command)'; \(cliUsage)"))
    }
}

// MARK: - One tokenising pass, shared by every verb

/// The left-to-right pass, factored out of `parseOn` so that every verb gets
/// it rather than only the one that was rewritten first.
///
/// Strictness that stops at `on` is worse than no strictness, because it makes
/// the *shape* of a mistake unpredictable: `on --sesion` was refused while
/// `off --sesion abc-123` was accepted — as `off` with no target at all, which
/// stops **every** session this user owns rather than the one named. That is a
/// single mistyped character turning "stop this session" into "stop all of
/// mine", i.e. the argument for refusing a typo on `on`, with more at stake.
///
/// The three rules are the same wherever they are applied, so they live here
/// once:
///
/// 1. a token is read at most once, so a value can never double as a flag;
/// 2. a value that is missing, or that looks like a flag, is refused rather
///    than taken literally or silently dropped;
/// 3. an unrecognised token is an error, not something to ignore.
private struct ArgumentScanner {
    /// The verb being parsed, so a rejection can say which command's option
    /// list the token was not found in.
    let verb: String
    /// The verb's usage line, appended to a rejection so the message carries
    /// its own fix.
    let usage: String
    private let args: [String]
    private var index = 0

    init(_ args: [String], verb: String, usage: String) {
        self.args = args
        self.verb = verb
        self.usage = usage
    }

    /// The next unconsumed token, or `nil` at the end of the arguments.
    mutating func next() -> String? {
        guard index < args.count else { return nil }
        defer { index += 1 }
        return args[index]
    }

    /// The next token, consumed as `option`'s value. A value that looks like
    /// a flag is refused rather than taken literally: no duration, time,
    /// bundle id, process name, session id or tool name starts with a hyphen,
    /// so this is only ever reached by an invocation that meant to pass a flag
    /// and forgot a value.
    mutating func value(for option: String) -> Result<String, CLIParseError> {
        guard index < args.count else {
            return .failure(CLIParseError(message: "\(option) needs a value"))
        }
        let candidate = args[index]
        // Saying only "needs a value" here is unactionable when one *was*
        // given: `on --while-process -bash` reads as a flat contradiction of
        // what the user can see on their own command line. Name the token and
        // say why it was not taken.
        guard !candidate.hasPrefix("-") else {
            return .failure(CLIParseError(
                message: "\(option) needs a value, but '\(candidate)' looks like a flag"))
        }
        index += 1
        return .success(candidate)
    }

    func unknownOption(_ token: String) -> CLIParseError {
        CLIParseError(message: "unknown option '\(token)' for '\(verb)'; \(usage)")
    }
}

/// At most one of a group of mutually exclusive options — and it remembers
/// *which* one was given, which is the whole point.
///
/// Naming the entire group unconditionally produced messages listing flags the
/// user never typed: `on --for 2h --for 3h` was rejected with "only one of
/// --for, --until, --while-app, --while-process may be given", sending them to
/// look for a conflict between options that appear nowhere in their command.
/// The same flag twice and two different flags are different mistakes and get
/// different sentences.
///
/// For a single-option "group" (`--json`, `--tool`) only the duplicate branch
/// is reachable, which is correct: repeating an option is the one way to give
/// two of a group of one.
private struct ExclusiveChoice<Value> {
    /// Every flag in the group, for the message that has to name them all.
    let group: [String]
    private var chosen: (flag: String, value: Value)?

    init(group: [String]) { self.group = group }

    var value: Value? { chosen?.value }

    /// Records `value` as chosen by `flag`, or returns why it cannot be.
    mutating func choose(_ value: Value, by flag: String) -> CLIParseError? {
        guard let existing = chosen else {
            chosen = (flag, value)
            return nil
        }
        if existing.flag == flag {
            return CLIParseError(message: "\(flag) may only be given once")
        }
        return CLIParseError(message: "only one of \(group.joined(separator: ", ")) may be given")
    }
}

/// Every option `on` accepts that selects an **end condition** — when the
/// session stops. Named once, because the tokenising loop below needs both "is
/// this a known option" and "what does it mean" and they must not be able to
/// disagree.
///
/// Three of these were added long after the `SessionKind` cases they select.
/// `.whileExternalDisplay`, `.whileOnACPower` and `.whileCPUBusy` were kinds
/// the daemon evaluated, the agent watched and no client could construct,
/// because this list and `SessionKind` are separate enums with nothing welding
/// them together — adding a case there compiled fine with no flag here. That is
/// what `SessionKind.Family` and the bijection test over it now catch; read
/// `Family`'s doc comment before adding a tenth kind.
///
/// Not all of them take a value: `--while-display`, `--while-ac-power` and
/// `--while-vpn` name a condition with nothing to parameterise. That does not make them wake-mode
/// flags — those are `on`'s other, independent axis. They are end conditions,
/// they share the `ExclusiveChoice` below, and `on --for 2h --while-display` is
/// the same contradiction `on --for 2h --until 17:00` already is.
private enum OnOption: String, CaseIterable {
    case duration = "--for"
    case untilTime = "--until"
    case whileApp = "--while-app"
    case whileProcess = "--while-process"
    case whileDisplay = "--while-display"
    case whileACPower = "--while-ac-power"
    case whileCPUBusy = "--while-cpu-busy"
    case whileVolume = "--while-volume"
    case whileSubnet = "--while-subnet"
    case whileVPN = "--while-vpn"
    case whileUSB = "--while-usb"

    /// How this option reads in `onUsage`, value placeholder and all.
    ///
    /// Exhaustive, and the usage line is built from `allCases`, so a flag
    /// cannot be added and left out of it. The rejection a user gets for a typo
    /// carries that line, and it is the only list of `on`'s options the CLI ever
    /// prints — a flag missing from it is a flag nobody finds, which is a milder
    /// version of the very problem the three new ones fix.
    var usageFragment: String {
        switch self {
        case .duration: return "\(rawValue) 2h"
        case .untilTime: return "\(rawValue) 17:00"
        case .whileApp: return "\(rawValue) <bundle-id>"
        case .whileProcess: return "\(rawValue) <name>"
        // The name Finder shows, not a mount path — see
        // `MountedVolumeObserving` for why a path cannot be matched on.
        case .whileVolume: return "\(rawValue) <volume-name>"
        case .whileSubnet: return "\(rawValue) 192.168.1.0/24"
        // A real pair (Apple's Magic Keyboard) rather than `<vid>:<pid>`,
        // because the placeholder's whole job here is to say "hexadecimal" —
        // which the angle brackets do not.
        case .whileUSB: return "\(rawValue) 05ac:024f"
        // `--while-vpn` takes no value because the condition is "any VPN":
        // naming one would mean typing a network-service identifier, which is
        // not a thing anybody has seen. See `VPNObserving`.
        case .whileDisplay, .whileACPower, .whileVPN: return rawValue
        case .whileCPUBusy:
            return "\(rawValue) \(cpuBusyPercentageRange.lowerBound)-\(cpuBusyPercentageRange.upperBound)"
        }
    }
}

/// `on`'s third axis, named once so the parser, the usage line, the rejection
/// message and the Settings copy that points at it cannot drift apart.
///
/// It is not a wake mode and not an end condition, so it belongs to neither
/// exhaustive list — see `onUsage` for what that costs.
let keepDisksAwakeFlag = "--keep-disks-awake"

/// **This line's structural guarantee is now partial, and that is a deliberate
/// trade rather than an oversight.**
///
/// The first two fragments are built from exhaustive lists (`OnOption.allCases`
/// and `WakeMode.selectingFlags`), which is what
/// `OnOption.usageFragment`'s doc comment buys: "a flag cannot be added and left
/// out of it". `--keep-disks-awake` is in neither list — it is not an end
/// condition and not a wake mode — so it is the **first hand-concatenated
/// fragment**, and for it the guarantee drops from structural ("no flag can be
/// omitted") to per-flag ("a test covers this one"). That test is
/// `CLIDiskAxisParsingTests.testTheUsageLineNamesTheDiskFlag`, and it is not a
/// nice-to-have.
///
/// If a **second** such flag ever arrives, that is the signal to give this
/// category its own `CaseIterable` list and restore the structural guarantee.
/// Building that list now, for one member, would be ceremony around a single
/// string.
private let onUsage = "usage: keepy-uppy on ["
    + OnOption.allCases.map(\.usageFragment).joined(separator: " | ")
    + "] [" + WakeMode.selectingFlags.joined(separator: " | ") + "]"
    + " [" + keepDisksAwakeFlag + "]"

/// One left-to-right pass over the arguments, rather than one `contains` scan
/// per option.
///
/// The scans could not tell an option's *value* from a flag, because nothing
/// tracked which tokens had already been consumed. So a missing value silently
/// ate the next flag and that flag still counted: `on --while-app
/// --display-may-sleep` produced a session watching a bundle id of
/// "--display-may-sleep" **and** selected `.system`, from the same token. The
/// scanner consumes a value at the point it reads the option it belongs to, so
/// a token can only ever play one role.
///
/// It also means an unrecognised token is an error. Silently ignoring one is
/// worse here than in most CLIs: `on --keep-dispaly-awake` is a typo whose old
/// behaviour — accept, start a clamshell session — differs from what was asked
/// for in the direction the user cannot see.
///
/// `on` is the only verb with independent option groups, which is why it holds
/// three `ExclusiveChoice`s: neither a wake-mode flag nor the disk flag may
/// consume the end-condition slot, and none of the three may be given twice.
///
/// Three groups rather than one is the whole point of the disk flag being a
/// separate slot: `--display-may-sleep --keep-disks-awake` is a coherent request
/// ("let the screen sleep, keep the backup drive spun up") and is accepted,
/// where `--display-may-sleep --keep-display-awake` is a contradiction and is
/// not. Folding it into the wake-mode group would refuse the first as if it were
/// the second.
private func parseOn(_ args: [String], now: Date) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "on", usage: onUsage)
    var endCondition = ExclusiveChoice<SessionKind>(group: OnOption.allCases.map(\.rawValue))
    var wakeMode = ExclusiveChoice<WakeMode>(group: WakeMode.selectingFlags)
    // A single-flag group, in the shape `parseStatus` uses for `--json`: only
    // the duplicate branch is reachable, which is correct — repeating a flag is
    // the one way to give two of a group of one.
    var keepDisksAwake = ExclusiveChoice<Bool>(group: [keepDisksAwakeFlag])

    while let token = scanner.next() {
        if let mode = WakeMode.selectedBy(flag: token) {
            if let error = wakeMode.choose(mode, by: token) { return .failure(error) }
            continue
        }

        if token == keepDisksAwakeFlag {
            if let error = keepDisksAwake.choose(true, by: token) { return .failure(error) }
            continue
        }

        // The value is parsed before the choice is recorded, so a malformed
        // value is still reported as malformed rather than being masked by a
        // duplicate-option rejection: `on --for 2h --for banana` names the
        // banana.
        let kind: SessionKind
        switch OnOption(rawValue: token) {
        case .duration:
            switch scanner.value(for: token).flatMap(parseDuration) {
            case .success(let interval): kind = .duration(until: now.addingTimeInterval(interval))
            case .failure(let error): return .failure(error)
            }
        case .untilTime:
            switch scanner.value(for: token) {
            case .success(let raw):
                guard let date = parseTimeOfDay(raw, relativeTo: now) else {
                    return .failure(CLIParseError(message: "could not parse --until time '\(raw)'"))
                }
                kind = .untilTime(date)
            case .failure(let error): return .failure(error)
            }
        case .whileApp:
            switch scanner.value(for: token) {
            case .success(let raw): kind = .whileAppRunning(bundleID: raw)
            case .failure(let error): return .failure(error)
            }
        case .whileProcess:
            switch scanner.value(for: token) {
            case .success(let raw): kind = .whileProcessRunning(processName: raw)
            case .failure(let error): return .failure(error)
            }
        case .whileVolume:
            switch scanner.value(for: token) {
            case .success(let raw): kind = .whileVolumeMounted(name: raw)
            case .failure(let error): return .failure(error)
            }
        case .whileSubnet:
            switch scanner.value(for: token).flatMap(parseSubnet) {
            case .success(let cidr): kind = .whileOnSubnet(cidr: cidr)
            case .failure(let error): return .failure(error)
            }
        case .whileDisplay:
            kind = .whileExternalDisplay
        case .whileACPower:
            kind = .whileOnACPower
        case .whileVPN:
            kind = .whileVPNActive
        case .whileUSB:
            switch scanner.value(for: token).flatMap(parseUSBDeviceID) {
            case .success(let device):
                kind = .whileUSBDevicePresent(vendorID: device.vendorID, productID: device.productID)
            case .failure(let error): return .failure(error)
            }
        case .whileCPUBusy:
            switch scanner.value(for: token).flatMap(parseCPUBusyPercentage) {
            case .success(let threshold): kind = .whileCPUBusy(threshold: threshold)
            case .failure(let error): return .failure(error)
            }
        case nil:
            return .failure(scanner.unknownOption(token))
        }
        if let error = endCondition.choose(kind, by: token) { return .failure(error) }
    }

    // The two absent-flag directions point opposite ways, and both are
    // load-bearing. No wake-mode flag means `.clamshell`, the strongest mode,
    // because that is what every `keepy-uppy on` written before those flags
    // existed already got and anything else silently weakens them. No disk flag
    // means `false`, the weakest state, because nothing written before this flag
    // existed asked for it and inventing a machine-wide held assertion for a
    // script that never requested one is over-application.
    return .success(.on(kind: endCondition.value ?? .indefinite,
                        persistence: .detached,
                        power: PowerRequest(wakeMode: wakeMode.value ?? .clamshell,
                                            keepsDisksAwake: keepDisksAwake.value ?? false)))
}

/// `mode`'s one option: **which** session. An enum for a single case, in
/// `OffOption`'s shape, because the usage line and the "is this a known token"
/// test must not be able to disagree about it.
private enum ModeOption: String, CaseIterable {
    case session = "--session"
}

/// The same two-part shape as `onUsage`, built from the same exhaustive list
/// (`WakeMode.selectingFlags`) plus the same one hand-concatenated flag — see
/// `onUsage` for what that costs and which test pays for it;
/// `CLIModeParsingTests.testTheUsageLineNamesEveryFlagThisVerbAccepts` is this
/// verb's copy of it.
///
/// The trailing sentence is Task 9 Step 1's requirement stated where a user
/// meets it. The absent-flag rule is the *same* rule `on` has and for the same
/// reason, but it needs saying out loud here because the intuition it defeats is
/// stronger: this verb acts on something already running, so "leave the axis I
/// did not mention alone" is the obvious reading — and it is not what happens,
/// because the verb sets the session's whole request rather than editing one
/// axis of it.
private let modeUsage = "usage: keepy-uppy mode --session <id> ["
    + WakeMode.selectingFlags.joined(separator: " | ") + "]"
    + " [" + keepDisksAwakeFlag + "]"
    + " — sets the session's whole request, so a flag you leave out means what it means for"
    + " 'on' (lid-closed mode, disks not held), not \"leave that as it is\""

/// The same left-to-right pass, the same flag machinery, and deliberately not a
/// second copy of either.
///
/// `WakeMode.selectedBy(flag:)` and `keepDisksAwakeFlag` are what `on` parses
/// through, so there is exactly one list of power flags in this file. A second
/// list is how `.whileExternalDisplay`, `.whileOnACPower` and `.whileCPUBusy`
/// became kinds no client could ask for — see `OnOption`'s comment — and the
/// same shape one axis over would be a `mode` that could not select a mode `on`
/// could.
///
/// What it does **not** share is the end-condition list: a session's kind is
/// fixed for its whole life, so `mode --for 2h` is not a request this verb could
/// honour and is rejected as an unknown option rather than quietly ignored.
private func parseMode(_ args: [String]) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "mode", usage: modeUsage)
    var target = ExclusiveChoice<String>(group: ModeOption.allCases.map(\.rawValue))
    var wakeMode = ExclusiveChoice<WakeMode>(group: WakeMode.selectingFlags)
    var keepDisksAwake = ExclusiveChoice<Bool>(group: [keepDisksAwakeFlag])

    while let token = scanner.next() {
        if let mode = WakeMode.selectedBy(flag: token) {
            if let error = wakeMode.choose(mode, by: token) { return .failure(error) }
            continue
        }

        if token == keepDisksAwakeFlag {
            if let error = keepDisksAwake.choose(true, by: token) { return .failure(error) }
            continue
        }

        switch ModeOption(rawValue: token) {
        case .session:
            switch scanner.value(for: token) {
            case .success(let id):
                if let error = target.choose(id, by: token) { return .failure(error) }
            case .failure(let error): return .failure(error)
            }
        case nil:
            return .failure(scanner.unknownOption(token))
        }
    }

    // **Absence is not a target here**, unlike `off`. There is no session this
    // could sensibly default to, and defaulting to "all of mine" would turn a
    // forgotten flag into a change to sessions nobody named — the widening
    // `parseOff`'s comment is about, with a mode change instead of a stop.
    guard let session = target.value else {
        return .failure(CLIParseError(message: "mode needs a session to change; \(modeUsage)"))
    }
    // The same two absent-flag directions as `parseOn`, deliberately identical:
    // no wake-mode flag means `.clamshell`, no disk flag means `false`. A verb
    // whose absent flags meant "leave that axis alone" would be sending half a
    // request, which is the shape `PowerRequest` and this whole verb exist to
    // refuse.
    return .success(.mode(session: session,
                          power: PowerRequest(wakeMode: wakeMode.value ?? .clamshell,
                                              keepsDisksAwake: keepDisksAwake.value ?? false)))
}

/// What `keepy-uppy mode` says when this Mac's daemon is too old to be asked to
/// change a running session — which is a refusal by *this* process, before
/// anything is sent, not a reply.
///
/// In `Shared/` rather than inline in `CLI/main.swift` for that file's standing
/// reason: it is not reachable from the test target, so a sentence written there
/// is one no test can read. `DaemonRemoval.unreachableNote` is the precedent —
/// the same kind of "here is why nothing happened, and what to do" line, for the
/// same binary, kept where it can be checked.
///
/// It names both ways out, because they are genuinely different trades: a
/// restart replaces the daemon and costs whatever is running on this Mac, while
/// stopping and starting a session costs only what that session's lifetime was
/// bound to. Deliberately *not* sharing `SessionPowerSkew.olderDaemonRemedy`,
/// which says "an older build than this app" — true, and in the wrong voice for
/// something printed by a command-line tool that is not an app.
let cliOldDaemonCannotChangeASessionNote =
    "the background service on this Mac is an older build and can't change a session that's "
    + "already running. Restart this Mac to update it, or stop the session and start a new one."

// MARK: - The wake-mode surface

/// `on`'s second, independent axis: how the session keeps the Mac awake.
///
/// **Absence means `.clamshell`**, and that is load-bearing rather than an
/// arbitrary pick. `.clamshell` is the only mode that survives a lid close
/// (it is the one that sets the global `SleepDisabled`; assertions do not
/// survive a lid close — spec §1), and it is what every `keepy-uppy on`
/// written before these flags existed already got. Any other default would
/// silently weaken every script and every documented invocation. That is why
/// `.clamshell` is the one mode with no flag: it is selected by absence.
///
/// Two flags rather than one boolean because `WakeMode` has three cases and a
/// bool can only name two. Two flags rather than a `--wake-mode <name>`
/// option because each flag names exactly what it changes about the display,
/// and because the raw values (`systemAndDisplay`) are camelCase wire strings
/// that have no business being typed at a shell prompt.
///
/// They are mutually exclusive for the same reason `--for` and `--until` are,
/// and `parseOn` rejects them the same way: a session holds exactly one
/// `WakeMode`, so asking for two is a contradiction to reject, not a
/// precedence rule to invent. (Two *different* live sessions may hold
/// different modes; unioning those is `PowerPlan.reduce`'s job in the daemon,
/// not something one `on` invocation can express.)
extension WakeMode {
    /// The `on` flag that selects this mode; `nil` for the default.
    ///
    /// Named here rather than as literals inside the parser so that the
    /// parser, the "only one of …" rejection, the usage line, and the caveat
    /// the CLI prints to stderr cannot drift apart — they all read this.
    var selectingFlag: String? {
        switch self {
        case .clamshell: return nil
        case .system: return "--display-may-sleep"
        case .systemAndDisplay: return "--keep-display-awake"
        }
    }

    /// Every flag that selects a mode, for messages that name them all.
    static var selectingFlags: [String] { allCases.compactMap(\.selectingFlag) }

    static func selectedBy(flag: String) -> WakeMode? {
        allCases.first { $0.selectingFlag == flag }
    }

    /// The thing the flag's own name does not say, for the CLI to print to
    /// **stderr** the moment it is used — at the keyboard, where the mistake
    /// is being made, not in a README nobody rereads.
    ///
    /// Both flags *drop* the clamshell axis, because the mode they select is
    /// not `.clamshell`. `--keep-display-awake` reads purely additive — "same
    /// as before, plus the screen stays on" — and is not: it keeps the display
    /// lit and stops keeping a lid-shut laptop awake. A user who types
    /// `on --for 8h --keep-display-awake`, shuts the lid and walks away loses
    /// the eight hours, and nothing they typed hinted at it.
    ///
    /// `nil` for `.clamshell`, which takes nothing away and is what an
    /// unflagged invocation already got.
    ///
    /// It is a statement about **this session**, not about the Mac, and the
    /// difference is not pedantry: the daemon unions the modes of every live
    /// session (`PowerPlan.reduce`), so a concurrent `.clamshell` session from
    /// another client keeps the machine awake lid-shut regardless of what this
    /// one asked for. "`--keep-display-awake` does not keep this Mac awake
    /// with the lid closed" was therefore false exactly when a user was most
    /// likely to be running two sessions at once — and a note that is
    /// sometimes wrong is worse than none, because it teaches people to skip
    /// the notes. Scoped to the session being started, it is unconditional.
    var lidCloseCaveat: String? {
        guard let flag = selectingFlag else { return nil }
        return "\(flag): this session does not keep this Mac awake with the lid closed; "
            + "only the default mode does."
    }

    /// How this mode reads in a `keepy-uppy sessions` row.
    ///
    /// The raw name is kept as the stem — it is what the README and the spec
    /// call each mode — but it is not left to speak for itself, because the
    /// one fact a reader is looking for is not in it. Before the flags
    /// existed, "keeping awake" *implied* lid-safe, since every session was a
    /// clamshell session; a `--display-may-sleep` session now prints the same
    /// `status` output as a default one, so this listing is where the
    /// difference has to become visible.
    /// Each parenthetical is about **this session**, never about the Mac, for
    /// the reason `lidCloseCaveat` above spells out: the daemon unions every
    /// live session's mode, so a concurrent `.clamshell` session holds the lid
    /// regardless. A bare "no lid close" read as a claim about the machine, and
    /// as such was false exactly when two sessions were live — the moment this
    /// listing is most worth printing.
    var sessionListDescription: String {
        switch self {
        case .clamshell: return "clamshell (this session survives a lid close)"
        case .system: return "system (this session does not survive a lid close; display may sleep)"
        case .systemAndDisplay: return "systemAndDisplay (this session does not survive a lid close; display stays on)"
        }
    }
}

extension PowerRequest {
    /// How a whole request reads in a `keepy-uppy sessions` row.
    ///
    /// The disk clause exists for the reason `wakeMode.sessionListDescription`
    /// does, one axis over: `status` answers a boolean that is true for every
    /// request, and the menu bar shows the same filled balloon either way, so
    /// without this line a `--keep-disks-awake` session is indistinguishable
    /// from one without it in **every** output the product has — which is the
    /// exact invisibility the `wake=` field was added to fix.
    ///
    /// Present only when the session asked for it: "annotate the exception, not
    /// the rule". An absent clause is unambiguous here — this listing is prose
    /// for a person, and `status --json` is what a script reads.
    ///
    /// It is deliberately *not* the menu's decision. A menu row is a short
    /// label competing for space with three others; this is a diagnostic line
    /// whose whole job is to say what each session asked for, and what it asked
    /// for is a fact about the request rather than a claim about the machine.
    var sessionListDescription: String {
        wakeMode.sessionListDescription + (keepsDisksAwake ? "; attached disks held awake" : "")
    }
}

// MARK: - The other verbs

/// `off`'s options. Both name a *target*, and a stop has exactly one, so they
/// share a single `ExclusiveChoice` — asking to stop both everything and one
/// named session is a contradiction, not a precedence rule to invent.
private enum OffOption: String, CaseIterable {
    case all = "--all"
    case session = "--session"
}

private let offUsage = "usage: keepy-uppy off [--all | --session <id>]"

/// The verb with the most to lose from a silently-ignored typo, and the reason
/// the strictness `on` got was worth generalising.
///
/// Absence of a target is not "nothing to do" here — it is `.own`, which stops
/// every session this user owns. So an option that fails to be recognised does
/// not degrade to a smaller action, it *widens* to a larger one:
/// `off --sesion abc-123` used to stop all of the caller's sessions instead of
/// the one it named, silently, with a zero exit status. Every rejection below
/// costs a retype; the behaviour it replaces costs however much work the other
/// sessions were protecting.
private func parseOff(_ args: [String]) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "off", usage: offUsage)
    var target = ExclusiveChoice<StopTarget>(group: OffOption.allCases.map(\.rawValue))

    while let token = scanner.next() {
        let chosen: StopTarget
        switch OffOption(rawValue: token) {
        case .all:
            chosen = .all
        case .session:
            switch scanner.value(for: token) {
            case .success(let id): chosen = .session(id)
            case .failure(let error): return .failure(error)
            }
        case nil:
            return .failure(scanner.unknownOption(token))
        }
        if let error = target.choose(chosen, by: token) { return .failure(error) }
    }

    return .success(.off(target.value ?? .own))
}

private let statusUsage = "usage: keepy-uppy status [--json]"

/// `--json` takes no value, so `status` needs no `OnOption`-style enum — one
/// literal, compared once. It still goes through the scanner, because the
/// failure that matters here is `status --jsno`: a script that asked for
/// machine-readable output and silently got prose, then parsed it.
private func parseStatus(_ args: [String]) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "status", usage: statusUsage)
    var json = ExclusiveChoice<Bool>(group: ["--json"])

    while let token = scanner.next() {
        guard token == "--json" else { return .failure(scanner.unknownOption(token)) }
        if let error = json.choose(true, by: token) { return .failure(error) }
    }

    return .success(.status(json: json.value ?? false))
}

private let finishedUsage = "usage: keepy-uppy finished [--tool <name>]"

/// `--tool` is optional context, not a selector — `finished` fires the same
/// configured action regardless of which tool (if any) is named; the name just
/// rides along into the script's env vars / webhook JSON.
///
/// Optional is not the same as ignorable, though, which is what the old
/// `firstIndex(of:)` lookup made it: `finished --tol claude-code` fired the
/// action with no tool attached, and `finished --tool` (value forgotten) did
/// the same. The webhook then reported a completion from nowhere in
/// particular, and nothing said why.
private func parseFinished(_ args: [String]) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "finished", usage: finishedUsage)
    var tool = ExclusiveChoice<String>(group: ["--tool"])

    while let token = scanner.next() {
        guard token == "--tool" else { return .failure(scanner.unknownOption(token)) }
        switch scanner.value(for: token) {
        case .success(let name):
            if let error = tool.choose(name, by: token) { return .failure(error) }
        case .failure(let error): return .failure(error)
        }
    }

    return .success(.finished(tool: tool.value))
}

/// `sessions`, `setup` and `reset` take no options at all, so every argument
/// is an unknown one.
///
/// Included for the same reason as the three verbs above even though none of
/// them can lose work: "does this verb notice a typo?" should not be a
/// question a user has to hold per-verb knowledge to answer. `sessions --jsno`
/// and `sessions --json` now say the same thing — that this verb has no
/// options — instead of one being ignored and the other being ignored.
private func parseVerbWithNoOptions(_ args: [String], verb: String,
                                    command: CLICommand) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: verb, usage: "usage: keepy-uppy \(verb)")
    if let token = scanner.next() { return .failure(scanner.unknownOption(token)) }
    return .success(command)
}

/// Accepts "30s", "10m", "2h" — the smallest set that covers every
/// realistic keep-awake duration without inventing a parsing DSL.
func parseDuration(_ string: String) -> Result<TimeInterval, CLIParseError> {
    guard let unit = string.last, let value = Double(string.dropLast()) else {
        return .failure(CLIParseError(message: "invalid duration '\(string)' — use e.g. 30s, 10m, 2h"))
    }
    switch unit {
    case "s": return .success(value)
    case "m": return .success(value * 60)
    case "h": return .success(value * 3600)
    default: return .failure(CLIParseError(message: "invalid duration unit in '\(string)' — use s, m, or h"))
    }
}

/// The whole percentages `--while-cpu-busy` accepts.
///
/// Both ends are excluded because each names a session that cannot do what its
/// author meant, and `CPUBusyWindow` is where to see why: it ends a session once
/// load has stayed **below** the threshold for two minutes, and the sampled
/// fraction is clamped to 0...1. So `0` is a session that can never end — load
/// cannot drop below zero — and `100` is one that ends two minutes after
/// anything short of a pegged CPU. Neither is a rule anybody sits down to write.
let cpuBusyPercentageRange = 1...99

/// Accepts a whole percentage — `30` — and returns the fraction
/// `SessionKind.whileCPUBusy` stores.
///
/// A percentage rather than the fraction itself, because a shell prompt is
/// where "30% busy" is the natural thing to type, and because the two readings
/// of `--while-cpu-busy 0.3` differ by a factor of a hundred with nothing to
/// tell them apart afterwards. `0.3` therefore is not quietly taken as 30%: it
/// means 0.3%, a threshold the CPU can never fall below, i.e. a session that
/// never ends, and nothing about having typed it would ever say so. Refusing a
/// value that can only produce a session that cannot work is the same call
/// `TriggerCondition.processNameProblem` makes about a path in a process field
/// — name it at the keyboard, where it is still one keystroke to fix.
func parseCPUBusyPercentage(_ string: String) -> Result<Double, CLIParseError> {
    guard let percentage = Int(string), cpuBusyPercentageRange.contains(percentage) else {
        return .failure(CLIParseError(
            message: "invalid --while-cpu-busy threshold '\(string)' — use a whole percentage from "
                + "\(cpuBusyPercentageRange.lowerBound) to \(cpuBusyPercentageRange.upperBound), "
                + "e.g. 30 for 30% busy"))
    }
    return .success(Double(percentage) / 100)
}

/// Accepts an IPv4 address or CIDR block, and hands back **what was typed**.
///
/// The value is validated but not normalized, for the reason `--while-app`
/// takes a bundle id verbatim: the string is what `status` and the menu will
/// show back, and `192.168.1.50/24` is what the user wrote down off their own
/// network settings. `IPv4Subnet` masks the host bits when it matches, so the
/// stored form and the matched block cannot disagree.
///
/// Refusing an unparseable value here is the same call `parseCPUBusyPercentage`
/// makes: a session whose block can never match is a session that will not end
/// on its own condition, and saying so at the keyboard costs one retype.
func parseSubnet(_ string: String) -> Result<String, CLIParseError> {
    guard IPv4Subnet(cidr: string) != nil else {
        return .failure(CLIParseError(
            message: "invalid --while-subnet block '\(string)' — use an IPv4 address or block, "
                + "e.g. 192.168.1.0/24 or 192.168.1.50 (IPv6 is not supported yet)"))
    }
    return .success(string)
}

/// Accepts a USB vendor/product pair in the form every USB tool prints it —
/// `05ac:024f`, or `0x05ac:0x024F` if that is how it was copied.
///
/// The colon is what makes this readable and is also the one thing to watch:
/// `--while-usb` is the only option whose *value* contains a colon, so a
/// consumer of `SessionKind.wireDescription` splitting on the first one still
/// gets the whole pair back (see `USBDeviceID.text`).
///
/// Refusing an unparseable value here is the call `parseSubnet` and
/// `parseCPUBusyPercentage` both make: a session whose device can never match
/// is one that will end two ticks after it starts, and saying so at the
/// keyboard costs one retype. The message names the value **and** points at
/// `system_profiler`, because "what is my dongle's vendor ID" is a real
/// question and a rejection that does not answer it just moves the problem.
func parseUSBDeviceID(_ string: String) -> Result<USBDeviceID, CLIParseError> {
    guard let device = USBDeviceID(text: string) else {
        return .failure(CLIParseError(
            message: "invalid --while-usb device '\(string)' — use a hexadecimal vendor:product pair, "
                + "e.g. 05ac:024f. `system_profiler SPUSBDataType` lists what is plugged in."))
    }
    return .success(device)
}

/// Accepts "HH:MM" in the local timezone, rolling to tomorrow if that
/// time has already passed today.
func parseTimeOfDay(_ string: String, relativeTo now: Date) -> Date? {
    let parts = string.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
    var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    guard let candidate = Calendar.current.date(from: components) else { return nil }
    return candidate > now ? candidate : Calendar.current.date(byAdding: .day, value: 1, to: candidate)
}
