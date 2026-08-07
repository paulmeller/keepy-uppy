import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        Image(systemName: daemon.keepingAwake ? "balloon.fill" : "balloon")
    }
}

struct MenuContent: View {
    @ObservedObject var daemon: DaemonConnection
    @AppStorage("defaultSessionKind", store: PreferencesSuite.defaults)
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue

    /// Settings' General tab writes the raw value; an unrecognised one (an
    /// enum case removed in a later version, say) falls back rather than
    /// dropping the quick-start entry entirely.
    private var defaultKind: DefaultSessionKind {
        DefaultSessionKind(rawValue: defaultKindRaw) ?? .indefinite
    }

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

        // The stored default goes first, above a divider, with the other
        // choices below it. Until the final whole-branch review (Item 3) this
        // submenu iterated `allCases` unconditionally and never read
        // `defaultKindRaw` at all, so Settings' "Default Session" picker was
        // entirely inert — deliberately kept to the smallest change that
        // makes the stored preference observably do something.
        Menu("Start…") {
            Button(defaultKind.label) {
                Task { await daemon.startSession(kind: defaultKind.sessionKind(now: Date())) }
            }

            Divider()

            ForEach(DefaultSessionKind.allCases.filter { $0 != defaultKind }) { kind in
                Button(kind.label) {
                    Task { await daemon.startSession(kind: kind.sessionKind(now: Date())) }
                }
            }
        }

        if !daemon.sessions.isEmpty {
            // NOT "Stop All": `stopAllSessions(all: false)` stops only this
            // app's own sessions (`SessionIsolation.sessionsToStop`), while
            // the list above deliberately shows every client's sessions so
            // the user can see why their Mac is awake. Labelling that "Stop
            // All" meant a CLI-started session stayed visibly running after
            // the click, looking like a silent failure. Passing `all: true`
            // would be the wrong fix — it is exactly the cross-client
            // isolation this project built `SessionIsolation` to prevent —
            // so the label is what changes (final whole-branch review,
            // Item 4).
            Button("Stop My Sessions") {
                Task { await daemon.stopAllSessions(all: false) }
            }
        }

        Divider()

        // `SettingsLink` is the only supported way to open the `Settings`
        // scene, but it needs macOS 14 and this ships back to 13. The 13
        // fallback sends `showSettingsWindow:`, which is undocumented and —
        // confirmed the hard way on macOS 26 — silently does nothing on
        // current systems: the menu item was simply inert. So the modern path
        // is not a nicety here, it is the one that works; the selector is kept
        // only to keep the 13.0 deployment target honest.
        if #available(macOS 14, *) {
            OpenSettingsButton()
        } else {
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
        }

        Button("Quit Keepy Uppy") {
            NSApplication.shared.terminate(nil)
        }
    }
}


/// `SettingsLink` opens the scene but cannot also activate the app, and
/// `SettingsView.onAppear` only fires the first time — so with the window
/// already open behind another app, clicking Settings did nothing visible.
/// `openSettings` is the same action as an invocable closure, so activation
/// can follow it every time.
@available(macOS 14, *)
private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
    }
}
