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

    /// Thin wrapper over `xpcCall` (Shared/XPCCall.swift), which owns the
    /// resume-exactly-once and timeout mechanics both XPC clients need. What
    /// stays here is the part that is genuinely this client's: turning a
    /// failed call into a disconnect, and treating a real reply as the only
    /// positive evidence the connection is live —
    /// `remoteObjectProxyWithErrorHandler` hands back a proxy quite happily
    /// for a connection that is about to fail.
    private func call<T>(
        _ send: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T? {
        guard let connection else {
            isConnected = false
            return nil
        }

        let result: T? = await xpcCall(on: connection, timeout: Self.callTimeout,
                                       logger: appLogger, send)

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

    /// The `Session` this app asks the daemon to start — the *request*, whose
    /// `id`, `owner`, `ownerUID` and `startedAt` the daemon overwrites
    /// server-side (`Session.authorized(id:owner:ownerUID:startedAt:)`), and
    /// whose remaining fields are the actual ask.
    ///
    /// It is a separate, testable function rather than four lines inside
    /// `startSession` for one reason: `wakeMode` is one of exactly three
    /// `Session` fields with a memberwise default, so omitting it from a
    /// construction site is not a compile error — it silently substitutes
    /// `.clamshell`. That omission *was* here, which is why every session this
    /// app started ignored the mode entirely, and the identical omission has
    /// now been made and fixed twice more on two other lines
    /// (`SessionEngine`'s lease renewal, `HelperService`'s trust split). Both
    /// of those were closed by pairing one copy with one whole-struct test;
    /// this is the third and last construction site in the app, closed the same
    /// way by `DaemonConnectionRequestTests`.
    nonisolated static func requestedSession(
        kind: SessionKind, wakeMode: WakeMode,
        persistence: SessionPersistence, origin: SessionOrigin, now: Date = Date()
    ) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "app"),
                persistence: persistence, origin: origin, startedAt: now,
                wakeMode: wakeMode)
    }

    /// `wakeMode` has **no default**, unlike `persistence` and `origin`, and
    /// that asymmetry is deliberate: the two defaulted fields are visible in
    /// the UI if they are wrong, whereas a session that quietly stopped being
    /// lid-safe looks exactly like one that still is.
    @discardableResult
    func startSession(kind: SessionKind, wakeMode: WakeMode,
                      persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual) async -> Bool {
        let session = Self.requestedSession(kind: kind, wakeMode: wakeMode,
                                            persistence: persistence, origin: origin)
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
        let _: Int? = await call { proxy, reply in
            proxy.stopAllSessions(all: all) { stopped, _ in reply(stopped) }
        }
        await refresh()
    }
}
