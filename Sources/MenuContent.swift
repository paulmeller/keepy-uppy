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
    @AppStorage(DefaultWakeModePreference.key, store: PreferencesSuite.defaults)
    private var defaultWakeModeRaw: String = DefaultWakeModePreference.defaultRawValue
    /// A `Bool` needs no raw-value dance and no fallback function: an absent key
    /// and a non-boolean value both read `false`, which is the fallback. The key
    /// and that fallback are still named once, in
    /// `DefaultKeepDisksAwakePreference`, because a string literal repeated here
    /// is how this pane and Settings would come to disagree.
    @AppStorage(DefaultKeepDisksAwakePreference.key, store: PreferencesSuite.defaults)
    private var defaultKeepDisksAwake: Bool = DefaultKeepDisksAwakePreference.fallback

    /// Settings' General tab writes the raw value; an unrecognised one (an
    /// enum case removed in a later version, say) falls back rather than
    /// dropping the quick-start entry entirely.
    private var defaultKind: DefaultSessionKind {
        DefaultSessionKind(rawValue: defaultKindRaw) ?? .indefinite
    }

    /// Same arrangement, one file further out: the fallback is named in
    /// `DefaultWakeModePreference` rather than repeated here, because unlike
    /// the kind above — where a wrong fallback shows the wrong duration and is
    /// obvious — a wrong wake-mode fallback silently starts weaker sessions
    /// than the user asked for, and looks identical in every surface.
    private var defaultWakeMode: WakeMode {
        DefaultWakeModePreference.mode(rawValue: defaultWakeModeRaw)
    }

    /// The whole request these rows will start, assembled once. Every start
    /// button reads this rather than passing axes individually, so a row cannot
    /// start a session with one of them left behind.
    private var defaultPower: PowerRequest {
        PowerRequest(wakeMode: defaultWakeMode, keepsDisksAwake: defaultKeepDisksAwake)
    }

    /// Every live session with the row it has earned, computed once per
    /// rebuild. The decision itself is `menuSessionGroup` — a pure function in
    /// `SessionDisplay.swift` rather than a filter written inline here, because
    /// a view body cannot be tested and this comparison is where a wrong answer
    /// produces a menu that looks entirely plausible: it used to sort a session
    /// started by this user's own trigger rule in with strangers' sessions,
    /// since a trigger is owned by `agent-<uid>` and not `app-<uid>`.
    private var grouped: [(session: Session, group: MenuSessionGroup)] {
        let userID = UInt32(getuid())
        return daemon.sessions.map { ($0, menuSessionGroup(for: $0, userID: userID)) }
    }

    /// The sessions this app started, which `SessionIsolation` makes the only
    /// ones it can stop.
    private var mine: [Session] { grouped.filter { $0.group == .thisApp }.map(\.session) }

    /// Everything else — this user's own automatic and command-line sessions
    /// and another account's alike. They share a list because they share a
    /// fate: shown, never clickable. What they no longer share is a *label*.
    ///
    /// `menuStatusLine`'s "yours" still counts `mine` only, so a user with a
    /// trigger session and an app session reads "2 sessions, 1 yours". That is
    /// the count of what the menu can act on rather than of what belongs to
    /// them, and it is left as it was: widening it is a change to a different
    /// sentence than the one this task was about.
    private var others: [(session: Session, group: MenuSessionGroup)] {
        grouped.filter { $0.group != .thisApp }
    }

    var body: some View {
        let now = Date()

        // Status, then actions — deliberately not the same line. Previously
        // each session row *was* the stop button, labelled
        // "Indefinite — Started manually — Stop", which read as a status line
        // and hid its own verb behind two pieces of trivia.
        if !daemon.isConnected {
            Text("Not connected to Keepy Uppy daemon")
        } else {
            Text(menuStatusLine(mine: mine, others: others.map(\.session), now: now))

            // The status region's second line, and the only place the menu
            // speaks about the machine rather than about a session. It is
            // computed from the union of every live session's mode, which is
            // why it can be stated flatly here while the CLI's equivalent has
            // to be hedged down to the one session it knows about. Absent
            // whenever the lid is held — the expected case says nothing.
            if let caveat = menuLidCaveat(for: daemon.sessions) {
                Text(caveat)
            }
        }

        if daemon.isConnected && !daemon.sessions.isEmpty {
            Divider()

            // The suffix here is still empty in every case anyone can currently
            // produce — this app sends `origin: .manual` — and it is kept
            // because `DaemonConnection.startSession` takes the origin as a
            // parameter, so an app-started automatic session is one argument
            // away. Its real caller is the automatic row below.
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
            // failure the old "Stop All" label had. That is still true of this
            // user's own trigger-started session, which the app can now *name*
            // but still has no authority to end.
            //
            // One flat list in the daemon's own order, not three sections: the
            // rows differ by a clause each, and grouping them would be
            // structure added to a menu that was rebuilt to have less of it.
            ForEach(others, id: \.session.id) { row in
                Text(menuSessionLabel(for: row.session, group: row.group, now: now))
            }
        }

        Divider()

        // Flat, not a submenu. Starting a session is the most common thing
        // anyone does here, and it used to take three interactions: open the
        // menu, hover "Start…", wait, then pick. The stored default leads.
        //
        // Still one row per duration, deliberately: the stored power request
        // applies to all of them, so this stays a list of *when it ends* and
        // does not become a 4×3 grid — let alone a 4×3×2 one now that there is a
        // third axis. What a session asks of the machine is a Settings decision
        // made once, not a per-start choice.
        Button(menuStartLabel(defaultKind, wakeMode: defaultWakeMode,
                              keepsDisksAwake: defaultKeepDisksAwake)) {
            Task {
                await daemon.startSession(kind: defaultKind.sessionKind(now: Date()),
                                          power: defaultPower)
            }
        }
        ForEach(DefaultSessionKind.allCases.filter { $0 != defaultKind }) { kind in
            Button(menuStartLabel(kind, wakeMode: defaultWakeMode,
                                  keepsDisksAwake: defaultKeepDisksAwake)) {
                Task {
                    await daemon.startSession(kind: kind.sessionKind(now: Date()),
                                              power: defaultPower)
                }
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
