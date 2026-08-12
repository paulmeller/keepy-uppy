import SwiftUI

/// Sizing follows the macOS settings convention: one width for every tab so
/// switching tabs doesn't resize the window sideways, and a minimum height
/// that fits the tallest pane. Panes scroll rather than clip if a future one
/// outgrows it.
private enum SettingsMetrics {
    static let width: CGFloat = 560
    static let minHeight: CGFloat = 440
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

    /// Passed straight through to the same tab, whose Diagnostics section asks
    /// it for the daemon's version. It has to be the app's one connection: a
    /// second `DaemonConnection` made here would open its own privileged XPC
    /// connection, poll it forever, and report on the health of something no
    /// other part of the app is using.
    let daemon: DaemonConnection

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
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TriggersSettingsTab()
                .tabItem { Label("Triggers", systemImage: "bolt") }
            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "display") }
            SafetySettingsTab()
                .tabItem { Label("Safety & Guards", systemImage: "exclamationmark.shield") }
            AdvancedSettingsTab(hotKeys: hotKeys, daemon: daemon)
                .tabItem { Label("CLI & Advanced", systemImage: "terminal") }
        }
        .frame(minWidth: SettingsMetrics.width, maxWidth: SettingsMetrics.width,
               minHeight: SettingsMetrics.minHeight)
        .onAppear {
            // An LSUIElement app owns no menu bar and is never "frontmost" by
            // default, so its Settings window opens behind whatever the user
            // was doing unless it asks for activation explicitly (spec §9).
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @StateObject private var onboarding = OnboardingService()
    @State private var launchAtLoginEnabled = LoginItemService.status() == .enabled
    @AppStorage("defaultSessionKind", store: PreferencesSuite.defaults)
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue
    /// Both keys and both starting values come from
    /// `SessionNotificationPreference`, never from literals here: the notifier
    /// reads them back in a different file that never calls this one, and a
    /// typo in either place is not a compile error and not a crash — it is a
    /// toggle that appears to work while nothing is ever posted.
    @AppStorage(SessionNotificationPreference.stopKey, store: PreferencesSuite.defaults)
    private var notifyWhenStopped: Bool = SessionNotificationPreference.fallback
    @AppStorage(SessionNotificationPreference.triggerStartKey, store: PreferencesSuite.defaults)
    private var notifyWhenTriggerStarts: Bool = SessionNotificationPreference.fallback
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

                // Present only when there is something wrong to report, which
                // is the opposite of the "always present rather than appearing
                // only when something is wrong" rule the Background Services
                // button below follows — and deliberately. That button is an
                // action the pane always offers; this is a *fault report*, and
                // a permanently-visible one on a working grant is a nag about
                // a permission the user already gave.
                if let note = notificationStatusNote(
                    state: authorization,
                    anyToggleOn: notifyWhenStopped || notifyWhenTriggerStarts) {
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
        guard notifyWhenStopped || notifyWhenTriggerStarts else { return }
        Task { authorization = await UserNotificationService().authorizationState() }
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
