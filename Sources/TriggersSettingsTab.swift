import SwiftUI
import UniformTypeIdentifiers

struct TriggersSettingsTab: View {
    @State private var rules = TriggerStore.load()
    /// Rules the store is holding on to that this build cannot decode — written
    /// by a newer version, kept verbatim by `TriggerStore.save`, and impossible
    /// to render here because nothing in this build knows what they say. Read
    /// once, like `rules`: only this pane writes the store, so the count cannot
    /// change underneath it.
    @State private var unreadableRuleCount = TriggerStore.loadStored().unreadableCount
    @State private var isAddingRule = false
    @State private var selection: TriggerRule.ID?
    @State private var completionConfig = SessionCompletionStore.load()
    /// Why the last script pick was rejected, or `nil`. Mirrors
    /// `AddTriggerSheet.pickerError` — a picker that silently does nothing is
    /// the same bug in both places.
    @State private var scriptError: String?

    var body: some View {
        VStack(spacing: 0) {
            if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }

            // Below the list and above its editing footer, so it reads as a
            // statement about what the list is not showing. It matters most in
            // the `rules.isEmpty` branch, where the empty state otherwise says
            // "No Triggers" to somebody who has several.
            if let notice = unreadableTriggerNotice(count: unreadableRuleCount) {
                Text(notice)
                    .settingsFootnote()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
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

            Divider()

            completionSection
        }
        .sheet(isPresented: $isAddingRule) {
            AddTriggerSheet { rule in
                rules.append(rule)
                TriggerStore.save(rules)
            }
        }
    }

