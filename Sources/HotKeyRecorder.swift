import SwiftUI
import AppKit
import Carbon.HIToolbox

/// One row of the Keyboard Shortcuts section: what the shortcut does, what it
/// is currently bound to, and — when there is one — why it is not working.
///
/// **The monitor is local, and that is a permission decision rather than a
/// convenience.** `NSEvent.addLocalMonitorForEvents` sees only events already
/// being delivered to this process, so it needs no grant at all.
/// `addGlobalMonitorForEvents` is the obvious wrong turn here — it looks like
/// the right API for a thing called a *global* hot key — and it requires
/// Accessibility, which is exactly the grant spec §4 chose `RegisterEventHotKey`
/// over an event tap to avoid. Reaching for it would silently re-introduce the
/// permission prompt this feature was designed not to need, and it would work
/// perfectly on the developer's machine, where the grant is already given.
///
/// Recording only has to see keys pressed *into this app*, which is the
/// definition of a local event, so nothing is given up by staying local. "Local"
/// means this process rather than this window — and in an `LSUIElement` app
/// whose only window is Settings, those are the same set: the monitor is armed
/// only between a press of this row's button and the next key, and it is torn
/// down on `onDisappear` as well, because closing the window mid-recording
/// takes none of the other paths that stop it.
struct HotKeyRecorderRow: View {
    let action: HotKeyAction
    @ObservedObject var hotKeys: HotKeyCenter

    /// The stored binding, in its `HotKeyBinding.storedForm`. An empty string
    /// is unset — `@AppStorage` has no way to express absence, and
    /// `HotKeyPreference.binding(for:in:)` reads empty, missing and unparseable
    /// back the same way.
    @AppStorage private var storedForm: String

    @State private var isRecording = false
    @State private var monitor: Any?
    /// A combination that was pressed and refused, kept only long enough to
    /// explain itself. Not stored: a binding that cannot work must never become
    /// the row's value, or the row would show a shortcut above a sentence
    /// saying it is impossible.
    @State private var refusedProblem: String?

    init(action: HotKeyAction, hotKeys: HotKeyCenter) {
        self.action = action
        _hotKeys = ObservedObject(wrappedValue: hotKeys)
        _storedForm = AppStorage(wrappedValue: "", action.preferenceKey,
                                 store: PreferencesSuite.defaults)
    }

    private var binding: HotKeyBinding? { HotKeyBinding(storedForm: storedForm) }

    /// macOS's own shortcuts, read once per rebuild rather than cached in
    /// `@State`: the user can change them in System Settings while this window
    /// is open, and a cached answer would go on warning about a combination
    /// they have just freed.
    private var systemTakesIt: Bool {
        systemShortcutTakes(binding, among: HotKeyCenter.systemShortcuts())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label)
                    Text(hotKeyActionExplanation(action))
                        .settingsFootnote()
                }
                Spacer()
                Button(recordButtonTitle) {
                    isRecording ? stopRecording() : startRecording()
                }
                .fixedSize()
                // Always present, never conditional: a button that appears only
                // when there is something to clear makes the row reflow as the
                // value changes, and the disabled state says "nothing to clear"
                // just as clearly.
                Button("Clear") { clear() }
                    .disabled(storedForm.isEmpty && !isRecording)
            }

            // At most one sentence, in this order, because they are not equally
            // urgent: a combination that cannot work at all comes before one
            // that failed to register, which comes before one that registered
            // and will never fire.
            if let refusedProblem {
                problem(refusedProblem)
            } else if let failure = hotKeys.failures[action] {
                problem(hotKeyRegistrationFailureSentence(failure))
            } else if systemTakesIt {
                problem(hotKeySystemConflictWarning)
            }
        }
        // The monitor must not outlive the window. It is torn down here as well
        // as on every path that stops recording, because closing Settings
        // mid-recording takes none of those paths.
        .onDisappear { stopRecording() }
    }

    private var recordButtonTitle: String {
        if isRecording { return "Press keys…" }
        guard let binding else { return hotKeyUnsetPlaceholder }
        return hotKeyDisplayString(binding)
    }

    private func problem(_ sentence: String) -> some View {
        Label(sentence, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startRecording() {
        refusedProblem = nil
        isRecording = true
        guard monitor == nil else { return }
        // `.flagsChanged` as well as `.keyDown`: without it, holding ⌘ before
        // pressing the key would leave the modifier event to be handled by the
        // window, and on some layouts that is enough to trigger a menu.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard isRecording else { return event }
            // Swallowed while recording, whatever it was. Returning the event
            // would let ⌘W close the Settings window as the user tries to bind
            // it — every combination has to be recordable, including the ones
            // this window itself would otherwise act on.
            guard event.type == .keyDown else { return nil }

            let modifiers = HotKeyModifiers(eventFlags: event.modifierFlags)
            // Escape alone cancels; Escape with modifiers is a combination
            // somebody may legitimately want, so it records like any other.
            if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                stopRecording()
                return nil
            }
            record(HotKeyBinding(keyCode: event.keyCode, modifiers: modifiers))
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A refused combination leaves the stored value exactly as it was. The
    /// alternative — clearing it because the new press was bad — would lose a
    /// working shortcut to a mistyped one.
    private func record(_ binding: HotKeyBinding) {
        stopRecording()
        if let problem = hotKeyBindingProblem(binding) {
            refusedProblem = problem
            return
        }
        refusedProblem = nil
        storedForm = binding.storedForm
    }

    private func clear() {
        stopRecording()
        refusedProblem = nil
        // The empty string rather than a removal, because `@AppStorage` cannot
        // express absence. `HotKeyPreference` reads the two identically.
        storedForm = ""
    }
}
