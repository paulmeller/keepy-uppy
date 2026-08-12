import AppKit
import Carbon.HIToolbox

/// `eventHotKeyExistsErr`, named once so nothing outside this file has to
/// import Carbon to recognise it. -9878, `<CarbonEventsCore.h>`.
///
/// It is the **only** conflict `RegisterEventHotKey` can report, and it reports
/// a narrower thing than its name suggests: another `RegisterEventHotKey`
/// client already holds this combination exclusively. Everything users actually
/// collide with — Spotlight, Mission Control, a screenshot shortcut, another
/// app's event tap — returns `noErr`. See `HotKeyRegistrationTests` for both
/// halves of that, measured.
let hotKeyAlreadyTakenStatus = OSStatus(eventHotKeyExistsErr)

/// Why a binding is not currently working.
///
/// **Every `OSStatus` is carried, none is discarded.** A registration that
/// failed and said nothing is a shortcut that looks set in Settings and does
/// nothing when pressed — the same defect as a toggle that looks on and does
/// nothing, which this project has shipped before.
enum HotKeyRegistrationFailure: Equatable {
    /// `hotKeyBindingProblem` refused it, so it was never handed to Carbon.
    /// Carries the sentence, so the row can show the same words the recorder
    /// would have.
    case unusableBinding(String)
    /// `eventHotKeyExistsErr`. Another exclusive registrant — possibly this
    /// app's own other action.
    case alreadyTaken(OSStatus)
    /// Any other status from `RegisterEventHotKey`.
    case refused(OSStatus)
    /// `InstallEventHandler` failed, so nothing could be registered at all.
    case noEventHandler(OSStatus)

    var isUnusableBinding: Bool {
        if case .unusableBinding = self { return true }
        return false
    }

    /// The status, for a row that wants to name the number. `nil` for the one
    /// case that never reached Carbon.
    var status: OSStatus? {
        switch self {
        case .unusableBinding: return nil
        case .alreadyTaken(let status), .refused(let status), .noEventHandler(let status):
            return status
        }
    }
}

/// The global hot keys this app holds, and the one event handler that receives
/// them.
///
/// **Main thread only.** Carbon's own header says `RegisterEventHotKey`,
/// `UnregisterEventHotKey` and `InstallEventHandler` are "not thread safe", and
/// the event target these install on is the application's. Not marked
/// `@MainActor` because the C callback below is a plain function pointer that
/// has to reach back in synchronously; `perform` hops to wherever its owner
/// needs instead.
///
/// **This is the one feature in the app that cannot verify itself.** A power
/// assertion can be read back from `pmset`; a session can be listed from the
/// daemon; a hot key that is registered and never fires is indistinguishable
/// from one that fires into a handler nobody wired up. So everything between
/// the window server and the action is tested (`HotKeyDispatchTests` delivers a
/// real `kEventHotKeyPressed` to the same target and checks the action runs),
/// and the one link no test can close — the window server actually delivering a
/// human keypress — is on the manual checklist and stated as such.
final class HotKeyCenter: ObservableObject {
    /// What is wrong with each action's binding right now, for the row that set
    /// it. Empty is the healthy state.
    @Published private(set) var failures: [HotKeyAction: HotKeyRegistrationFailure] = [:]

    /// Run when a hot key fires. Set by the owner; called on the main thread,
    /// synchronously, from Carbon's dispatch.
    var perform: ((HotKeyAction) -> Void)?

    /// The four-character code in every `EventHotKeyID` this app issues.
    ///
    /// Not decoration. The application event target is process-wide and
    /// `kEventHotKeyPressed` carries only a signature and a `UInt32` id — so
    /// without checking the signature, any other hot key client living in this
    /// process (a framework, a plug-in) whose id happened to collide
    /// numerically would start or stop a session.
    static let signature: OSType = 0x4B55_484B // 'KUHK'

