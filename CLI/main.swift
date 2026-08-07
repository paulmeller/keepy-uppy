import Foundation
import ServiceManagement

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

func connect() -> HelperProtocol? {
    // The CLI-ONLY Mach service, never the app's. That is what makes the
    // daemon see this process as the CLI, and therefore what gives every
    // `keepy-uppy` invocation by this user the same stable `ClientID` — the
    // thing `off` with no flags needs in order to match sessions a previous
    // invocation started (`ClientRole.clientID(forUserID:)`).
    let connection = NSXPCConnection(machServiceName: cliMachServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    if SigningRequirement.isEnforced {
        // Unchanged, and still correct: this pins the PEER (the daemon), not
        // this process's own identity — `setCodeSigningRequirement` validates
        // the other end of the connection. The daemon's *inbound* requirement
        // for this service (`SigningRequirement.cliRequirement`) deliberately
        // excludes the daemon's own identifier, so pinning an inbound
        // requirement here would reject the daemon on the first real message.
        connection.setCodeSigningRequirement(SigningRequirement.helperRequirement)
    }
    connection.resume()
    return connection.remoteObjectProxyWithErrorHandler { error in
        FileHandle.standardError.write("keepy-uppy: \(error.localizedDescription)\n".data(using: .utf8)!)
        // End the wait here rather than letting the 10s timeout deliver it.
        // A connection error is already conclusive, and the slow path is most
        // likely to be hit exactly when a client and daemon disagree about
        // which Mach services exist — the mixed-version window during an
        // upgrade — where a 10s stall reads as a hang.
        exitCode = 1
        semaphore.signal()
    } as? HelperProtocol
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("keepy-uppy: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// A placeholder only. `HelperService.startSession` overwrites `owner` with
// the identity it derived server-side from the accepting listener's role and
// the peer's authenticated uid, and never trusts this field — so despite the
// superficially similar shape, this is NOT the `"cli-<uid>"` id this process's
// sessions end up owned by (`ClientRole.clientID(forUserID:)`). It is kept
// only because `Session` requires a non-optional `owner` to encode.
let ownerID = ClientID(rawValue: "cli-pid-\(ProcessInfo.processInfo.processIdentifier)")

let command: CLICommand
switch parseCLIArguments(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error): fail(error.message)
}

guard let proxy = connect() else { fail("could not connect to the Keepy Uppy daemon") }

switch command {
case .on(let kind, let persistence):
    let session = Session(id: UUID(), kind: kind, owner: ownerID, persistence: persistence,
                          origin: .manual, startedAt: Date(), triggerID: nil)
    guard let data = try? JSONEncoder().encode(session) else { fail("internal error encoding session") }
    proxy.startSession(data) { sessionID, error in
        if let sessionID {
            print("Started session \(sessionID)")
        } else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!)
            exitCode = 1
        }
        semaphore.signal()
    }

case .off(.all):
    proxy.stopAllSessions(all: true) { stopped, error in
        if let error {
            FileHandle.standardError.write("keepy-uppy: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        } else if stopped == 0 {
            print("No sessions were running.")
        } else {
            print("Stopped \(stopped) session(s).")
        }
        semaphore.signal()
    }

case .off(.own):
    proxy.stopAllSessions(all: false) { stopped, error in
        if let error {
            FileHandle.standardError.write("keepy-uppy: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        } else if stopped == 0 {
            print("No sessions of yours were running.")
        } else {
            print("Stopped \(stopped) session(s).")
        }
        semaphore.signal()
    }

case .off(.session(let id)):
    proxy.stopSession(id) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .status(let json):
    proxy.currentState { disabled in
        if json {
            print("{\"keepingAwake\": \(disabled)}")
        } else {
            print(disabled ? "keeping awake" : "normal sleep")
        }
        semaphore.signal()
    }

case .sessions:
    proxy.listSessions { data, error in
        guard let data, let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed to list sessions")\n".data(using: .utf8)!)
            exitCode = 1
            semaphore.signal()
            return
        }
        if sessions.isEmpty {
            print("No active sessions.")
        } else {
            for session in sessions {
                print("\(session.id)  \(session.kind)  origin=\(session.origin.rawValue)")
            }
        }
        semaphore.signal()
    }

case .setup:
    // Unlike the branches above, this doesn't talk to the daemon over XPC
    // at all — SMAppService registration is a separate, synchronous call.
    // There's no async completion handler to signal the semaphore from, so
    // this branch does the work inline and signals immediately itself,
    // falling through to the same wait/exit epilogue as every other branch
    // rather than exiting early or leaving the semaphore unsignaled (which
    // would hang the process for the full 10s timeout).
    func registerAndReport(_ label: String, _ service: SMAppService) -> Bool {
        do {
            try service.register()
        } catch {
            FileHandle.standardError.write("keepy-uppy: \(label) registration failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            exitCode = 1
            return false
        }
        switch service.status {
        case .enabled:
            print("\(label): registered")
        case .requiresApproval:
            print("\(label): requires approval — run 'keepy-uppy setup' again after approving in System Settings")
            return true
        default:
            print("\(label): \(service.status)")
        }
        return false
    }

    let daemonNeedsApproval = registerAndReport(
        "Daemon", SMAppService.daemon(plistName: "au.com.workwireless.keepy-uppy.helper.plist"))
    let agentNeedsApproval = registerAndReport(
        "Agent", SMAppService.agent(plistName: "au.com.workwireless.keepy-uppy.agent.plist"))

    if daemonNeedsApproval || agentNeedsApproval {
        SMAppService.openSystemSettingsLoginItems()
    }

    semaphore.signal()

case .reset:
    // Same shape as `.setup` above — synchronous SMAppService work, no XPC,
    // so it signals the semaphore itself and falls through to the shared
    // epilogue. `unregister()` is deliberately routed through SMAppService
    // rather than documented as `sudo launchctl bootout`: smd performs the
    // privileged eviction on the user's behalf, so a wedged daemon is
    // recoverable without root.
    func unregisterAndReport(_ label: String, _ service: SMAppService) {
        do {
            try service.unregister()
            print("\(label): unregistered")
        } catch {
            // Not-registered is the expected, benign case when recovering a
            // half-installed state, and is worth reporting as success rather
            // than an error the user has to interpret.
            if service.status == .notRegistered || service.status == .notFound {
                print("\(label): not registered")
            } else {
                FileHandle.standardError.write("keepy-uppy: \(label) unregister failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exitCode = 1
            }
        }
    }

    unregisterAndReport("Daemon", SMAppService.daemon(plistName: "au.com.workwireless.keepy-uppy.helper.plist"))
    unregisterAndReport("Agent", SMAppService.agent(plistName: "au.com.workwireless.keepy-uppy.agent.plist"))
    print("Run 'keepy-uppy setup' to register again.")

    semaphore.signal()
}

let waitResult = semaphore.wait(timeout: .now() + 10)
if waitResult == .timedOut {
    FileHandle.standardError.write("keepy-uppy: timed out waiting for the daemon\n".data(using: .utf8)!)
    exitCode = 1
}
exit(exitCode)
