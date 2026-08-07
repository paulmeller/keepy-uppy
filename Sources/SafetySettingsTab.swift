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
            // 0 is in range because the getter above can produce it: a nil
            // `maxSessionDuration` (guard disabled) reads back as 0, which
            // `in: 1...24` put outside the control's own declared bounds
            // (final whole-branch review, Item 6). Widening the range is the
            // whole fix — the deeper "no way back to nil from this UI" issue
            // is deliberately left alone, pending separate in-progress work
            // on how the daemon reads this config cross-process.
            ), in: 0...24) {
                Text("Max Session Duration: \(Int((config.maxSessionDuration ?? 0) / 3600))h")
            }
        }
        .padding()
        .onChange(of: config) { newValue in
            SafetyConfigStore.save(newValue)
        }
    }
}
