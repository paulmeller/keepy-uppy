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
        // Not `.fullScreenPrimary`: a settings window has no full-screen mode
        // worth offering, and leaving the collection behaviour alone is what
        // puts a live green button back on some macOS versions.
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
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
            List(selection: selectedTab) {
                Section {
                    ForEach(SettingsTab.allCases) { tab in
                        Label {
                            Text(tab.title)
                                .font(.system(size: sidebarItemFontSize))
                                .padding(.leading, 2)
                        } icon: {
                            Image(systemName: tab.symbol)
                        }
                        .frame(height: sidebarItemHeight)
                        .tag(tab)
                    }
                }
                // **No app-name header, deliberately.** A 30pt wordmark was
                // here for one revision because it is what Ice does and it
                // makes a screenshot look designed. Neither System Settings nor
                // Xcode's settings has one, and a settings window is the last
                // place to be inventive — the title bar already names the pane,
                // and the window is only ever opened from this app. It was the
                // prettier layout and the wrong one.
                .collapsible(false)
            }
            // A settings sidebar is a fixed list of five, not a document
            // browser: it must not scroll, and it must not offer to collapse
            // itself away and leave the window with no navigation at all.
            .scrollDisabled(true)
            .removeSidebarToggle()
            .navigationSplitViewColumnWidth(sidebarWidth)
            // Top of the sidebar, where System Settings puts its own. It was
            // briefly at the bottom, which looked tidy and is not where anybody
            // reaches for it.
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsSearchField(query: $searchQuery, selectedTab: selectedTab)
            }
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
        .frame(minHeight: SettingsMetrics.minHeight)
        .onAppear {
            // An LSUIElement app owns no menu bar and is never "frontmost" by
            // default, so its Settings window opens behind whatever the user
            // was doing unless it asks for activation explicitly (spec §9).
            NSApp.activate(ignoringOtherApps: true)
            configureSettingsWindow()
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
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { enabled in
                        try? enabled ? LoginItemService.register() : LoginItemService.unregister()
                    }
            } footer: {
                Text("Opens Keepy Uppy in the menu bar when you log in. The background services below run regardless.")
                    .settingsFootnote()
            }

            Section {
                Picker("Default session", selection: $defaultKindRaw) {
                    ForEach(DefaultSessionKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
            } footer: {
                Text("Listed first in the menu's Start menu, so the session you use most is one click away.")
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


/// The search field above the tabs, and the results it drops beneath itself.
///
/// A list of destinations rather than a filtered view of the settings
/// themselves: the panes are `Form`s with their own footers and section
/// arguments, and rebuilding them from an index would give two renderings of
/// every control to keep in step. Naming where a thing lives and taking you
/// there is most of the value at a fraction of the surface.
private struct SettingsSearchField: View {
    @Binding var query: String
    @Binding var selectedTab: SettingsTab

    private var results: [SettingsIndexEntry] { searchSettings(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if !query.isEmpty {
                Divider()
                if results.isEmpty {
                    // Says so rather than showing an empty strip, which reads
                    // as a broken control rather than an answer.
                    Text("Nothing matches “\(query)”.")
                        .settingsFootnote()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(results, id: \.title) { entry in
                                Button {
                                    selectedTab = entry.tab
                                    query = ""
                                } label: {
                                    HStack {
                                        Label(entry.title, systemImage: entry.tab.symbol)
                                        Spacer()
                                        Text(entry.tab.title).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                Divider()
            }
        }
        .background(.bar)
    }
}