    /// A signature this app never issues, so a test can prove the check above
    /// is real rather than assumed.
    static let foreignSignatureForTesting: OSType = 0x5A5A_5A5A // 'ZZZZ'

    private var registrations: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    // MARK: - Applying a set of bindings

    /// Makes the live registrations match `bindings` exactly, and records why
    /// any of them could not be honoured.
    ///
    /// Everything is unregistered first rather than diffed. A diff would have
    /// to handle the case where the combination moving *onto* one action is the
    /// one moving *off* another, and getting that order wrong produces
    /// `eventHotKeyExistsErr` against yourself — a shortcut that reports a
    /// conflict with a shortcut that no longer exists. Registering two hot keys
    /// costs microseconds; the ordering bug would be permanent and would look
    /// exactly like a real conflict.
    func apply(_ bindings: [HotKeyAction: HotKeyBinding]) {
        unregisterAll()

        var newFailures: [HotKeyAction: HotKeyRegistrationFailure] = [:]
        var usable: [(HotKeyAction, HotKeyBinding)] = []

        // `allCases` order, not the dictionary's, so that two actions asking
        // for the same combination always resolve the same way round. A
        // dictionary's iteration order is not stable between runs, and a
        // conflict that lands on a different row each launch is unreportable.
        for action in HotKeyAction.allCases {
            guard let binding = bindings[action] else { continue }
            if let problem = hotKeyBindingProblem(binding) {
                // Never handed to Carbon. `RegisterEventHotKey` accepts a bare
                // key quite happily and would take it from every app on the Mac.
                newFailures[action] = .unusableBinding(problem)
                continue
            }
            usable.append((action, binding))
        }

        guard !usable.isEmpty else {
            removeEventHandler()
            failures = newFailures
            return
        }

        if let status = installEventHandlerIfNeeded() {
            for (action, _) in usable { newFailures[action] = .noEventHandler(status) }
            failures = newFailures
            return
        }

        for (action, binding) in usable {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
            // `kEventHotKeyExclusive` deliberately, and its limit is documented
            // on `hotKeyAlreadyTakenStatus`: it turns one kind of conflict into
            // an error the UI can show, and is silent about the kind users
            // actually meet.
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), binding.modifiers.carbonFlags, hotKeyID,
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)

