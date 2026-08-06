import Foundation

enum SleepState: Equatable {
    case disabled
    case enabled
    case unknown
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
}
