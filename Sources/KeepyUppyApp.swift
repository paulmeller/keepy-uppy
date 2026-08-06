import SwiftUI

@main
struct KeepyUppyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: appDelegate.monitor)
        } label: {
            MenuBarIcon(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}
