import Foundation
import os

let helperLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.helper", category: "helper")

/// Serialises all state behind one queue: XPC replies arrive on arbitrary threads.
final class HelperState {
    private let queue = DispatchQueue(label: "au.com.workwireless.keepy-uppy.helper.state")
    private var table = ClientTable<ObjectIdentifier>()

    /// Called at daemon startup: converge to the safe state before serving
    /// anyone, so a helper crash can never strand the Mac awake (spec §6).
    func resetToSafeState() {
        queue.sync {
            PowerControl.setSleepDisabled(false)
            helperLogger.log("Helper started; forced sleep enabled as safe baseline")
        }
    }

    func set(_ id: ObjectIdentifier, wantsAwake: Bool) -> Bool {
        queue.sync {
            table.set(id, wantsAwake: wantsAwake)
            return applyLocked()
        }
    }

    func remove(_ id: ObjectIdentifier) {
        queue.sync {
            table.remove(id)
            helperLogger.log("Client disconnected; \(self.table.clientCount) remain")
            _ = applyLocked()
        }
    }

    func currentState() -> Bool {
        queue.sync { PowerControl.sleepDisabled() }
    }

    private func applyLocked() -> Bool {
        let desired = table.desiredKeepAwake
        let ok = PowerControl.setSleepDisabled(desired)
        helperLogger.log("Applied keepAwake=\(desired) success=\(ok)")
        return ok
    }
}

final class HelperService: NSObject, HelperProtocol {
    private let state: HelperState
    private let clientID: ObjectIdentifier

    init(state: HelperState, clientID: ObjectIdentifier) {
        self.state = state
        self.clientID = clientID
    }

    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        let ok = state.set(clientID, wantsAwake: enabled)
        reply(ok, ok ? nil : "Failed to apply power setting")
    }

    func currentState(reply: @escaping (Bool) -> Void) {
        reply(state.currentState())
    }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