            guard status == noErr, let reference else {
                newFailures[action] = status == hotKeyAlreadyTakenStatus
                    ? .alreadyTaken(status)
                    : .refused(status)
                continue
            }
            registrations[action] = reference
        }

        // Nothing survived, so there is nothing for the handler to deliver.
        if registrations.isEmpty { removeEventHandler() }
        failures = newFailures
    }

    /// Gives every registration back and takes the handler off the application
    /// event target.
    ///
    /// The header says the system unregisters at process termination — true,
    /// and not enough. A shortcut switched off in Settings must stop working
    /// immediately, not at the next launch, and a stale registration would go
    /// on holding the combination away from whatever the user rebinds it to.
    /// `HotKeyRegistrationTests` proves this by *behaviour*: after `stop()`,
    /// another centre can take the same combination exclusively.
    func stop() {
        unregisterAll()
        removeEventHandler()
        failures = [:]
    }

    deinit {
        // Not merely tidy. The handler holds an unretained pointer to `self`,
        // so an instance that went away without being stopped would leave
        // Carbon calling into freed memory on the next hot key of any kind.
        //
        // Routed through the same two methods rather than repeating their two
        // calls inline, so that **every** `OSStatus` this file produces is
        // still checked and logged — a failed `RemoveEventHandler` during
        // deallocation is precisely the one that leaves that dangling pointer
        // installed, and it is the last moment anything could say so. Neither
        // method touches `failures`, so nothing is published from `deinit`;
        // `stop()` is deliberately not called here for that reason.
        unregisterAll()
        removeEventHandler()
    }

    private func unregisterAll() {
        for (action, reference) in registrations {
            let status = UnregisterEventHotKey(reference)
            if status != noErr {
                appLogger.error("UnregisterEventHotKey(\(action.rawValue, privacy: .public)) failed: \(status)")
            }
        }
        registrations = [:]
    }

    /// `nil` on success. Installed lazily so that an app with no shortcuts set
    /// is not sitting on the process-wide keyboard event target at all.
    private func installEventHandlerIfNeeded() -> OSStatus? {
        guard eventHandler == nil else { return nil }
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, 1, &specification,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr, let handler else {
            appLogger.error("InstallEventHandler for hot keys failed: \(status)")
            return status
        }
        eventHandler = handler
        return nil
    }

    private func removeEventHandler() {
        guard let eventHandler else { return }
        let status = RemoveEventHandler(eventHandler)
        if status != noErr { appLogger.error("RemoveEventHandler failed: \(status)") }
        self.eventHandler = nil
    }

    /// Called from the C callback, on the main thread.
    fileprivate func dispatch(_ action: HotKeyAction) {
        perform?(action)
    }

    // MARK: - macOS's own shortcuts

    /// Every symbolic hot key macOS holds, whether or not it is switched on.
    ///
    /// This is the part of "the combination is already taken" that *is*
    /// knowable, and it is worth knowing precisely because `RegisterEventHotKey`
    /// cannot tell you: these are consumed by the window server before any
    /// registration is consulted, so the call returns `noErr` and the shortcut
    /// silently never fires. Reading the list turns the commonest silent
    /// failure — somebody picks ⌘Space or ⌘⇧4 — into something the recorder can
    /// say out loud.
    ///
    /// It does not turn *every* silent conflict into a detectable one. Another
    /// app holding the key is still invisible from here, which is why the pane
    /// carries a standing warning as well as this check.
    ///
    /// Empty on failure rather than throwing: a conflict check is advisory, and
    /// an unreadable list must not stop somebody setting a shortcut.
    static func systemShortcuts() -> [SystemShortcut] {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let entries = array?.takeRetainedValue() as? [[String: Any]] else {
            appLogger.error("CopySymbolicHotKeys failed: \(status)")
            return []
        }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  code <= UInt32(UInt16.max),
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            return SystemShortcut(keyCode: UInt16(code), carbonModifiers: modifiers,
                                  isEnabled: enabled)
        }
    }

    // MARK: - Test hooks

    var registeredActionsForTesting: [HotKeyAction] {
        HotKeyAction.allCases.filter { registrations[$0] != nil }
    }

    var hasEventHandlerForTesting: Bool { eventHandler != nil }

    /// Builds a real `kEventHotKeyPressed` and sends it to the same event
    /// target the handler is installed on.
    ///
    /// **This is not a keypress and must never be described as one.** It proves
    /// the handler is installed on the right target for the right event class
    /// and kind, decodes `EventHotKeyID` correctly, checks the signature, and
    /// dispatches to the right action — which is every link in the chain except
    /// the window server delivering a real key, and that link is the one no
    /// in-process test can close. Posting a synthetic `CGEvent` would not close
    /// it either: it goes to whatever app is frontmost, which during a test run
    /// is somebody else's window.
    @discardableResult
    func deliverSyntheticHotKeyEventForTesting(
        id: UInt32, signature: OSType = HotKeyCenter.signature
    ) -> OSStatus {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  0, EventAttributes(kEventAttributeNone), &event)
        guard created == noErr, let event else { return created }
        defer { ReleaseEvent(event) }

        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        let set = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        guard set == noErr else { return set }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}

/// The C callback. A plain function so it converts to `EventHandlerUPP` — a
/// closure that captured anything could not.
///
/// Returns `eventNotHandledErr` for anything that is not ours, which is what
/// lets other hot key clients in this process go on working.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }

    guard hotKeyID.signature == HotKeyCenter.signature,
          let action = HotKeyAction(hotKeyID: hotKeyID.id)
    else { return OSStatus(eventNotHandledErr) }

    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().dispatch(action)
    return noErr
}
