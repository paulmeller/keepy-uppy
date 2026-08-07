import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

// `ContinuationLatch` — the "resume exactly once, from the reply block or the
// error handler, whichever arrives" primitive this file's `call` depends on —
// now lives in `Shared/ContinuationLatch.swift`, because `Agent`'s parallel
// XPC client needs the identical guarantee and the two must not drift. See
// that file for why.

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

    /// How long a single XPC call may wait before the daemon is treated as
    /// unreachable. Generous against a local round-trip (normally well under
    /// a millisecond) while still bounding the damage from an unresponsive
    /// daemon: each stuck call now ends after this, instead of pinning a
    /// task forever. Longer than `pollInterval`, so two polls can briefly
    /// overlap while one is timing out — harmless, since `refresh()` only
    /// assigns published state and the latch makes each call resume once.
    private static let callTimeout: Duration = .seconds(5)

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
        // `helperMachServiceName` is now the APP-ONLY service (its pinned
        // requirement narrowed to the app's bundle identifier alone when the
        // CLI moved to its own service); both the service and the pinned
        // requirement here are deliberately unchanged.
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            // Pins the PEER (the daemon), not this process's own identity —
            // `setCodeSigningRequirement` validates the other end of the
            // connection. The daemon's *inbound* requirement for this service
            // (`SigningRequirement.appRequirement`) deliberately excludes the
            // daemon's own identifier, so pinning an inbound requirement here
            // would reject the daemon on the first real message.
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

            // Resuming on reply-or-error is not sufficient on its own. A
            // daemon that is *registered but never successfully spawns*
            // (launchd owns the Mach port and keeps retrying the exec)
            // accepts the connection and queues the message, then neither
            // replies nor reports an error — so the reply block and the
            // error handler below both stay silent and the continuation
            // waits forever. Found by running the real signed build against
            // exactly that state, which the unit tests could not produce
            // because they only ever saw "service not registered at all",
            // which does fail fast. The latch makes this a safe race:
            // whichever path arrives first wins and the loser is a no-op.
            let timeout = Task {
                try? await Task.sleep(for: Self.callTimeout)
                guard !Task.isCancelled else { return }
                appLogger.error("XPC call timed out; treating the daemon as unreachable")
                latch.resume(nil)
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                appLogger.error("XPC error: \(error.localizedDescription)")
                timeout.cancel()
                latch.resume(nil)
            } as? HelperProtocol
            guard let proxy else {
                timeout.cancel()
                return latch.resume(nil)
            }
            send(proxy) { value in
                timeout.cancel()
                latch.resume(value)
            }
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
            proxy.stopAllSessions(all: all) { stopped, _ in reply(stopped >= 0) }
        }
        await refresh()
    }
}
