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
        return .success(.status(json: rest.contains("--json")))
    case "sessions":
        return .success(.sessions)
    case "finished":
        return .success(.finished(tool: parseTool(rest)))
    case "setup":
        return .success(.setup)
    case "reset":
        return .success(.reset)
    default:
        return .failure(CLIParseError(message: "unknown command '\(command)'; \(cliUsage)"))
    }
}

/// Every option `on` accepts that takes a value. Named once, because the
/// tokenising loop below needs both "is this a known option" and "what does it
/// mean" and they must not be able to disagree.
private enum OnOption: String, CaseIterable {
    case duration = "--for"
    case untilTime = "--until"
    case whileApp = "--while-app"
    case whileProcess = "--while-process"
}

private let onUsage = "usage: keepy-uppy on [--for 2h | --until 17:00 | --while-app <bundle-id> "
    + "| --while-process <name>] [" + WakeMode.selectingFlags.joined(separator: " | ") + "]"

/// One left-to-right pass over the arguments, rather than one `contains` scan
/// per option.
///
/// The scans could not tell an option's *value* from a flag, because nothing
/// tracked which tokens had already been consumed. So a missing value silently
/// ate the next flag and that flag still counted: `on --while-app
/// --display-may-sleep` produced a session watching a bundle id of
/// "--display-may-sleep" **and** selected `.system`, from the same token. This
/// loop consumes a value at the point it reads the option it belongs to, so a
/// token can only ever play one role.
///
/// It also means an unrecognised token is now an error. Silently ignoring one
/// is worse here than in most CLIs: `on --keep-dispaly-awake` is a typo whose
/// old behaviour — accept, start a clamshell session — differs from what was
/// asked for in the direction the user cannot see.
private func parseOn(_ args: [String], now: Date) -> Result<CLICommand, CLIParseError> {
    var endConditions: [SessionKind] = []
    var modes: [WakeMode] = []
    var index = 0

    /// The next token, consumed as `option`'s value. A value that looks like
    /// a flag is refused rather than taken literally: no duration, time,
    /// bundle id or process name starts with a hyphen, so this is only ever
    /// reached by an invocation that meant to pass a flag and forgot a value.
    func value(for option: String) -> Result<String, CLIParseError> {
        guard index < args.count, !args[index].hasPrefix("-") else {
            return .failure(CLIParseError(message: "\(option) needs a value"))
        }
        defer { index += 1 }
        return .success(args[index])
    }

    while index < args.count {
        let token = args[index]
        index += 1

        if let mode = WakeMode.selectedBy(flag: token) {
            modes.append(mode)
            continue
        }

        switch OnOption(rawValue: token) {
        case .duration:
            switch value(for: token).flatMap(parseDuration) {
            case .success(let interval): endConditions.append(.duration(until: now.addingTimeInterval(interval)))
            case .failure(let error): return .failure(error)
            }
        case .untilTime:
            switch value(for: token) {
            case .success(let raw):
                guard let date = parseTimeOfDay(raw, relativeTo: now) else {
                    return .failure(CLIParseError(message: "could not parse --until time '\(raw)'"))
                }
                endConditions.append(.untilTime(date))
            case .failure(let error): return .failure(error)
            }
        case .whileApp:
            switch value(for: token) {
            case .success(let raw): endConditions.append(.whileAppRunning(bundleID: raw))
            case .failure(let error): return .failure(error)
            }
        case .whileProcess:
            switch value(for: token) {
            case .success(let raw): endConditions.append(.whileProcessRunning(processName: raw))
            case .failure(let error): return .failure(error)
            }
        case nil:
            return .failure(CLIParseError(message: "unknown option '\(token)' for 'on'; \(onUsage)"))
        }
    }

    guard endConditions.count <= 1 else {
        return .failure(CLIParseError(
            message: "only one of \(OnOption.allCases.map(\.rawValue).joined(separator: ", ")) may be given"))
    }
    guard modes.count <= 1 else {
        return .failure(CLIParseError(
            message: "only one of \(WakeMode.selectingFlags.joined(separator: ", ")) may be given"))
    }

    return .success(.on(kind: endConditions.first ?? .indefinite,
                        persistence: .detached, wakeMode: modes.first ?? .clamshell))
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
    var lidCloseCaveat: String? {
        guard let flag = selectingFlag else { return nil }
        return "\(flag) does not keep this Mac awake with the lid closed; only the default does."
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
    var sessionListDescription: String {
        switch self {
        case .clamshell: return "clamshell (survives a lid close)"
        case .system: return "system (no lid close; display may sleep)"
        case .systemAndDisplay: return "systemAndDisplay (no lid close; display stays on)"
        }
    }
}

/// `--tool` is optional context, not a selector — `finished` fires the same
/// configured action regardless of which tool (if any) is named; the name
/// just rides along into the script's env vars / webhook JSON.
private func parseTool(_ args: [String]) -> String? {
    guard let idx = args.firstIndex(of: "--tool"), args.indices.contains(idx + 1) else { return nil }
    return args[idx + 1]
}

private func parseOff(_ args: [String]) -> Result<CLICommand, CLIParseError> {
    if args.contains("--all") { return .success(.off(.all)) }
    if let idx = args.firstIndex(of: "--session"), args.indices.contains(idx + 1) {
        return .success(.off(.session(args[idx + 1])))
    }
    return .success(.off(.own))
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
