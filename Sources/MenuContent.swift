import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        Image(systemName: daemon.keepingAwake ? "balloon.fill" : "balloon")
    }
}

struct MenuContent: View {
    @ObservedObject var daemon: DaemonConnection
    @AppStorage("defaultSessionKind", store: UserDefaults(suiteName: "au.com.workwireless.keepy-uppy"))
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue

    var body: some View {
        if !daemon.isConnected {
            Text("Not connected to Keepy Uppy daemon")
        } else if daemon.sessions.isEmpty {
            Text("Not keeping awake")
        } else {
            ForEach(daemon.sessions) { session in
                Button {
                    Task { await daemon.stopSession(session.id) }
                } label: {
                    Text("\(remainingTimeText(for: session, now: Date())) — \(originText(for: session)) — Stop")
                }
            }
        }

        Divider()

        Menu("Start…") {
            ForEach(DefaultSessionKind.allCases) { kind in
                Button(kind.label) {
                    Task { await daemon.startSession(kind: kind.sessionKind(now: Date())) }
                }
            }
        }

        if !daemon.sessions.isEmpty {
            Button("Stop All") {
                Task { await daemon.stopAllSessions(all: false) }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Quit Keepy Uppy") {
            NSApplication.shared.terminate(nil)
        }
    }
}
