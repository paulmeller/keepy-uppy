import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

/// Guarantees a `CheckedContinuation` is resumed exactly once, from
/// whichever of two mutually-exclusive-in-theory callbacks actually fires.
///
/// Every XPC call below has two possible completions: the reply block, or
/// the proxy's error handler. NSXPC invokes exactly one of them per message,
/// but they arrive on arbitrary XPC queues, and a `CheckedContinuation`
/// resumed twice traps at runtime — crashing the menu-bar app is a strictly
/// worse outcome than the hang this class exists to prevent. So the "exactly
/// once" property is enforced here rather than assumed, under a lock because
/// neither callback is guaranteed to be on the main actor.
private final class ContinuationLatch<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@MainActor
final class DaemonConnection: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var keepingAwake = false
    @Published private(set) var isConnected = false

    private var connection: NSXPCConnection?
    private var pollTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    /// Matches the poll interval below rather than the agent's 5s: the agent
    /// is a headless observer where a slightly later retry costs nothing,
    /// whereas here the poll timer is what actually re-populates the UI, so
    /// aligning the two means a daemon restart heals within roughly one
    /// refresh cycle instead of straddling two.
    private let reconnectDelay: TimeInterval = 3
    private let pollInterval: TimeInterval = 3

    func start() {
        connect()
        // Refresh immediately: `Timer.scheduledTimer` does not fire on
        // schedule, so without this the menu shows its default empty state
        // for a full poll interval after launch.
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func connect() {
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            // Pins the PEER (the daemon), not this process's own identity —
            // `setCodeSigningRequirement` validates the other end of the
            // connection. `SigningRequirement.requirement` is the *inbound*
            // requirement the daemon applies to its clients, and it
            // deliberately excludes the daemon's own identifier, so pinning
            // it here rejects the daemon on the first real message.
            new.setCodeSigningRequirement(SigningRequirement.helperRequirement)
        }
        // Both handlers capture the connection they belong to, so a late
        // callback from a connection we already replaced can never tear down
        // the live one.
        new.invalidationHandler = { [weak self, weak new] in
            Task { @MainActor in self?.handleDisconnect(new) }
        }
        new.interruptionHandler = { [weak self, weak new] in
            Task { @MainActor in self?.handleDisconnect(new) }
        }
        new.resume()
        connection = new
    }

    /// Tears down `failed` and schedules a reconnect. Idempotent and scoped:
    /// invalidation, interruption, and a mid-call XPC error can all report
    /// the same break, and only the first one to arrive does the work.
    ///
    /// Without the reconnect the app was permanently dead after a daemon
    /// restart — `isConnected` went false and nothing ever rebuilt the
    /// connection (final whole-branch review, Item 2).
    private func handleDisconnect(_ failed: NSXPCConnection?) {
        guard let current = connection, current === failed else { return }
        connection = nil
        isConnected = false
        // Interruption leaves the connection object alive; dropping the
        // reference without invalidating would leak it. Invalidating may
        // re-enter this method via `invalidationHandler`, which the guard
        // above already makes a no-op.
        current.invalidate()

        let delay = reconnectDelay
        appLogger.log("Daemon connection lost; reconnecting shortly")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// Sends one XPC message and awaits its reply, resolving to `nil` if the
    /// connection breaks instead of hanging forever.
    ///
    /// This is the core of Item 2. The old shape — a `proxy()` helper whose
    /// error handler only logged and flipped `isConnected` — had no way to
    /// reach the continuation that was actually pending, so a connection
    /// that broke mid-call left every `withCheckedContinuation` below
    /// unresumed. The 3s poll timer then started a fresh, equally stuck
    /// `refresh()` task every tick, leaking one task per tick for the
    /// lifetime of the app. Building the proxy *per call* is what fixes it:
    /// the error handler closes over that call's own latch, so the failure
    /// path resumes the very continuation the success path would have.
    ///
    /// A non-nil result is also the only thing that sets `isConnected` true,
    /// since a real reply is the only positive evidence the connection is
    /// live — `remoteObjectProxyWithErrorHandler` returns a proxy happily
    /// for a connection that is about to fail.
    private func call<T>(
        _ send: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T? {
        guard let connection else {
            isConnected = false
            return nil
        }

        let result: T? = await withCheckedContinuation { continuation in
            let latch = ContinuationLatch<T?>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                appLogger.error("XPC error: \(error.localizedDescription)")
                latch.resume(nil)
            } as? HelperProtocol
            guard let proxy else { return latch.resume(nil) }
            send(proxy) { latch.resume($0) }
        }

        if result == nil {
            handleDisconnect(connection)
        } else {
            isConnected = true
        }
        return result
    }

    func refresh() async {
        guard let state: Bool = await call({ proxy, reply in
            proxy.currentState { reply($0) }
        }) else { return }
        keepingAwake = state

        guard let list: [Session] = await call({ proxy, reply in
            proxy.listSessions { data, _ in
                guard let data, let decoded = try? JSONDecoder().decode([Session].self, from: data) else {
                    // The reply arrived, so the connection is live — an
                    // undecodable payload is an empty list, not a
                    // disconnection.
                    return reply([])
                }
                reply(decoded)
            }
        }) else { return }
        sessions = list
    }

    @discardableResult
    func startSession(kind: SessionKind, persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual) async -> Bool {
        let session = Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "app"),
                              persistence: persistence, origin: origin, startedAt: Date())
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let ok: Bool? = await call { proxy, reply in
            proxy.startSession(data) { sessionID, error in
                if let error { appLogger.error("startSession failed: \(error)") }
                reply(sessionID != nil)
            }
        }
        await refresh()
        return ok ?? false
    }

    func stopSession(_ id: UUID) async {
        let _: Bool? = await call { proxy, reply in
            proxy.stopSession(id.uuidString) { ok, _ in reply(ok) }
        }
        await refresh()
    }

    func stopAllSessions(all: Bool) async {
        let _: Bool? = await call { proxy, reply in
            proxy.stopAllSessions(all: all) { ok, _ in reply(ok) }
        }
        await refresh()
    }
}
