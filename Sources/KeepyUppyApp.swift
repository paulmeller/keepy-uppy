import SwiftUI

@main
struct KeepyUppyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(daemon: appDelegate.daemon)
        } label: {
            MenuBarIcon(daemon: appDelegate.daemon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(daemon: appDelegate.daemon)
        }
    }
}
