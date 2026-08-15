import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var daemon: DaemonConnection
    @AppStorage(MenuBarIconStylePreference.key, store: PreferencesSuite.defaults)
    private var styleRaw: String = MenuBarIconStylePreference.defaultRawValue

    var body: some View {
        Image(systemName: MenuBarIconStylePreference.style(rawValue: styleRaw)
            .symbol(active: daemon.keepingAwake))
    }
}

struct MenuContent: View {
    @ObservedObject var daemon: DaemonConnection
    /// Told — not asked — which endings this app is responsible for, at the two
    /// buttons that cause them. A plain `let` rather than an `@ObservedObject`
    /// because it publishes nothing and this view never reads it back.
    ///
    /// It is here, at the call site, rather than inside `DaemonConnection`, so
    /// that the XPC client stays a transport and
    /// `SessionNotificationTracker` stays the only thing that decides anything.
    let notifier: SessionNotifier
    @AppStorage(DefaultSessionKindPreference.key, store: PreferencesSuite.defaults)
    private var defaultKindRaw: String = DefaultSessionKindPreference.defaultRawValue
    @AppStorage(DefaultWakeModePreference.key, store: PreferencesSuite.defaults)
    private var defaultWakeModeRaw: String = DefaultWakeModePreference.defaultRawValue
    /// A `Bool` needs no raw-value dance and no fallback function: an absent key
    /// and a non-boolean value both read `false`, which is the fallback. The key
    /// and that fallback are still named once, in
    /// `DefaultKeepDisksAwakePreference`, because a string literal repeated here
    /// is how this pane and Settings would come to disagree.
    @AppStorage(DefaultKeepDisksAwakePreference.key, store: PreferencesSuite.defaults)
    private var defaultKeepDisksAwake: Bool = DefaultKeepDisksAwakePreference.fallback

    /// The whole of what the leading Start row will start, assembled once.
    ///
    /// `MenuDefaultStart` rather than three properties and a `PowerRequest`
    /// built inline, because this menu is no longer the only thing that starts
    /// "what the menu would start": the `.startDefaultSession` global hot key
    /// does too, and it has no view to read `@AppStorage` from. Both build this
    /// type, so an axis added to the stored default reaches both — which is the
    /// drift the disk axis would already have caused, having arrived after the
    /// hot key was first sketched against "the same two values".
    ///
    /// Each fallback stays named in its own preference type rather than
    /// repeated here: a wrong wake-mode fallback silently starts weaker
    /// sessions than the user asked for and looks identical in every surface.
    private var defaultStart: MenuDefaultStart {
        MenuDefaultStart(kindRawValue: defaultKindRaw,
                         wakeModeRawValue: defaultWakeModeRaw,
                         keepsDisksAwake: defaultKeepDisksAwake)
    }

    private var defaultKind: DefaultSessionKind { defaultStart.kind }
    private var defaultWakeMode: WakeMode { defaultStart.power.wakeMode }

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

    /// The sessions this app started itself — and, separately from being
    /// stoppable, the exact set `stopAllSessions(all: false)` sweeps.
    private var mine: [Session] { grouped.filter { $0.group == .thisApp }.map(\.session) }

    /// This user's own trigger-started sessions: **stoppable one row at a time
    /// as of Plan 8 Task 5**, which is spec §4's single exception to "every
    /// client may stop only its own sessions" (`SessionIsolation.authorize`).
    ///
    /// A separate list from `mine` rather than folded into it, because the two
    /// are not interchangeable anywhere the daemon is concerned: these are
    /// `agent-<uid>`, the sweep row below will not touch them, and neither will
    /// the `.stopAppSessions` hot key.
    private var yoursAutomatic: [Session] {
        grouped.filter { $0.group == .yoursAutomatic }.map(\.session)
    }

