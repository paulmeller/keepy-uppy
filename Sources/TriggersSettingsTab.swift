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
                SettingsPaneHeader(tab: .triggers)
            }

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
                // Two lines, and the second one is the return half of a
                // two-way signpost: the three ways of being told a session
                // ended now live on two tabs, and General → Notifications
                // points back here. One-directional signposting only helps the
                // reader who happened to start on the right tab.
                VStack(alignment: .leading, spacing: 6) {
                    Text(sessionEndActionsFootnote)
                        .settingsFootnote()
                    Text(sessionEndActionsNotificationsSignpost)
                        .settingsFootnote()
                }
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
            Text("Triggers start a session for you — when an app launches or comes to the front, a display is plugged in, power is connected, a volume is mounted, this Mac joins a network, a VPN connects, a USB device is attached, or a process (like a coding-assistant CLI) is running.")
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
                        // `triggerRuleTitle`, not `triggerConditionTitle`: the
                        // same condition reads as timed under one rule and as
                        // bound under another now that the lifetime is the
                        // rule's to choose, and this row is where a user would
                        // first notice a title promising a stop that will not
                        // come.
                        Text(triggerRuleTitle(rule))
                            .fontWeight(.medium)
                        Text(triggerEffectSubtitle(rule))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // Absent for the request every trigger used to make, so
                        // an ordinary list gains no noise — see
                        // `triggerPowerNote`.
                        if let power = triggerPowerNote(rule.effect.power) {
                            Text(power)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
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
    @State private var volumeName = ""
    /// What is mounted *now*, read once when the sheet is built. It is a
    /// convenience for filling the field in, never a constraint on it — the
    /// rule may name a drive that is not plugged in, which is most of the
    /// reason to write one. `.unavailable` becomes an empty list and a
    /// disabled menu rather than an error: the field still works.
    @State private var mountedVolumeNames: [String] = {
        guard case .names(let names) = MountedVolumeURLsReader().read() else { return [] }
        return names.sorted()
    }()
    @State private var subnetCIDR = ""
    /// A `/24` around each IPv4 address this Mac holds right now, read once
    /// when the sheet is built. `/24` is a suggestion, not a claim — it is
    /// the overwhelmingly common home and office prefix, and the field stays
    /// editable — so each row shows the address it came from, which is the
    /// fact the user can actually check.
    @State private var currentSubnetSuggestions: [(address: String, block: String)] = {
        guard case .addresses(let addresses) = GetifaddrsNetworkAddressReader().read() else { return [] }
        var seen = Set<String>()
        return addresses.sorted().compactMap { address in
            let octets = (0..<4).map { (address >> (24 - 8 * $0)) & 0xFF }
            let block = "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
            // Deduplicated because a docked laptop with Wi-Fi *and* Ethernet
            // on the same LAN is the ordinary case, not an exotic one: both
            // addresses suggest the identical block, which would be two rows
            // saying the same thing — and a duplicate `ForEach` id.
            guard seen.insert(block).inserted else { return nil }
            return (address: octets.map(String.init).joined(separator: "."), block: block)
        }
    }()
    @State private var usbDeviceText = ""
    /// The schedule being built. Seeded with the weekday nine-to-six the
    /// picker's own label promises, so the sheet opens on a rule that is
    /// already valid rather than one whose Add button is disabled until a day
    /// is ticked.
    @State private var scheduleDayMask: UInt8 = TriggerSchedule.weekdays
    @State private var scheduleStart = 9 * 60
    @State private var scheduleEnd = 18 * 60
    /// What is plugged in *now*, read once when the sheet is built — the
    /// `mountedVolumeNames` bargain exactly: a convenience for filling the field
    /// in, never a constraint on it, because a rule naming a dongle that is not
    /// plugged in yet is most of the reason to write one.
    ///
    /// Sorted by name so the menu is stable between openings; devices that
    /// report no name sort last under their identifiers, which is also what they
    /// are shown as. `.unavailable` becomes an empty list and a disabled menu
    /// rather than an error, so the field still works.
    @State private var attachedUSBDevices: [AttachedUSBDevice] = {
        guard case .attached(let devices) = IOKitUSBDeviceReader().read() else { return [] }
        return devices.sorted {
            ($0.name ?? "\u{10FFFF}\($0.id.text)") < ($1.name ?? "\u{10FFFF}\($1.id.text)")
        }
    }()
    @State private var sessionKind: DefaultSessionKind = .indefinite
    /// The lifetime **only if the user picked one**, so that "untouched" is a
    /// state this sheet can represent rather than a value it has to guess.
    ///
    /// A plain `@State private var lifetime: TriggerLifetime = .forDuration`
    /// would be a second copy of the condition's default sitting next to
    /// `conditionKind`'s initial value, free to drift from it the day either
    /// changes — and drift here is not cosmetic: a sheet nobody touched must
    /// save `TriggerEffect.default(for:)` exactly, because that is what keeps the
    /// rule on the pre-Task-10 wire shape and out of reach of an older build's
    /// undecodable path. See `TriggerRule`'s doc comment.
    ///
    /// Cleared whenever the condition changes, so the picker visibly returns to
    /// the new condition's own answer instead of silently carrying an override
    /// from a condition the user has moved on from.
    @State private var chosenLifetime: TriggerLifetime?
    @State private var wakeMode = TriggerEffect.defaultPower.wakeMode
    @State private var keepsDisksAwake = TriggerEffect.defaultPower.keepsDisksAwake
    @State private var pickerError: String?

    private var lifetime: TriggerLifetime {
        chosenLifetime ?? TriggerEffect.defaultLifetime(for: conditionKind)
    }

    /// What the Add button will store. One expression, read by the button and by
    /// nothing else, so the sheet cannot save a different effect from the one it
    /// has been describing.
    private var effect: TriggerEffect {
        TriggerEffect.chosen(power: PowerRequest(wakeMode: wakeMode,
                                                 keepsDisksAwake: keepsDisksAwake),
                             lifetime: lifetime, for: condition)
    }

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

                if inputField == .app {
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

                if inputField == .process {
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

                if inputField == .volume {
                    LabeledContent("Volume") {
                        HStack {
                            TextField("Backup", text: $volumeName)
                                .textFieldStyle(.roundedBorder)
                            // The `chooseApp()` bargain, in the shape a volume
                            // allows: pick from what is actually mounted, but
                            // leave the field editable, because the whole point
                            // of this trigger is a drive that is *not* plugged
                            // in yet.
                            Menu("Mounted…") {
                                ForEach(mountedVolumeNames, id: \.self) { name in
                                    Button(name) { volumeName = name }
                                }
                            }
                            .fixedSize()
                            .disabled(mountedVolumeNames.isEmpty)
                        }
                    }
                    Text("Use the name as it appears in Finder. A mount path (/Volumes/Backup) can't be used: the same disk mounts at a different path when another volume already has that name.")
                        .settingsFootnote()
                }

                if inputField == .subnet {
                    LabeledContent("Network") {
                        HStack {
                            TextField("192.168.1.0/24", text: $subnetCIDR)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                            // The same bargain again: the arithmetic of "what
                            // block am I on" is the part a person should not
                            // have to do, but the field stays editable because
                            // the whole point may be a network they are not on
                            // right now.
                            Menu("This Mac…") {
                                ForEach(currentSubnetSuggestions, id: \.block) { suggestion in
                                    Button("\(suggestion.block)  (this Mac is \(suggestion.address))") {
                                        subnetCIDR = suggestion.block
                                    }
                                }
                            }
                            .fixedSize()
                            .disabled(currentSubnetSuggestions.isEmpty)
                        }
                    }

                    // Under the field, not above it: the field is what the user
                    // came to fill in, and this explains the shape it wants.
                    // It is here at all because there is no Wi-Fi SSID row in
                    // the picker for somebody to find — see
                    // `subnetCoversWiFiNote`, which carries the whole reason.
                    Text(subnetCoversWiFiNote)
                        .settingsFootnote()

                    // A block that can never match is worth saying now rather
                    // than letting the rule sit in the list looking correct —
                    // the `.processRunning` argument, and here it also carries
                    // the one limitation a user cannot see: IPv4 only.
                    if let problem = TriggerCondition.subnetProblem(subnetCIDR) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                if inputField == .schedule {
                    LabeledContent("Days") {
                        // Seven toggles rather than a multi-select list: the
                        // whole set is seven items, they are always the same
                        // seven, and a row of them is read at a glance where a
                        // list has to be opened. The symbols come from the
                        // calendar so a non-English Mac is not shown "Mon".
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { day in
                                Toggle(scheduleDayInitial(day),
                                       isOn: scheduleDayBinding(day))
                                    .toggleStyle(.button)
                                    .help(Calendar.current.weekdaySymbols[day])
                            }
                        }
                    }

                    LabeledContent("From") { scheduleTimePicker($scheduleStart) }
                    LabeledContent("Until") {
                        HStack {
                            if scheduleEnd == TriggerSchedule.minutesPerDay {
                                // A `DatePicker` cannot represent midnight-at-
                                // the-end-of-the-day: it edits a wall-clock
                                // time, and 24:00 is not one — it is an
                                // exclusive bound. Showing the picker here
                                // would silently round the value down to 23:59
                                // and reintroduce the one-minute nightly gap
                                // this control exists to avoid, so the whole-
                                // day case is a label instead.
                                Text("Midnight (end of day)")
                                    .foregroundStyle(.secondary)
                            } else {
                                scheduleTimePicker($scheduleEnd)
                            }
                            Spacer()
                            Toggle("All day", isOn: Binding(
                                get: { scheduleStart == 0
                                    && scheduleEnd == TriggerSchedule.minutesPerDay },
                                set: { isOn in
                                    if isOn {
                                        scheduleStart = 0
                                        scheduleEnd = TriggerSchedule.minutesPerDay
                                    } else {
                                        scheduleEnd = 18 * 60
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }

                    // Said before it can surprise anyone: an end earlier than
                    // the start is not an error here, it is the way to write a
                    // window that runs through midnight, and the rule it makes
                    // belongs to the day it opens on.
                    if scheduleEnd < scheduleStart {
                        Text("This window runs overnight — it opens on the days you ticked "
                             + "and closes the next morning.")
                            .settingsFootnote()
                    }

                    if let problem = TriggerSchedule.problem(dayMask: scheduleDayMask,
                                                             startMinute: scheduleStart,
                                                             endMinute: scheduleEnd) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                if inputField == .usbDevice {
                    LabeledContent("Device") {
                        HStack {
                            TextField("05ac:024f", text: $usbDeviceText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                            // The third outing for the same bargain: pick from
                            // what is actually attached, but leave the field
                            // editable, because the point of this trigger is a
                            // device that is not plugged in *yet*.
                            Menu("Attached…") {
                                ForEach(attachedUSBDevices, id: \.id) { device in
                                    Button(device.name ?? device.id.text) {
                                        usbDeviceText = device.id.text
                                    }
                                }
                            }
                            .fixedSize()
                            .disabled(attachedUSBDevices.isEmpty)
                        }
                    }
                    Text("Matched on the device's vendor and product ID, not its name: names are neither unique nor stable, and two identical dongles share one. Pick from “Attached…” rather than typing — the IDs are hexadecimal.")
                        .settingsFootnote()

                    if let problem = TriggerCondition.usbDeviceProblem(usbDeviceText) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                // The VPN condition has no field to fill in, so this footnote is
                // the only place its one limitation can be said at the moment the
                // rule is being written. A rule that looks correct and never
                // fires is the failure being headed off.
                if conditionKind == .vpnActive {
                    Text(vpnDetectionLimitationNote)
                        .settingsFootnote()
                }

                // Until Plan 8 Task 10 this was not a choice: a condition that
                // bound its session's lifetime simply had its duration picker
                // *replaced* by the sentence saying what would end the session
                // instead. It is now a real choice wherever binding is possible
                // at all, and the sentence moves under the option it describes.
                //
                // Both predicates are functions in `Sources/SessionDisplay.swift`
                // rather than expressions here, because a `body` is not testable
                // and "the duration picker is hidden for a rule that will run for
                // a duration" is exactly the bug nobody would see.
                if triggerLifetimeChoiceIsOffered(condition) {
                    Picker(triggerLifetimeTitle, selection: lifetimeBinding) {
                        ForEach(TriggerLifetime.allCases, id: \.self) {
                            Text(triggerLifetimeOptionLabel($0)).tag($0)
                        }
                    }
                }

                if triggerDurationPickerIsShown(chosen: lifetime, for: condition) {
                    Picker(triggerDurationTitle, selection: $sessionKind) {
                        ForEach(DefaultSessionKind.allCases) { Text($0.label).tag($0) }
                    }
                } else if let footnote = triggerBindingFootnote(condition) {
                    Text(footnote)
                        .settingsFootnote()
                }

                // The power request, reusing the Display pane's words for the
                // same three modes and the same toggle. A second set of words
                // here is how that pane and this sheet come to describe them
                // differently.
                Picker(wakeModePickerTitle, selection: $wakeMode) {
                    ForEach(wakeModeSettingsOrder, id: \.self) { mode in
                        Text(wakeModeSettingsTitle(mode)).tag(mode)
                    }
                }
                Text(wakeModeSettingsExplanation(wakeMode))
                    .settingsFootnote()

                Toggle(keepDisksAwakeSettingsTitle, isOn: $keepsDisksAwake)
                // Only once it is on, which is the one difference from the
                // Display pane's arrangement and is a layout decision, not an
                // editorial one: this sheet already carries up to three
                // condition footnotes plus the wake-mode explanation, and that
                // paragraph is the longest string in the window. It says what
                // the toggle *cannot* promise — system-wide, not your drive,
                // and no answer to an enclosure's own firmware — which is
                // exactly the sentence somebody who has just switched it on
                // needs and somebody who left it off does not.
                if keepsDisksAwake {
                    Text(keepDisksAwakeSettingsFootnote)
                        .settingsFootnote()
                }
            }
            .formStyle(.grouped)
            // Clears the lifetime override rather than recomputing it, so the
            // picker returns to whatever the *new* condition's own answer is.
            .onChange(of: conditionKind) { _ in chosenLifetime = nil }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(TriggerRule(id: UUID(), condition: condition,
                                      defaultKind: sessionKind, enabled: true,
                                      effect: effect))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private var lifetimeBinding: Binding<TriggerLifetime> {
        Binding(get: { lifetime }, set: { chosenLifetime = $0 })
    }

    /// Which input a condition needs filling in, so the sheet shows exactly
    /// that one.
    ///
    /// An exhaustive `switch` rather than the chain of `conditionKind == …`
    /// this replaced, for the reason `TriggerConditionKind.bindsSessionLifetime`
    /// is one: a new condition must *state* which field it wants. A chain of
    /// equality tests answers "none" on its author's behalf, silently, and the
    /// result is a sheet whose Add button is enabled with nothing filled in.
    private enum InputField { case app, process, volume, subnet, usbDevice, schedule, none }

    /// One letter per day, from the calendar rather than a literal, so a
    /// non-English Mac gets its own initials. `veryShortWeekdaySymbols` is
    /// already one character in every locale that has such a thing.
    private func scheduleDayInitial(_ day: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return day < symbols.count ? symbols[day] : "?"
    }

    private func scheduleDayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { scheduleDayMask & (1 << UInt8(day)) != 0 },
            set: { isOn in
                if isOn { scheduleDayMask |= (1 << UInt8(day)) }
                else { scheduleDayMask &= ~(1 << UInt8(day)) }
            }
        )
    }

    /// A `DatePicker` over a minutes-since-midnight `Int`.
    ///
    /// The stored value is an `Int` rather than a `Date` because a schedule has
    /// no date — see `TriggerSchedule` for why the comparison is on wall-clock
    /// components — but the only good macOS control for picking a time takes a
    /// `Date`. This is the adapter, and it pins the date part to a fixed day so
    /// nothing about *which* day can leak into the value.
    private func scheduleTimePicker(_ minutes: Binding<Int>) -> some View {
        DatePicker("", selection: Binding(
            get: {
                var parts = DateComponents()
                parts.year = 2000; parts.month = 1; parts.day = 1
                parts.hour = minutes.wrappedValue / 60
                parts.minute = minutes.wrappedValue % 60
                return Calendar.current.date(from: parts) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
    }

    private var inputField: InputField {
        switch conditionKind {
        // Both app conditions name an app by bundle identifier and are picked
        // the same way; `.appFrontmost` is a stronger question about the same
        // subject, not a different one.
        case .appLaunched, .appFrontmost: return .app
        case .processRunning: return .process
        case .volumeMounted: return .volume
        case .onSubnet: return .subnet
        case .usbDevicePresent: return .usbDevice
        case .onSchedule: return .schedule
        // `.vpnActive` names no tunnel — see `VPNObserving` — so there is
        // nothing to fill in, exactly like the display and power conditions.
        case .externalDisplayConnected, .acPowerConnected, .vpnActive: return .none
        }
    }

    private var isValid: Bool {
        switch conditionKind {
        case .appLaunched, .appFrontmost: return !bundleID.isEmpty
        case .processRunning:
            return !processName.isEmpty && TriggerCondition.processNameProblem(processName) == nil
        case .volumeMounted: return !volumeName.isEmpty
        case .onSubnet:
            return !subnetCIDR.isEmpty && TriggerCondition.subnetProblem(subnetCIDR) == nil
        case .usbDevicePresent:
            return !usbDeviceText.isEmpty && TriggerCondition.usbDeviceProblem(usbDeviceText) == nil
        case .onSchedule:
            return TriggerSchedule.problem(dayMask: scheduleDayMask,
                                           startMinute: scheduleStart,
                                           endMinute: scheduleEnd) == nil
        case .externalDisplayConnected, .acPowerConnected, .vpnActive: return true
        }
    }

    private var condition: TriggerCondition {
        switch conditionKind {
        case .appLaunched: return .appLaunched(bundleID: bundleID)
        case .externalDisplayConnected: return .externalDisplayConnected
        case .acPowerConnected: return .acPowerConnected
        case .processRunning: return .processRunning(processName: processName)
        case .appFrontmost: return .appFrontmost(bundleID: bundleID)
        case .volumeMounted: return .volumeMounted(name: volumeName)
        case .onSubnet: return .onSubnet(cidr: subnetCIDR)
        case .vpnActive: return .vpnActive
        case .usbDevicePresent:
            // The Add button is disabled unless this parses, so the fallback is
            // unreachable from the keyboard; it is here because `condition` is
            // also read to build the binding footnote while the field is still
            // half-typed, and that footnote names no device.
            let device = USBDeviceID(text: usbDeviceText) ?? USBDeviceID(vendorID: 0, productID: 0)
            return .usbDevicePresent(vendorID: device.vendorID, productID: device.productID)
        case .onSchedule:
            return .onSchedule(TriggerSchedule(dayMask: scheduleDayMask,
                                               startMinute: scheduleStart,
                                               endMinute: scheduleEnd))
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // Deliberately not "whose running state…": the same picker now serves
        // `.appFrontmost`, where the fact being watched is which app is in
        // front rather than whether it is running at all.
        panel.message = "Choose the app this trigger should watch."
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
