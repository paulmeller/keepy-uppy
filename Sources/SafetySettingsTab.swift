import SwiftUI

struct SafetySettingsTab: View {
    @State private var config = SafetyConfigStore.load()

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .safety)
            }

            Section {
                SettingsRow(thermalSensitivityExplanation(config.thermalSensitivity)) {
                    Picker("Overheating", selection: $config.thermalSensitivity) {
                        ForEach(ThermalSensitivity.allCases, id: \.self) { level in
                            Text(thermalSensitivityTitle(level)).tag(level)
                        }
                    }
                }

                if config.thermalSensitivity == .off {
                    // The one setting here that removes a protection entirely
                    // rather than moving a threshold, so it says so plainly
                    // instead of being silently equivalent to the others.
                    Label(
                        "Your Mac can overheat unattended with the lid closed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            } header: {
                Text("Thermal")
            }

            Section {
                LabeledContent("Stop below") {
                    Text("\(config.batteryCutoff ?? 0)%")
                        .monospacedDigit()
                    Stepper(
                        value: Binding(
                            get: { config.batteryCutoff ?? 0 },
                            set: { config.batteryCutoff = $0 }
                        ),
                        // 0...50 step 1 deliberately, matching what this pane
                        // has always offered. Narrowing it to 5...50 step 5
                        // read better but made 12% or 18% unreachable, and —
                        // because the getter maps a nil (guard off) to 0,
                        // below a lower bound of 5 — a single click would
                        // have silently turned an off guard on at 5%.
                        in: 0...50
                    ) {
                        // Empty label: the value is drawn beside the stepper
                        // rather than inside it, because a `Stepper`'s own
                        // label sits *before* its arrows and every stepper in
                        // System Settings reads value-then-arrows.
                        EmptyView()
                    }
                    .labelsHidden()
                }

                Toggle("Stop earlier while the lid is closed", isOn: $config.lidClosedStricter)
            } header: {
                Text("Battery")
            } footer: {
                Text(batteryGuardFootnote(config))
                    .settingsFootnote()
            }

            Section {
                SettingsRow("A backstop for a session that was started and forgotten. It spends only time on battery, so a Mac left on mains power is never stopped by it, and plugging in pauses the budget rather than refunding it. It applies to every session, including ones started from the command line.") {
                    LabeledContent("Maximum length") {
                        Text(maxSessionLengthLabel(config))
                            .monospacedDigit()
                        Stepper(
                            value: Binding(
                                get: { Int((config.maxSessionDuration ?? 0) / 3600) },
                                set: { config.maxSessionDuration = TimeInterval($0) * 3600 }
                            // 0 MUST stay out of range. The setter writes a real
                            // `Optional(0.0)`, not nil, and `SafetyConfigStore.save`
                            // persists it verbatim — so a selectable 0 is a
                            // `maxSessionDuration` of zero seconds, which
                            // `Shared/SafetyEngine.swift` treats as a live limit:
                            // `breach(_:)` matches any session with `age >= 0` (every
                            // session, on the first 5s tick), `evaluate` short-circuits
                            // past the grace period straight to `.stopAll`, and
                            // `recovered(_:_:)`'s `oldestSessionAge < maxSessionDuration`
                            // can never be true against 0 — so `triggersSuppressed`
                            // latches permanently and all trigger automation dies
                            // silently.
                            //
                            // Harmless while the daemon could not see Safety Settings
                            // at all; widening this to 0...24 (final whole-branch
                            // review, Item 6) and teaching the daemon to honour the
                            // live config landed concurrently, and together made the
                            // zero reachable and destructive. 1...24 is the
                            // pre-existing safe state.
                            //
                            // The getter's nil -> 0 mapping stays: with 0 outside the
                            // bounds the Stepper clamps and its own increment and
                            // decrement can never land there, so the mapping is purely
                            // cosmetic for a config saved elsewhere. A real "No limit"
                            // affordance that round-trips to nil is a known, accepted
                            // limitation and deliberately out of scope.
                            ),
                            in: 1...24
                        ) {
                            EmptyView()
                        }
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Session Limit")
            }
        }
        .formStyle(.grouped)
        .onChange(of: config) { newValue in
            SafetyConfigStore.save(newValue)
        }
    }
}