    /// Every row that has a Stop button, in the order the menu draws them —
    /// and therefore what `menuStatusLine` calls "yours".
    ///
    /// **This is the answer to the question Plan 7 Task 3 raised and Plan 8
    /// Task 4 deferred here on purpose.** "Yours" earns its meaning from the
    /// stop buttons directly beneath it: the number says how many of those rows
    /// you can do something about, and `SessionIsolation.authorize` is what
    /// decides that — not this view. Task 4 declined to widen the count while
    /// the authorization still said `app-<uid>` alone, precisely so that the
    /// count and the buttons would change on the same day. This is that day.
    ///
    /// It is still not "belongs to your account": this user's `keepy-uppy on`
    /// session is theirs and has no button, so counting it would put a number
    /// above a list where the counted row cannot be acted on.
    private var stoppable: [Session] { mine + yoursAutomatic }

    /// Everything else — this user's command-line sessions, this user's
    /// sessions from a client this build cannot name, and another account's.
    /// They share a list because they share a fate: shown, never clickable,
    /// because `SessionIsolation` refuses all three and a button that silently
    /// does nothing is worse than a line of text. What they do not share is a
    /// *label*; `menuSessionLabel` gives each its own, and records there which
    /// groups these are and why each is still refused.
    private var others: [(session: Session, group: MenuSessionGroup)] {
        grouped.filter { $0.group != .thisApp && $0.group != .yoursAutomatic }
    }

    /// One definition of what a Stop row *is*, used by both loops below.
    ///
    /// Written once rather than twice because of the first line in it: the
    /// notifier must be told **before** the XPC call and **synchronously**, or
    /// the commonest way for the last session to end — this very click —
    /// produces a banner explaining the click back to the person who just made
    /// it (`SessionNotifications`, the `requestedStops` window). Two copies of
    /// this button is one copy that will one day be written without that line,
    /// and the symptom would be a notification bug in the one path nobody
    /// re-tests.
    ///
    /// `menuAutomaticSuffix` is appended for both kinds of row, so a trigger
    /// session's Stop button reads `Stop “indefinite” — started automatically`:
    /// the same provenance clause the unclickable row carried before it became
    /// clickable, so nothing about *why* the session exists is lost by gaining
    /// a button.
    @ViewBuilder
    private func stopRow(for session: Session, now: Date) -> some View {
        Button {
            notifier.appWillStop(sessionIDs: [session.id])
            Task { await daemon.stopSession(session.id) }
        } label: {
            Text(menuStopLabel(for: session, isOnlyOneOfYours: stoppable.count == 1, now: now)
                 + menuAutomaticSuffix(for: session))
        }
    }

    /// The rows a session the user can act on gets: its Stop button, and — only
    /// where a session has given up surviving a lid close — one row that gives
    /// it back.
    ///
    /// **Whether that second row exists at all is `menuPowerPromotion`'s
    /// decision, not this view's**, and it hands back the request as well as the
    /// label. A view body cannot be tested, so the rule about which rows appear
    /// and the request each one sends both live in the tested function; what is
    /// left here is drawing what it returned. It is the same division
    /// `menuSessionGroup` already gets, for the same reason.
    ///
    /// The promote row follows its own session's Stop row rather than being
    /// collected into a section of its own, so the two rows about one session
    /// are adjacent — and there is at most one of them per session, in the
    /// uncommon case, so this is not the per-row accumulation Plan 7 removed.
    ///
    /// `notifier` is deliberately **not** told about this click, unlike the Stop
    /// row above it: this ends nothing. Telling it would suppress a banner about
    /// an ending that is not happening.
    @ViewBuilder
    private func sessionRows(for session: Session, now: Date) -> some View {
        stopRow(for: session, now: now)
        if let promotion = menuPowerPromotion(for: session,
                                              isOnlyOneOfYours: stoppable.count == 1, now: now) {
            Button(promotion.label) {
                Task { await daemon.changeSessionPower(of: session.id, to: promotion.request) }
            }
        }
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
            Text(menuStatusLine(yours: stoppable, others: others.map(\.session), now: now))

            // The status region's second line, and the only place the menu
            // speaks about the machine rather than about a session. It is
            // computed from the union of every live session's mode, which is
            // why it can be stated flatly here while the CLI's equivalent has
            // to be hedged down to the one session it knows about. Absent
            // whenever the lid is held — the expected case says nothing.
            if menuShowsLidCaveat(alongside: daemon.powerRequestNote),
               let caveat = menuLidCaveat(for: daemon.sessions) {
                Text(caveat)
            }

            // The status region's third line, and the only one that is about
            // the *install* rather than about this Mac. Present only when the
            // daemon admitted a session that does not carry what this app
            // asked for — which, unlike the version row in Settings, is
            // evidence of an actual dropped request rather than a difference
            // in build numbers.
            if let note = daemon.powerRequestNote {
                Text(note)
            }
        }

