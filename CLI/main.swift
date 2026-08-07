import Foundation

func connect() -> HelperProtocol? {
    let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    if SigningRequirement.isEnforced {
        connection.setCodeSigningRequirement(SigningRequirement.requirement)
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
}

_ = semaphore.wait(timeout: .now() + 10)
exit(exitCode)
