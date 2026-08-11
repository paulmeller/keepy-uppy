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
            AdvancedSettingsTab()
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

            // The "Keeps this Mac awake" picker and the "Keep attached disks
            // awake" toggle used to sit here, in that order, directly under
            // "Default session" — Plan 4 put the picker here because the two
            // answer the same question about the same thing, and Plan 6 put the
            // toggle immediately beneath the picker for the same reason. Plan 7
            // moved the pair, together and in that order, to
            // `Sources/DisplaySettingsTab.swift`, where the argument is written
            // out in full. Nothing about it was withdrawn: "Default session"
            // says *when* a session ends and those two say *what* it holds
            // awake, and once there was a tab for the second question the pair
            // belonged in it rather than in a General tab that is otherwise
            // about the app rather than about a session.
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
