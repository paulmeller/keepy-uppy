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
    }
}