        if daemon.isConnected && !daemon.sessions.isEmpty {
            Divider()

            // `stopRow`'s `menuAutomaticSuffix` is still empty for every row in
            // *this* loop, in every case anyone can currently produce — this app
            // sends `origin: .manual` — and it is kept because
            // `DaemonConnection.startSession` takes the origin as a parameter,
            // so an app-started automatic session is one argument away. Its real
            // caller is the `yoursAutomatic` loop below, which is now a loop of
            // buttons rather than of labels.
            //
            // It is `origin` alone, and not the `startedByTrigger(forUserID:)`
            // rule the menu and the notifier share, *because* these rows are
            // `app-<uid>`: that rule requires `agent-<uid>` and would be
            // constant-false here, deleting the one-argument-away case rather
            // than guarding it. Nothing is lost by not corroborating, either —
            // only a binary meeting `SigningRequirement` is admitted as
            // `app-<uid>`, so this is us reading our own session's origin, not
            // taking another client's word for it.
            ForEach(mine) { session in sessionRows(for: session, now: now) }

            // Only worth offering once there is more than one to sweep; with a
            // single session it would just duplicate the line above it, which
            // is how the old menu ended up with two different stop buttons.
            //
            // The condition stays `mine.count`, not `stoppable.count`: this row
            // ends `mine` and nothing else, so with one app session and three
            // trigger sessions it would still be a duplicate of the single row
            // above it.
            if mine.count > 1 {
                Button(menuStopAllLabel) {
                    // The ids are snapshotted here because
                    // `stopAllSessions(all:)` replies with a count and not with
                    // ids: after the call there is nothing left to name. `mine`
                    // is exactly the set it will stop — `SessionIsolation`
                    // scopes it to this client's own `ClientID`, which is what
                    // that group means, and Task 5's amendment deliberately did
                    // **not** widen the sweep (`SessionIsolation.sessionsToStop`
                    // carries the argument). Hence the label: `yoursAutomatic`
                    // below has buttons this row does not press.
                    notifier.appWillStop(sessionIDs: mine.map(\.id))
                    Task { await daemon.stopAllSessions(all: false) }
                }
            }

            // Clickable since Plan 8 Task 5, one at a time — spec §4's single
            // exception, enforced by `SessionIsolation.authorize` in the daemon
            // and drawn here. They come after the sweep row rather than being
            // mixed in above it because the sweep does not touch them, and a
            // "stop all" sitting under rows it will not stop is the kind of
            // near-miss this menu was rebuilt to remove.
            // `sessionRows`, not `stopRow`, so a trigger session gets the
            // promote row on the same terms as one of this app's own. It is
            // unreachable today — `Agent/EvidenceLoopRunner.swift` builds every
            // trigger session with an explicit `.clamshell`, so there is nothing
            // to promote — and it is written this way deliberately rather than
            // scoped to `mine`: `SessionIsolation.authorize` already permits the
            // change for exactly this group, so a row here would be honoured,
            // and a per-rule wake mode would otherwise arrive as a session whose
            // menu row says "lid open only" with no way to fix it.
            ForEach(yoursAutomatic) { session in sessionRows(for: session, now: now) }

            // Shown, never clickable — this user's command-line sessions, this
            // user's sessions from a client this build cannot name, and another
            // account's. `SessionIsolation` refuses every stop of all three
            // (the amendment covers `agent-<uid>` trigger sessions of this user
            // and nothing else), so offering a button here would be a button
            // that silently does nothing — the same failure the old "Stop All"
            // label had.
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
        //
        // **And no `.keyboardShortcut`, though this row is exactly the one the
        // `.startDefaultSession` global hot key fires. Decided, not
        // overlooked.** A `.keyboardShortcut` on a `MenuBarExtra` row is a
        // *menu* shortcut: macOS draws it on the right of the row and it works
        // only while the menu is open. The binding beside it would be a global
        // one that works everywhere and needs no menu at all. Putting it here
        // gives two bad outcomes and no good one — either the app registers the
        // combination twice, once globally and once as a menu equivalent, so
        // one press does the thing twice with the menu open; or it is drawn as
        // decoration, in the place macOS has trained everyone to read as "this
        // key works here", about a key that works everywhere *else* too. The
        // binding is shown where it is set (Settings ▸ CLI & Advanced), and
        // `hotKeyShortcutsSectionFootnote` is where the user is told it works
        // without this menu being open. Recorded here so the absence is not
        // re-litigated as an omission — the same reason Plan 5 wrote down that
        // trigger warnings are not in the menu bar.
        // The verb moved to the section header, so the four rows carry only what
        // differs between them — the durations, which is what anyone is
        // scanning for. Each row still *announces* the whole phrase, because a
        // menu row is read alone by VoiceOver and "Indefinitely" on its own is
        // not an instruction.
        //
        // **Gated on macOS 14, and the fallback is not cosmetic.** Section
        // headers in a menu are `NSMenu`'s, added in Sonoma; on 13 a
        // `Section` still groups but draws no title, which would leave four
        // rows reading "Indefinitely", "For 1 Hour" with the verb nowhere on
        // screen. That is worse than the repetition this replaced, so 13 keeps
        // the full labels it always had.
        if #available(macOS 14, *) {
            startRows(headed: true)
        } else {
            startRows(headed: false)
        }
    }

    /// The four start rows, with or without the header that carries their verb.
    @ViewBuilder
    private func startRows(headed: Bool) -> some View {
        if headed {
            Section(menuStartSectionTitle) { startButtons(showingVerb: false) }
        } else {
            startButtons(showingVerb: true)
        }
    }

    @ViewBuilder
    private func startButtons(showingVerb: Bool) -> some View {
        Group {
            Button(showingVerb
                   ? menuStartLabel(defaultKind, wakeMode: defaultWakeMode,
                                    keepsDisksAwake: defaultKeepDisksAwake)
                   : menuStartRowLabel(defaultKind, wakeMode: defaultWakeMode,
                                       keepsDisksAwake: defaultKeepDisksAwake)) {
                let start = defaultStart
                Task {
                    await daemon.startSession(kind: start.sessionKind(now: Date()),
                                              power: start.power)
                }
            }
            .accessibilityLabel(menuStartLabel(defaultKind, wakeMode: defaultWakeMode,
                                               keepsDisksAwake: defaultKeepDisksAwake))

            ForEach(DefaultSessionKind.allCases.filter { $0 != defaultKind }) { kind in
                Button(showingVerb
                       ? menuStartLabel(kind, wakeMode: defaultWakeMode,
                                        keepsDisksAwake: defaultKeepDisksAwake)
                       : menuStartRowLabel(kind, wakeMode: defaultWakeMode,
                                           keepsDisksAwake: defaultKeepDisksAwake)) {
                    let power = defaultStart.power
                    Task {
                        await daemon.startSession(kind: kind.sessionKind(now: Date()),
                                                  power: power)
                    }
                }
                .accessibilityLabel(menuStartLabel(kind, wakeMode: defaultWakeMode,
                                                   keepsDisksAwake: defaultKeepDisksAwake))
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
