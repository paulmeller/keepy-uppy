import SwiftUI
import AppKit

/// The tab Tasks 9 and 10 still have to fill — hot keys and diagnostics. Its
/// first section is the CLI on your `PATH`.
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
/// there.
struct AdvancedSettingsTab: View {
    private let installation = CLIInstallation.forThisApp()

    @State private var state: CLIInstallState = .notInstalled
    /// What to say — and usually what to paste — after an attempt that did not
    /// simply work. Cleared on every re-read, so a message can never outlive
    /// the state that produced it.
    @State private var prompt: CLIInstallPrompt?

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
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
}

/// A command the user is being asked to run as root, shown in full and
/// selectable, with a Copy button beside it.
///
/// Shown rather than summarised, and never truncated: this is a command that
/// will run with root privileges, and "click Copy and trust us" is not a thing
/// to ask of somebody who cannot see what they are pasting.
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
