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

private func parseOn(_ args: [String], now: Date) -> Result<CLICommand, CLIParseError> {
    var endConditions: [SessionKind] = []

    if let forIndex = args.firstIndex(of: "--for"), args.indices.contains(forIndex + 1) {
        switch parseDuration(args[forIndex + 1]) {
        case .success(let interval): endConditions.append(.duration(until: now.addingTimeInterval(interval)))
        case .failure(let error): return .failure(error)
        }
    }
    if let untilIndex = args.firstIndex(of: "--until"), args.indices.contains(untilIndex + 1) {
        guard let date = parseTimeOfDay(args[untilIndex + 1], relativeTo: now) else {
            return .failure(CLIParseError(message: "could not parse --until time '\(args[untilIndex + 1])'"))
        }
        endConditions.append(.untilTime(date))
    }
    if let appIndex = args.firstIndex(of: "--while-app"), args.indices.contains(appIndex + 1) {
        endConditions.append(.whileAppRunning(bundleID: args[appIndex + 1]))
    }
    if let processIndex = args.firstIndex(of: "--while-process"), args.indices.contains(processIndex + 1) {
        endConditions.append(.whileProcessRunning(processName: args[processIndex + 1]))
    }

    guard endConditions.count <= 1 else {
        return .failure(CLIParseError(message: "only one of --for, --until, --while-app, --while-process may be given"))
    }

    switch parseWakeMode(args) {
    case .success(let wakeMode):
        return .success(.on(kind: endConditions.first ?? .indefinite,
                            persistence: .detached, wakeMode: wakeMode))
    case .failure(let error):
        return .failure(error)
    }
}

/// `on`'s second, independent axis: how the session keeps the Mac awake.
///
/// **Absence means `.clamshell`**, and that is load-bearing rather than an
/// arbitrary pick. `.clamshell` is the only mode that survives a lid close
/// (it is the one that sets the global `SleepDisabled`; assertions do not
/// survive a lid close — spec §1), and it is what every `keepy-uppy on`
/// written before these flags existed already got. Any other default would
/// silently weaken every script and every documented invocation.
///
/// Two flags rather than one boolean because `WakeMode` has three cases and a
/// bool can only name two. Two flags rather than a `--wake-mode <name>`
/// option because each flag names exactly what it changes about the display,
/// and because the raw values (`systemAndDisplay`) are camelCase wire strings
/// that have no business being typed at a shell prompt.
///
/// They are mutually exclusive for the same reason `--for` and `--until` are,
/// and the rejection is written the same way: a session holds exactly one
/// `WakeMode`, so asking for two is a contradiction to reject, not a
/// precedence rule to invent. (Two *different* live sessions may hold
/// different modes; unioning those is `PowerPlan.reduce`'s job in the daemon,
/// not something one `on` invocation can express.)
///
/// Worth knowing when reading an invocation: both flags *drop* the clamshell
/// axis, because the mode they select is not `.clamshell`. `--keep-display-awake`
/// therefore keeps the display lit but no longer keeps a lid-shut laptop
/// awake. It reads additive and is not; the README says so out loud.
private func parseWakeMode(_ args: [String]) -> Result<WakeMode, CLIParseError> {
    var modes: [WakeMode] = []
    if args.contains("--display-may-sleep") { modes.append(.system) }
    if args.contains("--keep-display-awake") { modes.append(.systemAndDisplay) }

    guard modes.count <= 1 else {
        return .failure(CLIParseError(
            message: "only one of --display-may-sleep, --keep-display-awake may be given"))
    }
    return .success(modes.first ?? .clamshell)
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
