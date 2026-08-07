import Foundation
import ServiceManagement

func connect() -> HelperProtocol? {
    let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    if SigningRequirement.isEnforced {
        // Pins the PEER (the daemon), not this process's own identity —
        // `setCodeSigningRequirement` validates the other end of the
        // connection. `SigningRequirement.requirement` is the *inbound*
        // requirement the daemon applies to its clients, and it deliberately
        // excludes the daemon's own identifier, so pinning it here rejects
        // the daemon on the first real message.
        connection.setCodeSigningRequirement(SigningRequirement.helperRequirement)
    }
    connection.resume()
    return connection.remoteObjectProxyWithErrorHandler { error in
        FileHandle.standardError.write("keepy-uppy: \(error.localizedDescription)\n".data(using: .utf8)!)
    } as? HelperProtocol
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("keepy-uppy: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let ownerID = ClientID(rawValue: "cli-\(ProcessInfo.processInfo.processIdentifier)")

let command: CLICommand
switch parseCLIArguments(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error): fail(error.message)
}

guard let proxy = connect() else { fail("could not connect to the Keepy Uppy daemon") }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

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
    proxy.stopAllSessions(all: true) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .off(.own):
    proxy.stopAllSessions(all: false) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
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
