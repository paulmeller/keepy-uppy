import SwiftUI

/// Sizing follows the macOS settings convention: one width for every tab so
/// switching tabs doesn't resize the window sideways, and a minimum height
/// that fits the tallest pane. Panes scroll rather than clip if a future one
/// outgrows it.
private enum SettingsMetrics {
    /// The *detail* column. It is the width the five panes were laid out
    /// against as tabs, kept unchanged so no pane has to be re-checked.
    static let detailWidth: CGFloat = 560
    static let minHeight: CGFloat = 460
}

/// Deliberately observes nothing. It held an `@ObservedObject
/// DaemonConnection` it never read, so each 3s poll republished, re-evaluated
/// this body, and re-ran every tab's `@State` default expression — an
/// `SMAppService` status query and two UserDefaults reads with JSON decodes —
/// twenty times a minute, all discarded. Tabs own their own state.
///
/// **The connection came back in Task 10 and the rule did not change.** It is a
/// plain `let` below, not an `@ObservedObject`: a stored reference is inert,
/// and passing it on costs nothing. `AdvancedSettingsTab` — the one tab that
/// reads it — takes it the same way and subscribes to the single publisher it
/// needs through `.onReceive`, which delivers to a closure instead of
/// invalidating a view. Restoring `@ObservedObject` on either declaration
/// reinstates the exact cost described above.
struct SettingsView: View {
    /// `AdvancedSettingsTab` shows why a hot key failed to register, which only
    /// the centre that tried to register it knows — see the doc comment there
    /// for what a second instance would do.
    @ObservedObject var hotKeys: HotKeyCenter

    /// Stored rather than `@State`, so reopening Settings returns you to the
    /// pane you were last in. macOS settings windows are expected to do this,
    /// and the old `@State` reset to General on every open — which is worst
    /// exactly where it is most annoying, on the deep panes somebody is
    /// iterating on.
    @AppStorage("settingsSelectedTab", store: PreferencesSuite.defaults)
    private var selectedTabRaw: String = SettingsTab.general.rawValue
    @State private var searchQuery = ""

