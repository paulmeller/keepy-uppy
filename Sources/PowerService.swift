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
}
