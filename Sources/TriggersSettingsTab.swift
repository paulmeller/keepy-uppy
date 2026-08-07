import SwiftUI
import UniformTypeIdentifiers

struct TriggersSettingsTab: View {
    @State private var rules = TriggerStore.load()
    @State private var isAddingRule = false
    @State private var selection: TriggerRule.ID?

    var body: some View {
        VStack(spacing: 0) {
            if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }

            Divider()

            // The classic macOS list-editing footer: add and remove live
            // under the list they act on, rather than the previous layout's
            // inline row that crammed two pickers, a text field and a button
            // onto one line and changed shape as you used it.
            HStack(spacing: 0) {
                Button {
                    isAddingRule = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .help("Add a trigger")

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .disabled(selection == nil)
                .help("Remove the selected trigger")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .sheet(isPresented: $isAddingRule) {
            AddTriggerSheet { rule in
                rules.append(rule)
                TriggerStore.save(rules)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Triggers")
                .font(.title3.weight(.semibold))
            Text("Triggers start a session for you — when an app launches, a display is plugged in, or power is connected.")
                .settingsFootnote()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var ruleList: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                HStack(spacing: 10) {
                    Toggle("", isOn: binding(for: rule).enabled)
                        .labelsHidden()
                        .help(rule.enabled ? "Turn this trigger off" : "Turn this trigger on")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(triggerConditionTitle(rule.condition))
                            .fontWeight(.medium)
                        Text(triggerEffectSubtitle(rule))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // A disabled rule stays legible but visibly inactive,
                    // rather than looking identical to an active one.
                    .opacity(rule.enabled ? 1 : 0.45)

                    Spacer()
                }
                .padding(.vertical, 2)
                .tag(rule.id)
                .contextMenu {
                    Button("Remove", role: .destructive) { remove(rule.id) }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgroundsIfAvailable()
    }

    /// Looks the rule up by id *inside* the closures. Capturing the index
    /// instead crashes: SwiftUI can evaluate an outgoing row's retained
    /// binding after `rules` has already shrunk (row-removal animation), so
    /// `rules[index]` traps on an out-of-range subscript — and this pane now
    /// has two removal paths (minus button, context menu) that reach it.
    private func binding(for rule: TriggerRule) -> Binding<TriggerRule> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id }) ?? rule },
            set: { newValue in
                guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                rules[index] = newValue
                TriggerStore.save(rules)
            }
        )
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: TriggerRule.ID) {
        rules.removeAll { $0.id == id }
        if selection == id { selection = nil }
        TriggerStore.save(rules)
    }
}

// MARK: - Add sheet

/// Adding a rule is a distinct task with its own three decisions, so it gets
/// its own surface. Inline, it had to share a row with the list it was adding
/// to, and the app field appeared and disappeared as the condition changed.
private struct AddTriggerSheet: View {
    enum ConditionKind: String, CaseIterable, Identifiable {
        case appLaunched = "An app launches"
        case externalDisplayConnected = "An external display connects"
        case acPowerConnected = "Power is connected"
        var id: String { rawValue }
    }

    let onAdd: (TriggerRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conditionKind: ConditionKind = .appLaunched
    @State private var bundleID = ""
    @State private var appName = ""
    @State private var sessionKind: DefaultSessionKind = .indefinite
    @State private var pickerError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Trigger")
                .font(.headline)
                .padding([.top, .horizontal], 20)

            Form {
                Picker("When", selection: $conditionKind) {
                    ForEach(ConditionKind.allCases) { Text($0.rawValue).tag($0) }
                }

                if conditionKind == .appLaunched {
                    // Typing a reverse-DNS bundle identifier from memory is a
                    // developer's chore, not a user's. Picking the app gets
                    // the identifier exactly right, and shows a name back.
                    LabeledContent("App") {
                        HStack {
                            Text(appName.isEmpty ? "None chosen" : appName)
                                .foregroundStyle(appName.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { chooseApp() }
                        }
                    }

                    // Picking is the easy path, but it can only offer apps
                    // installed here — this keeps a rule expressible for an
                    // app that isn't (yet).
                    LabeledContent("Bundle ID") {
                        TextField("com.apple.dt.Xcode", text: $bundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onChange(of: bundleID) { _ in pickerError = nil }
                    }

                    if let pickerError {
                        Label(pickerError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                Picker("Keep awake", selection: $sessionKind) {
                    ForEach(DefaultSessionKind.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(TriggerRule(id: UUID(), condition: condition,
                                      defaultKind: sessionKind, enabled: true))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private var isValid: Bool {
        conditionKind != .appLaunched || !bundleID.isEmpty
    }

    private var condition: TriggerCondition {
        switch conditionKind {
        case .appLaunched: return .appLaunched(bundleID: bundleID)
        case .externalDisplayConnected: return .externalDisplayConnected
        case .acPowerConnected: return .acPowerConnected
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app whose running state should keep your Mac awake."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            // Returning silently here left the sheet reading "None chosen"
            // with no explanation of why the pick did nothing.
            pickerError = "\(url.lastPathComponent) doesn't have a bundle identifier, so it can't be used as a trigger."
            return
        }
        pickerError = nil
        bundleID = identifier
        appName = bundle.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

private extension View {
    /// `alternatingRowBackgrounds` is macOS 14+, and this ships back to 13.
    @ViewBuilder
    func alternatingRowBackgroundsIfAvailable() -> some View {
        if #available(macOS 14, *) {
            self.alternatingRowBackgrounds()
        } else {
            self
        }
    }
}
