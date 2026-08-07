import SwiftUI

struct SafetySettingsTab: View {
    @State private var config = SafetyConfigStore.load()

    var body: some View {
        Form {
            Picker("Thermal Sensitivity", selection: $config.thermalSensitivity) {
                ForEach(ThermalSensitivity.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }

            Toggle("Stricter Battery Cutoff While Lid Closed", isOn: $config.lidClosedStricter)

            Stepper(value: Binding(
                get: { config.batteryCutoff ?? 0 },
                set: { config.batteryCutoff = $0 }
            ), in: 0...50) {
                Text("Battery Cutoff: \(config.batteryCutoff ?? 0)%")
            }

            Stepper(value: Binding(
                get: { Int((config.maxSessionDuration ?? 0) / 3600) },
                set: { config.maxSessionDuration = TimeInterval($0) * 3600 }
            ), in: 1...24) {
                Text("Max Session Duration: \(Int((config.maxSessionDuration ?? 0) / 3600))h")
            }
        }
        .padding()
        .onChange(of: config) { newValue in
            SafetyConfigStore.save(newValue)
        }
    }
}
