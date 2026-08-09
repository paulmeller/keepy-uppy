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

    /// The identity the daemon stamps on sessions this app starts, derived the
    /// same way the daemon derives it — from the app's role and this user's
    /// uid. Sessions with any other owner belong to the CLI, the agent, or
    /// another user, and this app cannot stop them.
    private var myClientID: ClientID {
        ClientRole.app.clientID(forUserID: UInt32(getuid()))
    }

    private var mine: [Session] { daemon.sessions.filter { $0.owner == myClientID } }
    private var others: [Session] { daemon.sessions.filter { $0.owner != myClientID } }

    var body: some View {
        let now = Date()

        // Status, then actions — deliberately not the same line. Previously
        // each session row *was* the stop button, labelled
        // "Indefinite — Started manually — Stop", which read as a status line
        // and hid its own verb behind two pieces of trivia.
        if !daemon.isConnected {
            Text("Not connected to Keepy Uppy daemon")
        } else {
            Text(menuStatusLine(mine: mine, others: others, now: now))
        }

        if daemon.isConnected && !daemon.sessions.isEmpty {
            Divider()

            ForEach(mine) { session in
                Button {
                    Task { await daemon.stopSession(session.id) }
                } label: {
                    Text(menuStopLabel(for: session, isOnlyOneOfMine: mine.count == 1, now: now)
                         + menuAutomaticSuffix(for: session))
                }
            }

            // Only worth offering once there is more than one to sweep; with a
            // single session it would just duplicate the line above it, which
            // is how the old menu ended up with two different stop buttons.
            if mine.count > 1 {
                Button("Stop all mine") {
                    Task { await daemon.stopAllSessions(all: false) }
                }
            }

            // Shown, never clickable. `stopAllSessions(all: false)` scopes to
            // this client by design (`SessionIsolation`), so offering to stop
            // these would be a button that silently does nothing — the same
            // failure the old "Stop All" label had.
            ForEach(others) { session in
                Text(menuForeignSessionLabel(for: session, now: now))
            }
        }

        Divider()

        // Flat, not a submenu. Starting a session is the most common thing
        // anyone does here, and it used to take three interactions: open the
        // menu, hover "Start…", wait, then pick. The stored default leads.
        Button(menuStartLabel(defaultKind)) {
            Task { await daemon.startSession(kind: defaultKind.sessionKind(now: Date())) }
        }
        ForEach(DefaultSessionKind.allCases.filter { $0 != defaultKind }) { kind in
            Button(menuStartLabel(kind)) {
                Task { await daemon.startSession(kind: kind.sessionKind(now: Date())) }
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
