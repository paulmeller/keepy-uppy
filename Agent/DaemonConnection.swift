import Foundation
import os

let agentLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.agent", category: "agent")

/// The agent's XPC client. Connects to the daemon's AGENT-ONLY Mach
/// service — never the general one — so the daemon's structural role
/// derivation (plan 1, spec §4) sees this process as the agent.
@MainActor
final class DaemonConnection {
    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?

    func connect() {
        let new = NSXPCConnection(machServiceName: agentMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            new.setCodeSigningRequirement(SigningRequirement.helperRequirement)
        }
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.resume()
        connection = new

        proxy()?.registerAsAgent { ok, message in
            if !ok { agentLogger.error("registerAsAgent rejected: \(message ?? "unknown")") }
        }
    }

    private func handleDisconnect() {
        connection = nil
        agentLogger.log("Daemon connection lost; reconnecting in 5s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func proxy() -> HelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            agentLogger.error("XPC error: \(error.localizedDescription)")
        } as? HelperProtocol
    }

    func startSession(_ session: Session) async -> (id: String?, error: String?) {
        guard let data = try? JSONEncoder().encode(session) else { return (nil, "encode failed") }
        return await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: (nil, "not connected")) }
            proxy.startSession(data) { sessionID, error in
                if let sessionID { continuation.resume(returning: (sessionID, nil)) }
                else { continuation.resume(returning: (nil, error ?? "unknown")) }
            }
        }
    }

    func reportConditionEnded(_ sessionID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: false) }
            proxy.reportConditionEnded(sessionID) { ok, _ in continuation.resume(returning: ok) }
        }
    }

    func listSessions() async -> [Session]? {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: nil) }
            proxy.listSessions { data, _ in
                guard let data, let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: sessions)
            }
        }
    }
}
