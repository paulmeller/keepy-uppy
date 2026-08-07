import SwiftUI

struct TriggersSettingsTab: View {
    @State private var rules = TriggerStore.load()
    @State private var newConditionKind: NewRuleConditionKind = .appLaunched
    @State private var newBundleID = ""
    @State private var newSessionKind: DefaultSessionKind = .indefinite

    enum NewRuleConditionKind: String, CaseIterable, Identifiable {
        case appLaunched = "App Launched"
        case externalDisplayConnected = "External Display Connected"
        case acPowerConnected = "AC Power Connected"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(rules) { rule in
                    HStack {
                        Toggle("", isOn: binding(for: rule).enabled)
                            .labelsHidden()
                        Text(describe(rule))
                        Spacer()
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                            TriggerStore.save(rules)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Divider()

            HStack {
                Picker("Condition", selection: $newConditionKind) {
                    ForEach(NewRuleConditionKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if newConditionKind == .appLaunched {
                    TextField("Bundle ID (e.g. com.apple.dt.Xcode)", text: $newBundleID)
                }
                Picker("Starts", selection: $newSessionKind) {
                    ForEach(DefaultSessionKind.allCases) { Text($0.label).tag($0) }
                }
                Button("Add") {
                    addRule()
                }
                .disabled(newConditionKind == .appLaunched && newBundleID.isEmpty)
            }
        }
        .padding()
    }

    private func binding(for rule: TriggerRule) -> Binding<TriggerRule> {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return .constant(rule)
        }
        return Binding(
            get: { rules[index] },
            set: { rules[index] = $0; TriggerStore.save(rules) }
        )
    }

    private func addRule() {
        let condition: TriggerCondition
        switch newConditionKind {
        case .appLaunched: condition = .appLaunched(bundleID: newBundleID)
        case .externalDisplayConnected: condition = .externalDisplayConnected
        case .acPowerConnected: condition = .acPowerConnected
        }
        let rule = TriggerRule(id: UUID(), condition: condition,
                               sessionKind: newSessionKind.sessionKind(now: Date()), enabled: true)
        rules.append(rule)
        TriggerStore.save(rules)
        newBundleID = ""
    }

    private func describe(_ rule: TriggerRule) -> String {
        let conditionText: String
        switch rule.condition {
        case .appLaunched(let bundleID): conditionText = "When \(appDisplayName(bundleID: bundleID)) launches"
        case .externalDisplayConnected: conditionText = "When an external display connects"
        case .acPowerConnected: conditionText = "When AC power connects"
        }
        return "\(conditionText) — keep awake \(remainingTimeText(for: previewSession(rule), now: Date()).lowercased())"
    }

    private func previewSession(_ rule: TriggerRule) -> Session {
        Session(id: UUID(), kind: rule.sessionKind, owner: ClientID(rawValue: "preview"),
               persistence: .detached, origin: .trigger, startedAt: Date())
    }
}