    /// Falls back rather than trapping on a value written by a newer build or
    /// edited by hand, exactly like every other raw-value reader here.
    private var selectedTab: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: selectedTabRaw) ?? .general },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    /// Honours the system's sidebar size, which most apps ignore. The numbers
    /// are Ice's — the open-source menu bar app whose settings window is the
    /// one people point at — because they are already tuned against the same
    /// control the OS offers.
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    private var sidebarWidth: CGFloat {
        switch sidebarRowSize {
        case .small: 190
        case .medium: 210
        case .large: 230
        @unknown default: 210
        }
    }

    private var sidebarItemHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 26
        case .medium: 32
        case .large: 34
        @unknown default: 32
        }
    }

    private var sidebarItemFontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 13
        case .medium: 15
        case .large: 16
        @unknown default: 15
        }
    }

    /// Passed straight through to the same tab, whose Diagnostics section asks
    /// it for the daemon's version. It has to be the app's one connection: a
    /// second `DaemonConnection` made here would open its own privileged XPC
    /// connection, poll it forever, and report on the health of something no
    /// other part of the app is using.
    let daemon: DaemonConnection

    /// The window rules a settings window is expected to follow, and which
    /// SwiftUI does not apply on its own.
    ///
    /// **Close only.** A settings window is not a document: it cannot be
    /// minimised to the Dock and there is nothing to zoom to full screen, so
    /// both buttons are disabled rather than left live and doing something
    /// nobody wants. macOS keeps drawing them, greyed, which is the intended
    /// appearance.
    ///
    /// **Escape closes it**, alongside the ⌘W the Settings scene already
    /// provides — a modeless window whose changes are already saved should be
    /// dismissible with the key people press to dismiss things.
    ///
    /// Done in `onAppear` rather than at construction because there is no
    /// `NSWindow` until SwiftUI has put the view in one.
    @MainActor
    private func configureSettingsWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("Settings") == true || $0.isKeyWindow
        }) else { return }
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // **`.unified`, and this is what puts the toolbar right.**
        //
        // A Settings scene defaults to a preference-style toolbar: a tall band
        // with its title centred and items stacked beneath it. That shape was
        // built for the row of centred tab icons this window used to have, and
        // with a sidebar it leaves a deep empty stripe above both columns and
        // strands the back/forward buttons floating in the middle of it.
        //
        // Unified is the shape System Settings uses: one row, title at the
        // leading edge, items beside it, and no reserved height for icons that
        // are not there any more.
        window.toolbarStyle = .unified
        // Not `.fullScreenPrimary`: a settings window has no full-screen mode
        // worth offering, and leaving the collection behaviour alone is what
        // puts a live green button back on some macOS versions.
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
    }

    private var searchResults: [SettingsIndexEntry] { searchSettings(searchQuery) }

    // MARK: - Pane history, for the toolbar's back and forward buttons
    //
    // System Settings puts a pair of chevrons at the leading edge of its
    // toolbar, and they walk the panes you have *visited* rather than any
    // hierarchy — which is why they are meaningful here even though these five
    // panes are flat and none contains another.
    //
    // Not persisted, deliberately: the selected pane is remembered across
    // launches because returning to what you were editing is useful, but a
    // *trail* through panes from a previous session is not something anybody
    // wants to walk back through, and restoring one would make the back button
    // do something inexplicable on the first click after opening the app.

    @State private var history: [SettingsTab] = []
    @State private var historyIndex = -1
    /// Set while a chevron is driving the selection, so the resulting change
    /// is not recorded as a new visit — otherwise going back would append the
    /// pane you just left and the forward button would never enable.
    @State private var navigatingHistory = false

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    private func recordVisit(_ tab: SettingsTab) {
        if navigatingHistory {
            navigatingHistory = false
            return
        }
        if historyIndex >= 0, history.indices.contains(historyIndex),
           history[historyIndex] == tab {
            return
        }
        // Everything ahead of here is discarded, exactly as a browser does: you
        // have taken a different branch, and the old forward trail is no longer
        // somewhere you were.
        history = Array(history.prefix(historyIndex + 1))
        history.append(tab)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigatingHistory = true
        selectedTab.wrappedValue = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigatingHistory = true
        selectedTab.wrappedValue = history[historyIndex]
    }

    @ViewBuilder
    private func sidebarRow(for tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
                .font(.system(size: sidebarItemFontSize))
                .padding(.leading, 2)
        } icon: {
            SettingsTabIcon(tab: tab)
        }
        .frame(height: sidebarItemHeight)
        .tag(tab)
    }

    var body: some View {
        // Five tabs, in the order a new user meets them: what the app does on
        // its own (General), what starts a session without you (Triggers), what
        // a session holds awake (Display), what stops one (Safety & Guards),
        // and what you only go looking for (CLI & Advanced).
        //
        // Every symbol here is checked available at this project's 13.0
        // deployment target rather than assumed — an unavailable SF Symbol
        // renders as nothing at all, with no warning and no crash, which in a
        // tab bar is an unlabelled blank where a tab should be. Verified
        // against CoreGlyphs' `name_availability.plist`: bolt and
        // exclamationmark.shield are 2019 (macOS 10.15), gearshape, display and
        // terminal are 2020 (macOS 11.0).
        // The tabs are `selection`-bound now, which they were not, because
        // search has to be able to *go* somewhere: a result that names a tab
        // and cannot open it is a worse answer than no result.
        NavigationSplitView {
            // **No VStack wrapping the List, and no hand-built search field.**
            //
            // Both were here and both were wrong on macOS 26. A stack that owns
            // the whole column ignores the sidebar's top safe area, so its
            // first row slid under the traffic lights; and the sidebar is
            // handed floating Liquid Glass by the system, which the guidance is
            // explicit you should not paint over. `.searchable` is placed,
            // inset and materialised by SwiftUI, which is the only way those
            // stay right across appearances and OS versions.
            List(selection: selectedTab) {
                if searchResults.isEmpty {
                    Section {
                        ForEach(SettingsTab.allCases) { tab in
                            sidebarRow(for: tab)
                        }
                    }
                    .collapsible(false)
                } else {
                    // Searching replaces the five panes with what matched, the
                    // way System Settings does, rather than dropping a menu
                    // over them. The row still names its pane, because "which
                    // tab is this in" is most of what a settings search is for.
                    Section("Results") {
                        ForEach(searchResults, id: \.title) { entry in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(.system(size: sidebarItemFontSize))
                                    Text(entry.tab.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            } icon: {
                                SettingsTabIcon(tab: entry.tab)
                            }
                            .tag(entry.tab)
                        }
                    }
                    .collapsible(false)
                }
            }
            .scrollDisabled(searchResults.isEmpty)
            .removeSidebarToggle()
            .navigationSplitViewColumnWidth(sidebarWidth)
        } detail: {
            Group {
                switch selectedTab.wrappedValue {
                case .general: GeneralSettingsTab()
                case .triggers: TriggersSettingsTab()
                case .display: DisplaySettingsTab()
                case .safety: SafetySettingsTab()
                case .advanced: AdvancedSettingsTab(hotKeys: hotKeys, daemon: daemon)
                }
            }
            // A floor, not a fixed width. The panes were laid out against this
            // as tabs and must never be squeezed below it; letting them use a
            // little more when the window is wider costs nothing, and pinning
            // them exactly would leave dead space beside a resizable window.
            .frame(minWidth: SettingsMetrics.detailWidth)
        }
        .navigationTitle(selectedTab.wrappedValue.title)
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")
        .toolbar {
            // `.navigation` puts them at the leading edge, ahead of the title,
            // which is where System Settings has them and the only placement
            // that reads as navigation rather than as an action.
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!canGoBack)
                .help("Back")

                Button(action: goForward) {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!canGoForward)
                .help("Forward")
            }
        }
        .onChange(of: selectedTab.wrappedValue) { tab in
            recordVisit(tab)
        }
        .frame(minHeight: SettingsMetrics.minHeight)
        .onAppear {
            // An LSUIElement app owns no menu bar and is never "frontmost" by
            // default, so its Settings window opens behind whatever the user
            // was doing unless it asks for activation explicitly (spec §9).
            NSApp.activate(ignoringOtherApps: true)
            configureSettingsWindow()
            // Seeds the trail with wherever the window opened, so the first
            // pane you click has somewhere to go back to.
            if history.isEmpty { recordVisit(selectedTab.wrappedValue) }
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @StateObject private var onboarding = OnboardingService()
    @State private var launchAtLoginEnabled = LoginItemService.status() == .enabled
    @AppStorage(DefaultSessionKindPreference.key, store: PreferencesSuite.defaults)
    private var defaultKindRaw: String = DefaultSessionKindPreference.defaultRawValue
    /// Both keys and both starting values come from
    /// `SessionNotificationPreference`, never from literals here: the notifier
    /// reads them back in a different file that never calls this one, and a
    /// typo in either place is not a compile error and not a crash — it is a
    /// toggle that appears to work while nothing is ever posted.
    @AppStorage(SessionNotificationPreference.stopKey, store: PreferencesSuite.defaults)
    private var notifyWhenStopped: Bool = SessionNotificationPreference.fallback
    @AppStorage(SessionNotificationPreference.triggerStartKey, store: PreferencesSuite.defaults)
    private var notifyWhenTriggerStarts: Bool = SessionNotificationPreference.fallback
    @AppStorage(SessionNotificationPreference.safetyStopKey, store: PreferencesSuite.defaults)
    private var notifyWhenASafetyGuardStops: Bool = SessionNotificationPreference.fallback
    /// What macOS last said about the grant. Read only while a toggle is on —
    /// see `refreshAuthorization()`.
    @State private var authorization: NotificationAuthorization = .notDetermined

    var body: some View {
        Form {
            Section {
                SettingsRow("Opens Keepy Uppy in the menu bar when you log in. The background services below run regardless.") {
                    Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                        .onChange(of: launchAtLoginEnabled) { enabled in
                            try? enabled ? LoginItemService.register() : LoginItemService.unregister()
                        }
                }
            }

            Section {
                SettingsRow("Listed first in the menu's Start menu, so the session you use most is one click away.") {
                    Picker("Default session", selection: $defaultKindRaw) {
                        ForEach(DefaultSessionKind.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                }
            } footer: {
                Text("")
                    .settingsFootnote()
            }

            // NOTHING SITS IN THIS GAP ANY MORE, and the note is about the gap
            // rather than about the section below it. The "Keeps this Mac
            // awake" picker and the "Keep attached disks awake" toggle used to
            // be here, in that order, directly under "Default session" — Plan 4
            // put the picker here because the two answer the same question
            // about the same thing, and Plan 6 put the toggle immediately
            // beneath the picker for the same reason. Plan 7 moved the pair,
            // together and in that order, to `Sources/DisplaySettingsTab.swift`,
            // where the argument is written out in full. Nothing about it was
            // withdrawn: "Default session" says *when* a session ends and those
            // two say *what* it holds awake, and once there was a tab for the
            // second question the pair belonged in it rather than in a General
            // tab that is otherwise about the app rather than about a session.

            // Notifications are in General rather than in Triggers because they
            // are something the *app* does, like launching at login and like
            // running the background services below — not something that starts
            // or ends a session. The other two ways of being told a session
            // ended (a script, a webhook) are in Triggers, and the footers point
            // at each other in both directions rather than leaving the split to
            // be discovered.
            Section {
                Toggle(notifyWhenStoppedTitle, isOn: $notifyWhenStopped)
                    .onChange(of: notifyWhenStopped) { on in askOrRefresh(turnedOn: on) }
                Toggle(notifyWhenTriggerStartsTitle, isOn: $notifyWhenTriggerStarts)
                    .onChange(of: notifyWhenTriggerStarts) { on in askOrRefresh(turnedOn: on) }

                // Directly under the stop toggle, because it refines that one
                // rather than standing beside it: with both on you get the
                // reason when there is one and the plain notice when there is
                // not. Its own footnote is attached to the row instead of going
                // in the section footer, so the sentence about a reason not
                // always being available sits against the control it qualifies.
                Toggle(notifyWhenSafetyGuardStopsTitle, isOn: $notifyWhenASafetyGuardStops)
                    .onChange(of: notifyWhenASafetyGuardStops) { on in askOrRefresh(turnedOn: on) }
                Text(notifyWhenSafetyGuardStopsFootnote)
                    .settingsFootnote()

                // Present only when there is something wrong to report, which
                // is the opposite of the "always present rather than appearing
                // only when something is wrong" rule the Background Services
                // button below follows — and deliberately. That button is an
                // action the pane always offers; this is a *fault report*, and
                // a permanently-visible one on a working grant is a nag about
                // a permission the user already gave.
                if let note = notificationStatusNote(
                    state: authorization,
                    anyToggleOn: anyNotificationToggleOn) {
                    Text(note.sentence)
                        .settingsFootnote()
                    if note.offersSystemSettings {
                        HStack {
                            Spacer()
                            Button("Open System Settings") { openNotificationSettings() }
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notificationsSectionFootnote)
                        .settingsFootnote()
                    Text(notificationsTriggersSignpost)
                        .settingsFootnote()
                }
            }

            Section {
                LabeledContent("Status") {
                    ServiceStatusBadge(state: onboarding.state)
                }

                // Always present rather than appearing only when something is
                // wrong: a control that materialises mid-layout shifts
                // everything below it, and a permanently-visible disabled
                // button also tells the reader this pane is where you'd fix it.
                // Shown only before the daemon is running, which is the only
                // moment it is load-bearing: it is the answer to "why does this
                // want an administrator", and it has to be on screen *before*
                // the button is pressed rather than in a README nobody opens
                // while a password prompt is waiting. Once running, the reader
                // has already made the decision and the pane goes back to being
                // a status pane.
                if onboarding.state != .running {
                    Text(privilegeBoundaryExplanation())
                        .settingsFootnote()
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button(onboarding.state == .running ? "Running" : "Enable Keepy Uppy…") {
                        onboarding.enable()
                    }
                    .disabled(onboarding.state == .running)
                }
            } header: {
                Text("Background Services")
            } footer: {
                Text(backgroundServicesFootnote(onboarding.state))
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            onboarding.refresh()
            refreshAuthorization()
        }
        // **The grant is macOS's, and it changes while this pane is on screen.**
        // The fault report above offers an "Open System Settings" button; taking
        // it deactivates the app and leaves this window exactly where it was, so
        // granting the permission over there and switching back fires no
        // `onAppear` and the pane goes on saying macOS is blocking notifications
        // about a grant that now exists. Same shape, same fix, as the CLI pane's
        // trip to Terminal (`AdvancedSettingsTab`) — and here it is the flow the
        // pane itself invited.
        //
        // Unconditional, unlike that pane's `refreshIfChanged`: this re-read
        // starts an async query and assigns one `@State` enum, with nothing
        // half-typed to clobber, and it is still gated on a toggle being on so
        // becoming active with both off touches UserNotifications not at all.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAuthorization()
            }
    }

    /// **The only place in this project that asks for the notification grant,
    /// and it is reached only by a user switching a toggle on.** Not at launch,
    /// not on a timer, not from the notifier. Spec §4: ask lazily, at first
    /// use. A user who never turns one of these on is never asked anything,
    /// which is what keeps the README's claim about permissions true.
    ///
    /// Switching one *off* asks for nothing and revokes nothing — the grant is
    /// macOS's, not this app's — so it only re-reads, because the other toggle
    /// may still be on and its fault report has to stay accurate.
    private func askOrRefresh(turnedOn: Bool) {
        guard turnedOn else { return refreshAuthorization() }
        Task { authorization = await UserNotificationService().requestAuthorization() }
    }

    /// Reads the grant without prompting for it, and **only while something is
    /// switched on**.
    ///
    /// The guard is what makes "the conformer is never constructed unless a
    /// toggle is on" true of this pane as well as of `SessionNotifier` — with
    /// both toggles off, opening Settings touches UserNotifications not at all.
    private func refreshAuthorization() {
        guard anyNotificationToggleOn else { return }
        Task { authorization = await UserNotificationService().authorizationState() }
    }

    /// **Written once**, because it is read from three places and a third toggle
    /// omitted from any one of them is a live control whose fault report never
    /// appears — or worse, a pane that touches UserNotifications with everything
    /// switched off. `SessionNotificationPreferences.wantsAnything` answers the
    /// same question for the notifier; this is the `@AppStorage` side of it,
    /// which cannot use that type because these are three separate bindings.
    private var anyNotificationToggleOn: Bool {
        notifyWhenStopped || notifyWhenTriggerStarts || notifyWhenASafetyGuardStops
    }

    private func openNotificationSettings() {
        guard let url = URL(string: notificationSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A status line reads faster with a shape and a colour than with a bare
/// word, and colour alone would be unreadable for anyone who can't
/// distinguish it — so each state pairs a distinct SF Symbol with its tint.
private struct ServiceStatusBadge: View {
    let state: OnboardingService.State

    var body: some View {
        Label {
            Text(serviceStatusTitle(state))
        } icon: {
            Image(systemName: serviceStatusSymbol(state))
                .foregroundStyle(serviceStatusTint(state))
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Shared styling

extension Text {
    /// Section footers carry most of the explanation in this window, so they
    /// get one consistent treatment instead of each pane inventing its own.
    func settingsFootnote() -> some View {
        self
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sidebar row's icon, drawn the way System Settings draws its own: a white
/// glyph centred on a filled, rounded square.
///
/// The size is fixed rather than derived from the row height. It has to line up
/// down the column whatever symbol is in it — a bolt and a display have very
/// different natural widths — and the system's own tiles do not resize with the
/// sidebar row setting either.
struct SettingsTabIcon: View {
    let tab: SettingsTab

    private let side: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tab.tint)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            // The label beside it already says everything this conveys, and a
            // tile announced separately is one more stop for no information.
            .accessibilityHidden(true)
    }
}

/// A control and the sentence that explains it, in **one** cell.
///
/// System Settings attaches an explanation to the control it describes: same
/// rounded card, directly beneath, in secondary text. This window used
/// `Section(footer:)` for the same sentences, which puts them *outside* the
/// card — so a pane with four controls read as four cards and four unattached
/// captions, and which caption belonged to which control was left to proximity.
///
/// A `Section` footer is still right for a sentence about the whole group
/// (`backgroundServicesFootnote`, the wake-mode scope note); this is for the
/// commoner case where one sentence explains exactly one control.
struct SettingsRow<Control: View, Note: View>: View {
    private let control: Control
    private let note: Note

    init(@ViewBuilder control: () -> Control, @ViewBuilder note: () -> Note) {
        self.control = control()
        self.note = note()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            note
                // Wraps rather than truncating: these sentences are the honest
                // caveats this project insists on, and a clipped caveat is a
                // caveat nobody read.
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The styled sentence the string convenience below builds.
///
/// A named type rather than `AnyView` or a `where Note == Text` clause:
/// `.settingsFootnote()` returns an opaque `some View`, so the constraint
/// cannot be written against `Text`, and erasing to `AnyView` to dodge that
/// would be reaching for a sledgehammer over one label.
struct SettingsRowNote: View {
    let text: String

    var body: some View {
        Text(text).settingsFootnote()
    }
}

extension SettingsRow where Note == SettingsRowNote {
    /// The common case: one control, one sentence.
    init(_ note: String, @ViewBuilder control: () -> Control) {
        self.init(control: control) {
            SettingsRowNote(text: note)
        }
    }
}
