import Foundation

/// Mach service name shared by helper, app, and CLI.
let helperMachServiceName = "au.com.workwireless.keepy-uppy.helper"

@objc protocol HelperProtocol {
    /// Registers this client's desire to keep the Mac awake.
    /// The helper keeps sleep disabled while any client wants it.
    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    /// The helper's view of the real system state.
    func currentState(reply: @escaping (Bool) -> Void)
    /// Helper build version, used by the app to detect version skew.
    func version(reply: @escaping (String) -> Void)
}
