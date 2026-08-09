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
    /// `kind` and `wakeMode` are two independent axes, and every combination
    /// of them is legal: `kind` says *when the session ends*, `wakeMode` says
    /// *how it keeps the Mac awake while it lasts*.
    case on(kind: SessionKind, persistence: SessionPersistence, wakeMode: WakeMode)
    case off(StopTarget)
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
private let cliUsage = "usage: keepy-uppy on|off|status|sessions|finished|setup|reset"

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
        // `--while-vpn` takes no value because the condition is "any VPN":
        // naming one would mean typing a network-service identifier, which is
        // not a thing anybody has seen. See `VPNObserving`.
        case .whileDisplay, .whileACPower, .whileVPN: return rawValue
        case .whileCPUBusy:
            return "\(rawValue) \(cpuBusyPercentageRange.lowerBound)-\(cpuBusyPercentageRange.upperBound)"
        }
    }
}

private let onUsage = "usage: keepy-uppy on ["
    + OnOption.allCases.map(\.usageFragment).joined(separator: " | ")
    + "] [" + WakeMode.selectingFlags.joined(separator: " | ") + "]"

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
/// `on` is the only verb with two independent option groups, which is why it
/// holds two `ExclusiveChoice`s: a wake-mode flag must not consume the end
/// condition slot, and neither may be given twice.
private func parseOn(_ args: [String], now: Date) -> Result<CLICommand, CLIParseError> {
    var scanner = ArgumentScanner(args, verb: "on", usage: onUsage)
    var endCondition = ExclusiveChoice<SessionKind>(group: OnOption.allCases.map(\.rawValue))
    var wakeMode = ExclusiveChoice<WakeMode>(group: WakeMode.selectingFlags)

    while let token = scanner.next() {
        if let mode = WakeMode.selectedBy(flag: token) {
            if let error = wakeMode.choose(mode, by: token) { return .failure(error) }
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

    return .success(.on(kind: endCondition.value ?? .indefinite,
                        persistence: .detached, wakeMode: wakeMode.value ?? .clamshell))
}

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
