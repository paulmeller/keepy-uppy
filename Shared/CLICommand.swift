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
    case on(kind: SessionKind, persistence: SessionPersistence)
    case off(StopTarget)
    case status(json: Bool)
    case sessions
}

/// Pure: no I/O, no XPC, no process exit — fully testable. `now` is
/// injected so duration parsing can be tested without depending on the
/// wall clock.
func parseCLIArguments(_ args: [String], now: Date = Date()) -> Result<CLICommand, CLIParseError> {
    guard let command = args.first else { return .failure(CLIParseError(message: "usage: keepy-uppy on|off|status|sessions")) }
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
    default:
        return .failure(CLIParseError(message: "unknown command '\(command)'; usage: keepy-uppy on|off|status|sessions"))
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

    guard endConditions.count <= 1 else {
        return .failure(CLIParseError(message: "only one of --for, --until, --while-app may be given"))
    }
    return .success(.on(kind: endConditions.first ?? .indefinite, persistence: .detached))
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
