import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

@MainActor
final class DaemonConnection: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var keepingAwake = false
    @Published private(set) var isConnected = false

    private var connection: NSXPCConnection?
    private var pollTimer: Timer?

    func start() {
        connect()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func connect() {
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            new.setCodeSigningRequirement(SigningRequirement.requirement)
        }
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.isConnected = false }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.isConnected = false }
        }
        new.resume()
        connection = new
    }

    private func proxy() -> HelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            appLogger.error("XPC error: \(error.localizedDescription)")
            Task { @MainActor in self?.isConnected = false }
        } as? HelperProtocol
    }

    func refresh() async {
        guard let proxy = proxy() else { return }
        isConnected = true

        let state: Bool = await withCheckedContinuation { continuation in
            proxy.currentState { continuation.resume(returning: $0) }
        }
        keepingAwake = state

        let list: [Session] = await withCheckedContinuation { continuation in
            proxy.listSessions { data, _ in
                guard let data, let decoded = try? JSONDecoder().decode([Session].self, from: data) else {
                    return continuation.resume(returning: [])
                }
                continuation.resume(returning: decoded)
            }
        }
        sessions = list
    }

    @discardableResult
    func startSession(kind: SessionKind, persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual) async -> Bool {
        guard let proxy = proxy() else { return false }
        let session = Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "app"),
                              persistence: persistence, origin: origin, startedAt: Date())
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let ok: Bool = await withCheckedContinuation { continuation in
            proxy.startSession(data) { sessionID, error in
                if let error { appLogger.error("startSession failed: \(error)") }
                continuation.resume(returning: sessionID != nil)
            }
        }
        await refresh()
        return ok
    }

    func stopSession(_ id: UUID) async {
        guard let proxy = proxy() else { return }
        _ = await withCheckedContinuation { continuation in
            proxy.stopSession(id.uuidString) { ok, _ in continuation.resume(returning: ok) }
        }
        await refresh()
    }

    func stopAllSessions(all: Bool) async {
        guard let proxy = proxy() else { return }
        _ = await withCheckedContinuation { continuation in
            proxy.stopAllSessions(all: all) { ok, _ in continuation.resume(returning: ok) }
        }
        await refresh()
    }
}
