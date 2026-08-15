import SwiftUI
import AppKit

/// The tab three tasks fill: shortcuts, the CLI on your `PATH`, and — as of
/// Task 10 — diagnostics.
///
/// It shipped empty one task earlier on purpose: three tasks each need it to
/// exist, and a tab created three times is a tab with three different section
/// orders. The placeholder sentence it carried until now
/// (`advancedSettingsPlaceholder`) is gone, along with its tests — "nothing to
/// set up here yet" above an Install button is worse than no placeholder at all.
///
/// **The state is the filesystem and it is re-read every time the pane
/// appears.** There is no stored preference behind it and there must not be
/// one: a cached "Installed" is wrong the moment the user moves the app, deletes
/// the link from a Terminal, or installs a second copy — and the cached answer
/// is the one this pane would show, confidently, about a link that is no longer
/// there. The Diagnostics section below is built on the same rule, one layer
/// out: it stores nothing about the daemon and asks it again on every visit.
struct AdvancedSettingsTab: View {
    /// The app's one `HotKeyCenter`, passed in rather than made here.
    ///
    /// It has to be the same instance `AppDelegate` registers through, because
    /// this pane's job includes showing *why a registration failed* — and a
    /// second centre would have its own empty `failures` and would cheerfully
    /// report that everything is fine. It would also try to register the same
    /// combinations exclusively and collide with the real one, so the pane
    /// would manufacture the very conflict it exists to report.
    @ObservedObject var hotKeys: HotKeyCenter

    /// The app's one `DaemonConnection`, and **deliberately not an
    /// `@ObservedObject`.**
    ///
    /// It republishes twice every three seconds (`refresh()` assigns
    /// `keepingAwake` and `sessions` on every poll, whether or not they
    /// changed). Observing it here would re-evaluate this pane's body on that
    /// cadence for the whole time Settings is open, which is what
    /// `SettingsView`'s own comment records having already cost this project
    /// once. What this section actually needs from it is one reply and one
    /// edge — both taken below through `.onReceive`, which delivers to a
    /// closure rather than invalidating a view.
    let daemon: DaemonConnection

    private let installation = CLIInstallation.forThisApp()
    /// Fixed for the lifetime of the process, so it is read once rather than on
    /// every body evaluation.
    private let appVersion = bundleVersionText(of: .main)

    @State private var state: CLIInstallState = .notInstalled
    /// What to say — and usually what to paste — after an attempt that did not
    /// simply work. Cleared on every re-read, so a message can never outlive
    /// the state that produced it.
    @State private var prompt: CLIInstallPrompt?

