import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemon = DaemonConnection()

    /// Everything decidable about a notification lives in here, tested
    /// (`Tests/SessionNotificationTests.swift`). This file's whole job is to
    /// construct it and forward what the daemon already publishes — no policy,
    /// no filtering, no thresholds.
    ///
    /// `DaemonConnection` is deliberately unchanged: it publishes the session
    /// list and the connection state already, and putting a notification
    /// concern inside the XPC client would be policy in the transport.
    let notifier = SessionNotifier()

    /// The global shortcuts, and the only thing in this app that can act
    /// without the menu being open.
    ///
    /// It holds no policy: `HotKeyCenter` knows how to register a combination
    /// and how to say why it could not, and `performHotKeyAction` below routes
    /// what fires into the same two calls the menu's own rows make. Nothing
    /// here can do something the menu cannot.
    let hotKeys = HotKeyCenter()

    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Subscribed BEFORE `daemon.start()`, and `dropFirst()` on both, and
        // both halves of that matter.
        //
        // `@Published` replays its current value to a new subscriber, and at
        // this instant `sessions` is `[]` — not "the daemon has no sessions"
        // but "nobody has asked yet". Feeding that to the tracker would spend
        // the no-baseline-on-the-first-snapshot protection on a synthetic empty
        // list, so the first *real* `listSessions` reply would diff as "every
        // live session just started" and announce a trigger session that had
        // been running for hours. Dropping it means the first real assignment
        // is the one that primes the baseline, which is exactly the rule.
        //
        // Subscribing first (rather than after `start()`) is what guarantees
        // there is a subscriber by the time that first real reply lands.
        daemon.$sessions
            .dropFirst()
            .sink { [weak self] sessions in self?.notifier.record(sessions: sessions) }
            .store(in: &subscriptions)

        // `handleDisconnect` is the single funnel for invalidation,
        // interruption and a mid-call XPC error alike, and it is where
        // `isConnected` goes false — so this is the one place that sees every
        // way the connection can break. `refresh()` returns early on a failed
        // call and leaves `sessions` at its stale value, so the outage is
        // invisible in the published array and this subscription is the only
        // thing that can catch it.
        daemon.$isConnected
            .dropFirst()
            .sink { [weak self] connected in
                guard !connected else { return }
                self?.notifier.forgetSnapshot()
            }
            .store(in: &subscriptions)

        daemon.start()
        startHotKeys()
    }

    /// **Nothing is bound unless the launch environment names it, and there is
    /// deliberately no preference behind this yet.**
    ///
    /// A stored binding is what the next task adds. Until then the only way to
    /// arm one is an environment variable, because the alternative is not
    /// merely untidy: `PreferencesSuite.name` is the *production* domain
    /// outside XCTest, the installed app reads it live through `@AppStorage`,
    /// and a stored binding outlives the process that wrote it. A "temporary
    /// default" written from a development build would therefore arm an
    /// arbitrary global shortcut in the user's shipping app and leave it armed
    /// after the development build quit — the header's promise that the system
    /// unregisters at termination ends the *registration*, not the *binding*.
    ///
    /// `#if DEBUG` as well as an environment variable, so a Release build
    /// cannot be driven this way at all.
    private func startHotKeys() {
        hotKeys.perform = { [weak self] action in
            // Carbon dispatches on the main thread, but `perform` is not
            // main-actor-isolated (it is called from a C function pointer), so
            // the hop is stated rather than assumed.
            Task { @MainActor in self?.performHotKeyAction(action) }
        }
        #if DEBUG
        let bindings = hotKeyDebugBindings(in: ProcessInfo.processInfo.environment)
        guard !bindings.isEmpty else { return }
        appLogger.log("Applying \(bindings.count) development hot key binding(s) from the environment")
        hotKeys.apply(bindings)
        for (action, failure) in hotKeys.failures {
            appLogger.error("Hot key \(action.rawValue, privacy: .public) not registered: \(String(describing: failure))")
        }
        #endif
    }

    /// Both arms call exactly what `MenuContent`'s own rows call.
    ///
    /// The `notifier.appWillStop` line is not optional garnish: it is marked
    /// **before** the call and synchronously, so that the commonest way for the
    /// last session to end — this very keystroke — cannot produce a banner
    /// explaining the keystroke back to the person who just made it. The menu's
    /// Stop rows do the same thing for the same reason.
    private func performHotKeyAction(_ action: HotKeyAction) {
        switch action {
        case .startDefaultSession:
            let start = MenuDefaultStart(readingFrom: PreferencesSuite.defaults)
            appLogger.log("Hot key: starting the menu's default session")
            Task {
                await daemon.startSession(kind: start.sessionKind(now: Date()),
                                          power: start.power)
            }
        case .stopAppSessions:
            // Exactly the set `stopAllSessions(all: false)` will end —
            // `SessionIsolation` scopes it to this client's own `ClientID`,
            // which is what `.thisApp` means. This user's own trigger and
            // command-line sessions are deliberately not in it; see
            // `HotKeyAction.stopAppSessions`.
            let userID = UInt32(getuid())
            let mine = daemon.sessions.filter {
                menuSessionGroup(for: $0, userID: userID) == .thisApp
            }
            appLogger.log("Hot key: stopping \(mine.count) session(s) started from the menu")
            notifier.appWillStop(sessionIDs: mine.map(\.id))
            Task { await daemon.stopAllSessions(all: false) }
        }
    }
}
