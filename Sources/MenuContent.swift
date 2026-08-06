import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        Image(systemName: monitor.sleepState == .disabled ? "balloon.fill" : "balloon")
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        Text(statusText)

        Button(toggleText) {
            monitor.toggle()
        }

        Toggle("Launch at Login", isOn: Binding(
            get: { monitor.loginItemEnabled },
            set: { _ in monitor.toggleLoginItem() }
        ))

        Divider()

        Button("Quit Keepy Uppy") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusText: String {
        switch monitor.sleepState {
        case .disabled: return "Status: Keeping Awake"
        case .enabled: return "Status: Normal Sleep"
        case .unknown: return "Status: Unknown"
        }
    }

    private var toggleText: String {
        monitor.sleepState == .disabled ? "Turn Off Keepy Uppy" : "Turn On Keepy Uppy"
    }
}