    /// What the daemon last said about itself. Starts `.unasked` rather than
    /// `.unreachable` — see `DaemonReachability`.
    @State private var reachability: DaemonReachability = .unasked
    /// One question in flight at a time. `$isConnected` delivers on every poll,
    /// so without this a daemon that has stopped answering would accumulate one
    /// pending five-second call per three seconds for as long as the window
    /// stayed open.
    @State private var asking = false

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .advanced)
            }

            // Shortcuts first, above the CLI section: this is the one people
            // come here to set, and the CLI section is the one they come here
            // to read once and never again.
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    HotKeyRecorderRow(action: action, hotKeys: hotKeys)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hotKeyShortcutsSectionFootnote)
                        .settingsFootnote()
                    // **Always visible, never conditional on a failure.** The
                    // conflict it describes is the one nothing can detect, so
                    // there is no state in which the app knows to show it — and
                    // a note that appeared only when something went wrong would
                    // teach the reader that its absence means the shortcut
                    // works, which is precisely the inference that is unsafe
                    // here.
                    Text(hotKeySilentConflictNote)
                        .settingsFootnote()
                }
            }

            Section {
                Text(cliInstallStatusSentence(state, linkPath: installation.linkPath))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let prompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(prompt.note)
                            .settingsFootnote()
                        if let command = prompt.command {
                            CommandToCopy(command: command)
                        }
                    }
                }

                // Always in the same place, so the section does not reflow as
                // the state changes; the states this app will not act on get no
                // button at all, because a button that refuses on every press is
                // worse than an absence explained by the sentence above it.
                HStack {
                    Spacer()
                    switch state {
                    case .notInstalled:
                        Button("Install…") { applyInstall(installation.install()) }
                    case .installed:
                        Button("Remove") { applyRemove(installation.remove()) }
                    case .linkedElsewhere, .dangling, .occupied:
                        EmptyView()
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cliInstallSectionFootnote(linkPath: installation.linkPath))
                        .settingsFootnote()
                    Text(cliRemoteInvocationNote)
                        .settingsFootnote()
                    ForEach(cliRemoteInvocationForms(binaryPath: installation.binaryPath), id: \.self) { form in
                        Text(form)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(cliSetupThroughLinkNote)
                        .settingsFootnote()
                }
            }

            // Last, and the only section here nobody sets anything in. The two
            // above are things you come to this tab to *do*, once; this is
            // where you look when something has already gone wrong, and a pane
            // you read in that state should not be the first thing between you
            // and the controls you came for.
            //
            // **There is no "Reset background services" button here, and there
            // must not be one.** `Shared/DaemonRemoval.swift` is why:
            // unregistering the daemon evicts the only process that can clear
            // `SleepDisabled`, and that setting outlives both the process and
            // the next reboot, so `prepareForRemoval` has to run and be
            // *believed* before anything unregisters. `keepy-uppy reset`
            // sequences that correctly and is one command away. A one-click
            // version of it, sitting on the pane somebody opens *because*
            // something already looks wrong, is a way to reach that hazard by
            // accident — and the accident leaves a Mac that cannot sleep with
            // nothing left installed to fix it. Everything below is read-only.
            Section {
                LabeledContent("Keepy Uppy", value: appVersion)
                LabeledContent("Background service", value: daemonVersionRowValue(reachability))

                Text(daemonDiagnosticsSentence(reachability, appVersion: appVersion))
                    .settingsFootnote()

                CommandToCopy(command: diagnosticsLogCommand)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(diagnosticsSectionFootnote)
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refresh()
            askTheDaemonItsVersion()
        }
        // The connection's own edges, taken as a stream rather than by
        // observing the object — see `daemon` above for why that distinction
        // matters here. `@Published` replays its current value on subscribe, so
        // this also covers a pane that appears while the connection is already
        // down.
        .onReceive(daemon.$isConnected) { connected in
            guard connected else {
                // **Only from `.reachable`.** From `.unasked`, a `false` means
                // "no poll has succeeded yet" rather than "the daemon is gone",
                // and the call `onAppear` started is the thing entitled to
                // settle that; from `.unreachable` there is nothing to change,
                // and re-assigning it twice a second-and-a-half would invalidate
                // this view for the whole time the window stayed open.
                if case .reachable = reachability { reachability = .unreachable }
                return
            }
            // Back after an outage — ask again, so the row carries the version
            // of whatever answered this time rather than of whatever answered
            // last time.
            if case .reachable = reachability { return }
            askTheDaemonItsVersion()
        }
        // The pane's own flow sends people to Terminal and brings them back to
        // a window that never disappeared, so `onAppear` does not fire again
        // and the sentence would still say "Not installed" about a link that
        // now exists. This is that case, and it is the *common* one: the
        // unprivileged attempt fails on any Mac nobody has chowned.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshIfChanged()
            }
    }

    /// Only when the filesystem actually moved. An unconditional re-read here
    /// would clear the command the user is in the middle of copying every time
    /// they switched to Terminal and back — which is precisely the trip this
    /// pane just asked them to make.
    private func refreshIfChanged() {
        guard installation.state() != state else { return }
        refresh()
    }

    private func refresh() {
        state = installation.state()
        // The one state with no button and a command worth offering anyway: a
        // link pointing at something that is gone. Matched on explicitly rather
        // than on "whatever `fallbackCommand` returned", so a future state that
        // gains a command cannot inherit this sentence.
        if case .dangling = state, let command = installation.fallbackCommand(for: state) {
            prompt = CLIInstallPrompt(note: cliReplaceDanglingNote, command: command)
        } else {
            prompt = nil
        }
    }

    /// Re-read first, then say what happened. In that order, so the sentence
    /// above the button always describes the filesystem as it is now rather
    /// than as the click expected it to be.
    private func applyInstall(_ result: CLIInstallResult) {
        let outcome = cliPrompt(after: result)
        refresh()
        if let outcome { prompt = outcome }
    }

    private func applyRemove(_ result: CLIRemoveResult) {
        let outcome = cliPrompt(after: result)
        refresh()
        if let outcome { prompt = outcome }
    }

    /// One round trip, and its answer is the whole state: a version means the
    /// daemon answered, `nil` means it did not. Nothing is cached between
    /// visits, on the same rule the CLI section follows about the filesystem —
    /// a remembered "0.1.0 (2)" is wrong the moment the daemon is replaced or
    /// stops, and the remembered answer is the one this pane would show,
    /// confidently, about a process that is no longer there.
    private func askTheDaemonItsVersion() {
        guard !asking else { return }
        asking = true
        // `@MainActor` stated rather than inherited: `DaemonConnection` is
        // main-actor-isolated and both assignments below are `@State` writes,
        // so this task has to land back on the main actor either way. Saying so
        // is what keeps that true if the enclosing isolation ever changes.
        Task { @MainActor in
            let version = await daemon.version()
            asking = false
            reachability = version.map { .reachable(version: $0) } ?? .unreachable
        }
    }
}

/// A command the user is being handed to run themselves, shown in full and
/// selectable, with a Copy button beside it.
///
/// Shown rather than summarised, and never truncated. It was written for the
/// `sudo` commands the CLI section hands over — "click Copy and trust us" is
/// not a thing to ask of somebody who cannot see what they are pasting as root
/// — and the Diagnostics section reuses it unchanged for a command that needs
/// no privilege at all. The rule generalises without weakening: a command this
/// app puts on the clipboard is one the user can read first.
private struct CommandToCopy: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
        }
        // A different command is a different thing to have copied, so the
        // confirmation must not carry over to it.
        .onChange(of: command) { _ in copied = false }
    }
}
