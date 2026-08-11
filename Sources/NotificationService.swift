import Foundation
import UserNotifications

/// The grant, as five states this app can actually reason about.
///
/// It is **this project's own enum rather than `UNAuthorizationStatus`**, for
/// two reasons that both bite in the Settings copy:
///
/// 1. **`CaseIterable`.** The copy is written over `allCases`
///    (`notificationAuthorizationSentence`), so a state without a sentence is a
///    compile error rather than a blank line under a toggle. `UNAuthorizationStatus`
///    is an imported `NS_ENUM` and has no such conformance to write it over.
/// 2. **`.ephemeral` does not exist on macOS.** A brief that lists
///    `.notDetermined`, `.denied`, `.authorized`, `.provisional` and
///    `.ephemeral` as the states to cover is describing iOS. The SDK header on
///    this machine is explicit:
///
///        // The application is temporarily authorized to post notifications.
///        // Only available to app clips.
///        UNAuthorizationStatusEphemeral API_AVAILABLE(ios(14.0))
///            API_UNAVAILABLE(macos, watchos, tvos)
///
///    so it is not even imported here — a macOS `switch` cannot name it, and a
///    case for it would be copy nobody could ever read. What replaces it is
///    `.unknown`, where `@unknown default` lands, which covers `.ephemeral` if
///    it is ever brought to macOS *and* any sixth status a later OS adds,
///    rather than one of the two.
///
/// `.provisional` is kept, because unlike `.ephemeral` it is real on macOS
/// (10.14+). This app never *requests* it, but a state nobody requests is still
/// a state somebody can be in, and the pane has to have a sentence for it.
enum NotificationAuthorization: CaseIterable, Equatable {
    /// Nobody has been asked yet — the state every user starts in and the state
    /// most of them stay in, because this app asks only when a toggle is
    /// switched on.
    case notDetermined
    /// Asked and refused, or switched off later in System Settings.
    case denied
    case authorized
    /// Delivered quietly: straight to Notification Center, with no banner and
    /// no sound.
    case provisional
    /// A status this build does not recognise. See the `.ephemeral` note above
    /// for why this exists rather than a fifth named case.
    case unknown
}

extension NotificationAuthorization {
    /// Mapped from the framework's own enum rather than from its raw integers,
    /// so this is an exhaustive `switch` the compiler checks instead of a
    /// second list of numbers that has to agree with a header — the
    /// two-lists-that-must-agree failure this project keeps closing everywhere
    /// else. `@unknown default` is what makes a status added by a future macOS
    /// land somewhere with a sentence instead of somewhere with nothing.
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        @unknown default: self = .unknown
        }
    }
}

/// The seam between this app's notification policy and the OS.
///
/// It exists so that `SessionNotifier`, the tracker behind it and every word of
/// copy can be tested without a notification centre — which is not a
/// convenience here but a hard requirement: `xcodebuild test` hosts the test
/// bundle **inside this very app**, so anything that reached
/// `requestAuthorization` from a test would raise a real system dialog on
/// whoever ran the suite and leave a real row in System Settings →
/// Notifications.
protocol NotificationPosting {
    /// Reads the current grant. Safe — it prompts for nothing.
    func authorizationState() async -> NotificationAuthorization

    /// **The one call in this project that can raise a system dialog, and it is
    /// made from exactly one place**: a Settings toggle being switched on
    /// (`GeneralSettingsTab`). Not at launch, not on a timer, not here. A user
    /// who never turns a notification on is never asked for anything, which is
    /// what keeps the README's claim about permissions true.
    ///
    /// Answers with the resulting state rather than with the `BOOL` the
    /// framework hands back, because that `BOOL` is not the state: a user who
    /// has already denied gets `false` with no dialog, and so does an error.
    func requestAuthorization() async -> NotificationAuthorization

    func post(title: String, body: String)
}

/// The live conformer, and the only thing in the project that touches
/// UserNotifications.
///
/// **It is never constructed unless a toggle is on.** `SessionNotifier` holds a
/// *factory* and calls it only when there is something to post; the Settings
/// pane builds one only inside a toggle's action or when a toggle is already
/// on. Nothing constructs one at launch.
///
/// It holds no stored centre either: `UNUserNotificationCenter.current()` is
/// fetched inside each call, so *constructing* this type touches the framework
/// not at all, and "never constructed" and "never called" are the same
/// guarantee rather than two hopeful ones.
///
/// **No delegate is set.** `UNUserNotificationCenter.h` says the delegate "can
/// only be set from an application" and the delegate protocol requires it to be
/// set before the app finishes launching — which is precisely the launch-time
/// construction the paragraph above forbids. The consequence is worth knowing
/// and is small: macOS suppresses a banner while its app is frontmost, and this
/// is an `LSUIElement` app that is frontmost only while its own Settings window
/// is in front. A notification raised in that moment lands in Notification
/// Center without a banner rather than being lost.
struct UserNotificationService: NotificationPosting {
    private var center: UNUserNotificationCenter { .current() }

    /// **Refuses to touch UserNotifications inside XCTest — in shipping code
    /// that does not compile out.**
    ///
    /// The preference gate already makes this unreachable under test: both
    /// toggles default off, the test suite is `…keepy-uppy.tests` and empty, and
    /// `SessionNotifier` never builds a service with everything off. But that is
    /// one `defaults.set` in one future test away from not being true, and the
    /// failure mode is not a red test — it is a permission dialog on a
    /// developer's screen and a real banner in their Notification Center.
    ///
    /// Deliberately not `#if DEBUG`-gated, for the reason
    /// `PreferencesSuite.removeAllValuesForTesting`'s refusal is not: a guard
    /// that compiles out is a guard that stops protecting exactly when somebody
    /// changes the configuration. `UserNotificationServiceRefusalTests` is what
    /// proves it is live, and that test would raise a dialog if it were not.
    private var isUnderTest: Bool { PreferencesSuite.isRunningTests }

    func authorizationState() async -> NotificationAuthorization {
        guard !isUnderTest else { return .notDetermined }
        return NotificationAuthorization(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        guard !isUnderTest else { return .notDetermined }
        do {
            // `.alert` alone, deliberately. A banner is the whole feature; a
            // sound is not, and this app's sessions run overnight on Macs
            // beside beds. Asking for less is also the difference between a
            // grant a user is willing to give and one they think about.
            _ = try await center.requestAuthorization(options: [.alert])
        } catch {
            appLogger.error("notification authorization request failed: \(error.localizedDescription)")
        }
        return await authorizationState()
    }

    func post(title: String, body: String) {
        guard !isUnderTest else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // `trigger: nil` means deliver now, which is the only scheduling this
        // app wants — the event has already happened by the time we are here.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { error in
            // Fire and forget, like the agent's completion notifier: a refused
            // or undeliverable banner is a log line, never a crash and never a
            // retry loop. `add` also fails harmlessly when the grant is absent,
            // which is what "degrade honestly; never require it" reduces to at
            // this layer.
            if let error {
                appLogger.error("notification was not delivered: \(error.localizedDescription)")
            }
        }
    }
}
