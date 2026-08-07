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

    /// Matches the app client's bound. `EvidenceLoopRunner.tick()` calls in
    /// here every 5s for the whole login session, so an unbounded wait is the
    /// difference between one slow tick and a permanently-stranded task per
    /// tick for days.
    private static let callTimeout: Duration = .seconds(5)

    /// Deliberately longer than the app's 3s. The app's reconnect races its
    /// own 3s UI poll, so healing within one refresh cycle is what makes a
    /// daemon restart invisible; this client is a headless observer on a 5s
    /// evidence loop, where a slightly later retry costs nothing.
    private let reconnectDelay: TimeInterval = 5

    func connect() {
        let new = NSXPCConnection(machServiceName: agentMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
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

        // Fire-and-forget, and deliberately not routed through `call` below:
        // nothing awaits a continuation here, so there is nothing to leak, and
        // failing registration is not by itself evidence the connection is
        // dead — the invalidation/interruption handlers above are what report
        // that. It still gets its own error handler so a registration that
        // never reaches the daemon is logged rather than silently dropped.
        let proxy = new.remoteObjectProxyWithErrorHandler { error in
            agentLogger.error("registerAsAgent XPC error: \(error.localizedDescription)")
        } as? HelperProtocol
        proxy?.registerAsAgent { ok, message in
            if !ok { agentLogger.error("registerAsAgent rejected: \(message ?? "unknown")") }
        }
    }

    /// Tears down `failed` and schedules a reconnect. Idempotent and scoped:
    /// invalidation, interruption, and a mid-call XPC error can all report the
    /// same break, and only the first one to arrive does the work.
    ///
    /// Previously took no argument and unconditionally cleared `connection`,
    /// so a late invalidation callback from a connection that had already been
    /// replaced tore down the live replacement — and it never called
    /// `invalidate()`, so an *interrupted* connection (which stays alive) was
    /// leaked outright when the reference was dropped.
    private func handleDisconnect(_ failed: NSXPCConnection?) {
        guard let current = connection, current === failed else { return }
        connection = nil
        // Interruption leaves the connection object alive; dropping the
        // reference without invalidating would leak it. Invalidating may
        // re-enter this method via `invalidationHandler`, which the guard
        // above already makes a no-op.
        current.invalidate()

        let delay = reconnectDelay
        agentLogger.log("Daemon connection lost; reconnecting shortly")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// Sends one XPC message and awaits its reply, resolving to `nil` if the
    /// connection breaks instead of hanging forever.
    ///
    /// This replaces a `proxy()` helper whose error handler only logged. That
    /// shape had no way to reach the continuation that was actually pending,
    /// so a connection breaking mid-call left every `withCheckedContinuation`
    /// below unresumed — and `EvidenceLoopRunner.tick()` calls `listSessions`
    /// every 5s for the entire login session, so each tick after a break
    /// leaked one more permanently-suspended `Task` in a process designed to
    /// run for days. Building the proxy *per call* is what fixes it: the error
    /// handler closes over that call's own latch, so the failure path resumes
    /// the very continuation the success path would have.
    private func call<T>(
        _ send: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T? {
        guard let connection else { return nil }
        let result: T? = await xpcCall(on: connection, timeout: Self.callTimeout,
                                       logger: agentLogger, send)
        if result == nil { handleDisconnect(connection) }
        return result
    }

    func startSession(_ session: Session) async -> (id: String?, error: String?) {
        guard let data = try? JSONEncoder().encode(session) else { return (nil, "encode failed") }
        let result: (id: String?, error: String?)? = await call { proxy, reply in
            proxy.startSession(data) { sessionID, error in
                if let sessionID { reply((id: sessionID, error: nil)) }
                else { reply((id: nil, error: error ?? "unknown")) }
            }
        }
        // Unchanged from the pre-fix behaviour for an unusable connection; the
        // difference is that a connection breaking *mid-call* now lands here
        // too, rather than never returning at all.
        return result ?? (id: nil, error: "not connected")
    }

    func reportConditionEnded(_ sessionID: String) async -> Bool {
        let ok: Bool? = await call { proxy, reply in
            proxy.reportConditionEnded(sessionID) { ok, _ in reply(ok) }
        }
        return ok ?? false
    }

    /// The double optional is load-bearing, not an accident. `T` is
    /// `[Session]?` so that "the reply arrived but would not decode" (inner
    /// nil) stays distinguishable from "the connection broke" (outer nil):
    /// only the latter may tear the connection down, and a decode failure must
    /// not be reported to `call` as a disconnection. Both still collapse to
    /// `nil` for the caller, exactly as before — `EvidenceLoopRunner.tick()`
    /// skips the tick rather than treating an unreadable reply as "no sessions
    /// are running", which would let triggers fire against a stale view.
    func listSessions() async -> [Session]? {
        let sessions: [Session]?? = await call { proxy, reply in
            proxy.listSessions { data, _ in
                reply(data.flatMap { try? JSONDecoder().decode([Session].self, from: $0) })
            }
        }
        return sessions ?? nil
    }
}
