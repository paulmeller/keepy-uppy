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
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "exclamationmark.shield") }
            TriggersSettingsTab()
                .tabItem { Label("Triggers", systemImage: "bolt") }
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
    @AppStorage(DefaultWakeModePreference.key, store: PreferencesSuite.defaults)
    private var defaultWakeModeRaw: String = DefaultWakeModePreference.defaultRawValue

    private var defaultWakeMode: WakeMode {
        DefaultWakeModePreference.mode(rawValue: defaultWakeModeRaw)
    }

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

            // Directly under "Default session", and not in Safety, because the
            // two answer the same question about the same thing: what the
            // menu's "Keep awake…" rows will start. One says when it ends, the
            // other how it holds the Mac awake. Safety is about limits the
            // daemon imposes on sessions it did not start, including the CLI's
            // — this governs only sessions started here, so it would be the
            // odd one out there.
            //
            // Its own Section rather than a second row of the one above so the
            // footer can change with the selection, which is the arrangement
            // Safety's thermal picker already uses: three short phrases can
            // distinguish the options but cannot explain what they cost.
            Section {
                Picker("Keeps this Mac awake", selection: $defaultWakeModeRaw) {
                    ForEach(wakeModeSettingsOrder, id: \.self) { mode in
                        Text(wakeModeSettingsTitle(mode)).tag(mode.rawValue)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(wakeModeSettingsExplanation(defaultWakeMode))
                        .settingsFootnote()
                    Text(wakeModeSettingsScopeNote)
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
        .onAppear { onboarding.refresh() }
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
