import SwiftUI

struct SettingsView: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "shield") }
            TriggersSettingsTab()
                .tabItem { Label("Triggers", systemImage: "bolt") }
        }
        .frame(width: 420, height: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct GeneralSettingsTab: View {
    @StateObject private var onboarding = OnboardingService()
    @State private var launchAtLoginEnabled = LoginItemService.status() == .enabled
    @AppStorage("defaultSessionKind", store: UserDefaults(suiteName: "au.com.workwireless.keepy-uppy"))
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { enabled in
                    try? enabled ? LoginItemService.register() : LoginItemService.unregister()
                }

            Picker("Default Session", selection: $defaultKindRaw) {
                ForEach(DefaultSessionKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }

            Divider()

            LabeledContent("Background Service") {
                Text(statusText(onboarding.daemonStatus, onboarding.agentStatus))
            }
            if onboarding.daemonStatus != .enabled || onboarding.agentStatus != .enabled {
                Button("Enable Keepy Uppy") {
                    onboarding.enable()
                }
            }
        }
        .padding()
        .onAppear { onboarding.refresh() }
    }

    private func statusText(_ daemon: ServiceStatus, _ agent: ServiceStatus) -> String {
        if daemon == .enabled && agent == .enabled { return "Running" }
        if daemon == .requiresApproval || agent == .requiresApproval { return "Needs approval in System Settings" }
        return "Not enabled"
    }
}
