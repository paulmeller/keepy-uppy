import Foundation

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

struct BatteryState: Equatable {
    let percentage: Int?
    let source: PowerSource
}

enum PowerError: Error {
    case commandFailed(Error)
    case nonZeroExit(String)
    case decodingFailed
}

extension PowerError {
    // When the user dismisses the admin-auth dialog, osascript writes
    // "execution error: User canceled. (-128)" to stderr — but the prose is
    // localized on non-English systems, so the stable AppleScript error
    // code (-128) is matched as well.
    var isUserCancelled: Bool {
        if case .nonZeroExit(let message) = self {
            return message.contains("User canceled") || message.contains("-128")
        }
        return false
    }
}

enum PowerService {
    static func parseSleepDisabled(_ output: String) -> SleepState {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "SleepDisabled" else { continue }
            guard parts.count > 1 else { return .unknown }
            switch parts[1] {
            case "1": return .disabled
            case "0": return .enabled
            default: return .unknown
            }
        }
        return .enabled
    }

    static func parseBattery(_ output: String) -> BatteryState {
        let source: PowerSource
        if output.contains("'Battery Power'") {
            source = .battery
        } else if output.contains("'AC Power'") {
            source = .acPower
        } else {
            source = .unknown
        }

        var percentage: Int?
        outer: for line in output.split(separator: "\n") {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let percentIndex = token.firstIndex(of: "%") else { continue }
                let digits = token[token.startIndex..<percentIndex].filter { $0.isNumber }
                if let value = Int(digits) {
                    percentage = value
                    break outer
                }
            }
        }

        return BatteryState(percentage: percentage, source: source)
    }

    static func readSleepState() throws -> SleepState {
        parseSleepDisabled(try run("/usr/bin/pmset", ["-g"]))
    }

    static func readBatteryState() throws -> BatteryState {
        parseBattery(try run("/usr/bin/pmset", ["-g", "batt"]))
    }

    static func setSleepDisabled(_ disabled: Bool) throws {
        let flag = disabled ? "1" : "0"
        let script = "do shell script \"pmset -a disablesleep \(flag)\" with administrator privileges"
        _ = try run("/usr/bin/osascript", ["-e", script])
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PowerError.commandFailed(error)
        }
        // Drain both pipes BEFORE waitUntilExit: waiting first deadlocks if
        // a child ever fills a 64KB pipe buffer. pmset's output is far below
        // that today, but the ordering costs nothing.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            guard let text = String(data: stdoutData, encoding: .utf8) else {
                throw PowerError.decodingFailed
            }
            return text
        } else {
            throw PowerError.nonZeroExit(String(data: stderrData, encoding: .utf8) ?? "")
        }
    }
}
