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
            // 0 MUST stay out of range. The setter above writes a real
            // `Optional(0.0)`, not nil, and `SafetyConfigStore.save` persists
            // it verbatim — so a selectable 0 is a persisted
            // `maxSessionDuration` of zero seconds, which
            // `Shared/SafetyEngine.swift` treats as a live limit:
            // `breach(_:)` matches any session with `age >= 0` (i.e. every
            // session, on the very first 5s tick), `evaluate` short-circuits
            // `.maxDuration` straight past the grace period to `.stopAll`, and
            // `recovered(_:_:)`'s `oldestSessionAge < maxSessionDuration` can
            // never be true against 0 — so `triggersSuppressed` latches
            // permanently and all trigger automation dies silently.
            //
            // This was harmless while the daemon could not see Safety Settings
            // at all; widening the range to 0...24 (final whole-branch review,
            // Item 6, to match the getter's nil -> 0 display mapping) and
            // teaching the daemon to honour the live config landed
            // concurrently, and together they made the zero reachable and
            // destructive. 1...24 is the pre-existing safe state.
            //
            // The getter's nil -> 0 mapping stays: with 0 outside the bounds
            // the Stepper clamps to 1 and its own increment/decrement can
            // never land there, so the mapping is purely cosmetic for a config
            // saved elsewhere. Offering a real "No limit" affordance that
            // round-trips back to nil is a known, accepted limitation and
            // deliberately out of scope here.
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