    /// "On session end": a script and/or a webhook, fired by the Agent
    /// (`Agent/EvidenceLoopRunner.swift`) whenever ANY session ends — not
    /// scoped to trigger-started sessions, matching the plain "on session
    /// end" mental model rather than something narrower. A CLI coding
    /// assistant's own completion hook can also fire this immediately via
    /// `keepy-uppy finished`, independent of the Agent's poll — see the
    /// README's "AI coding-assistant integration" section.
    private var completionSection: some View {
        Form {
            Section {
                LabeledContent("Script") {
                    HStack {
                        Text(completionConfig.scriptPath?.isEmpty == false ? completionConfig.scriptPath! : "None chosen")
                            .foregroundStyle(completionConfig.scriptPath?.isEmpty == false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if completionConfig.scriptPath?.isEmpty == false {
                            Button("Clear") { setScriptPath(nil) }
                        }
                        Button("Choose…") { chooseScript() }
                    }
                }
                if let scriptError {
                    Text(scriptError)
                        .settingsFootnote()
                        .foregroundStyle(.red)
                }
                LabeledContent("Webhook URL") {
                    TextField("https://example.com/hook", text: webhookURLBinding)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("On Session End")
            } footer: {
                Text("Runs the script and/or POSTs to the webhook whenever any keep-awake session ends — manual, timed, trigger-started, or stopped by a safety guard.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }

    private var webhookURLBinding: Binding<String> {
        Binding(
            get: { completionConfig.webhookURL ?? "" },
            set: { newValue in
                completionConfig.webhookURL = newValue.isEmpty ? nil : newValue
                SessionCompletionStore.save(completionConfig)
            }
        )
    }

    private func setScriptPath(_ path: String?) {
        completionConfig.scriptPath = path
        SessionCompletionStore.save(completionConfig)
        scriptError = nil
    }

    /// The panel cannot filter on "is executable" — `allowedContentTypes`
    /// works on UTIs, and a shell script with no extension has none useful —
    /// so the check happens here, on the way out.
    ///
    /// Without it the pick was accepted, saved, and failed much later inside
    /// `Process.run()`. Foundation's message for a mode-644 file was checked
    /// rather than assumed, and it is worse than unhelpful — it is wrong:
    ///
    ///     Error Domain=NSCocoaErrorDomain Code=4
    ///     "The file “notify.sh” doesn’t exist."
    ///
    /// The file is right there; it just isn't `chmod +x`. And that sentence
    /// landed in the Agent's log at some later session end, not in the UI at
    /// the moment of the mistake. Checking here turns it into an accurate
    /// sentence next to the button that caused it.
    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a script to run whenever a session ends."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            scriptError = "\(url.lastPathComponent) isn't executable, so it can't be run. Add the execute permission (chmod +x) and choose it again."
            return
        }
        setScriptPath(url.path)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Triggers")
                .font(.title3.weight(.semibold))
            Text("Triggers start a session for you — when an app launches, a display is plugged in, power is connected, or a process (like a coding-assistant CLI) is running.")
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
    // This sheet used to declare its own `ConditionKind`, a parallel enum whose
    // raw values were the picker labels. Nothing linked it to `TriggerCondition`,
    // so a new condition simply never appeared here — the shape that left three
    // `SessionKind` cases unreachable from every client. It now picks
    // `TriggerConditionKind` directly: `allCases` fills the picker, and the two
    // switches below stop compiling until a new case is handled.

    /// Quick-add shortcuts for the CLI coding-assistant tools this condition
    /// exists for — none of them have a bundle ID, so the app-picker flow
    /// the `.appLaunched` case uses doesn't apply; typing an exact binary
    /// name from memory is the developer's chore this saves. `agent` and
    /// `pi` are generic enough to collide with an unrelated process of the
    /// same name — `warning` is shown when one of those two is selected.
    private static let codingAssistantPresets: [(label: String, processName: String, warning: String?)] = [
        ("Claude Code", "claude", nil),
        ("Codex CLI", "codex", nil),
        ("Pi", "pi", "\"pi\" is a generic process name — this could also match an unrelated tool with the same name."),
        ("Cursor CLI", "agent", "Cursor's CLI installs its binary literally as \"agent\" — a generic name that could also match an unrelated process."),
        ("Antigravity CLI", "agy", nil),
    ]

    let onAdd: (TriggerRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conditionKind: TriggerConditionKind = .appLaunched
    @State private var bundleID = ""
    @State private var appName = ""
    @State private var processName = ""
    @State private var sessionKind: DefaultSessionKind = .indefinite
    @State private var pickerError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Trigger")
                .font(.headline)
                .padding([.top, .horizontal], 20)

            Form {
                Picker("When", selection: $conditionKind) {
                    ForEach(TriggerConditionKind.allCases) {
                        Text(triggerConditionKindLabel($0)).tag($0)
                    }
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

                if conditionKind == .processRunning {
                    LabeledContent("Process name") {
                        TextField("claude", text: $processName)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick add")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(Self.codingAssistantPresets, id: \.processName) { preset in
                                Button(preset.label) { processName = preset.processName }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }

                    // A name the matcher could never match is worth saying so
                    // now, rather than letting the rule sit in the list
                    // looking correct and never firing.
                    if let problem = TriggerCondition.processNameProblem(processName) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    } else if let warning = Self.codingAssistantPresets.first(where: { $0.processName == processName })?.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                // A condition that binds its session's lifetime has no duration
                // to pick — `sessionKind(firing:now:)` would discard whatever
                // was chosen — so the picker is replaced by the sentence saying
                // what will end the session instead. Keyed off the one table
                // rather than off `== .processRunning`, which is what this line
                // and three others used to match on.
                if conditionKind.bindsSessionLifetime {
                    if let footnote = triggerBindingFootnote(condition) {
                        Text(footnote)
                            .settingsFootnote()
                    }
                } else {
                    Picker("Keep awake", selection: $sessionKind) {
                        ForEach(DefaultSessionKind.allCases) { Text($0.label).tag($0) }
                    }
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
        switch conditionKind {
        case .appLaunched: return !bundleID.isEmpty
        case .processRunning:
            return !processName.isEmpty && TriggerCondition.processNameProblem(processName) == nil
        case .externalDisplayConnected, .acPowerConnected: return true
        }
    }

    private var condition: TriggerCondition {
        switch conditionKind {
        case .appLaunched: return .appLaunched(bundleID: bundleID)
        case .externalDisplayConnected: return .externalDisplayConnected
        case .acPowerConnected: return .acPowerConnected
        case .processRunning: return .processRunning(processName: processName)
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
