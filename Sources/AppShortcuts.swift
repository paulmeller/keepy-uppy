import AppIntents
import AppKit
import Foundation

/// Shortcuts support, via App Intents rather than an AppleScript dictionary.
///
/// **Why App Intents and not an `.sdef`.** Both reach the same audience — the
/// people automating a Mac who are not going to open a terminal — but only one
/// of them composes with Shortcuts, Focus filters and Automations, and only one
/// is still gaining surface area. An `.sdef` would also be a second, parallel
/// description of every verb the CLI already has, maintained by hand, which is
/// the two-lists-that-must-agree shape this project closes everywhere else.
///
/// **These run in the app's process and use the app's own connection**, which
/// is the whole reason they are correct rather than merely convenient: the
/// daemon scopes every session to the client that asked (`"<role>-<uid>"`), so
/// a session started from Shortcuts is the *app's* session. It appears in the
/// menu with a Stop button, the stop shortcut ends it, and quitting the app
/// ends it — exactly as if the row had been clicked. An intent that opened its
/// own XPC connection would create sessions the menu could see and never stop,
/// which is the "shows you a session it can't stop" state the UI already has to
/// explain once and should not have to explain twice.
///
/// Nothing here asks for a permission. Shortcuts needs no grant to run an
/// intent, so "nothing in Keepy Uppy needs a privacy permission to work" stays
/// true with this in the build.
@MainActor
private func appDaemon() throws -> DaemonConnection {
    // `NSApp.delegate` rather than a singleton on `DaemonConnection`: the app
    // owns exactly one connection and it is already reachable, and a second
    // static would be a second lifetime to reason about for no gain.
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
        throw KeepyUppyIntentError.appNotReady
    }
    return delegate.daemon
}

enum KeepyUppyIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case daemonRefused
    case daemonUnreachable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Keepy Uppy is still starting up. Try again in a moment."
        case .daemonRefused:
            // Deliberately does not guess *why*. The daemon refuses a start for
            // reasons this side cannot see — a safety guard is suppressing
            // automation, the per-user cap is reached — and inventing one here
            // would be the same lie the notification copy refuses to tell.
            return "Keepy Uppy could not start a session. Check Settings → Safety & Guards, or run keepy-uppy status for what the daemon says."
        case .daemonUnreachable:
            // Thrown rather than answered, because the alternative is a
            // confident wrong answer. A Shortcut branching on "is this Mac
            // awake" would take the wrong branch, and a Shortcut told "nothing
            // was stopped" would believe sessions had ended that are still
            // running.
            return "Keepy Uppy could not reach its background service, so it cannot say what this Mac is doing. Check Settings → General."
        }
    }
}

/// How long a Shortcuts-started session should last.
///
/// The menu's four choices, not an arbitrary number of minutes. A free-form
/// duration would be a fifth way to express something the menu, the CLI and the
/// trigger sheet already express three ways, and `DefaultSessionKind` is the
/// list all three read.
enum ShortcutDuration: String, AppEnum {
    case indefinitely, oneHour, fourHours, eightHours

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Duration" }

    static var caseDisplayRepresentations: [ShortcutDuration: DisplayRepresentation] = [
        .indefinitely: "Indefinitely",
        .oneHour: "For 1 hour",
        .fourHours: "For 4 hours",
        .eightHours: "For 8 hours",
    ]

    var sessionKind: DefaultSessionKind {
        switch self {
        case .indefinitely: return .indefinite
        case .oneHour: return .oneHour
        case .fourHours: return .fourHours
        case .eightHours: return .eightHours
        }
    }
}

struct KeepAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription(
        "Starts a session that keeps this Mac awake, using the wake mode picked in Settings → Display.",
        categoryName: "Sessions")

    /// No `openAppWhenRun`: this app is a menu bar item with no window worth
    /// bringing forward, and a Shortcut that yanks focus to nothing is a
    /// Shortcut people stop using.
    static var openAppWhenRun = false

    @Parameter(title: "Duration", default: .indefinitely)
    var duration: ShortcutDuration

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let daemon = try appDaemon()
        // `MenuDefaultStart` is the type the global hot key already reads for
        // this, so a Shortcut, a keystroke and the menu's first row all start
        // the same session. Only the duration is overridden, because that is
        // the one thing the Shortcut was given.
        let stored = MenuDefaultStart(readingFrom: PreferencesSuite.defaults)
        let started = await daemon.startSession(
            kind: duration.sessionKind.sessionKind(now: Date()),
            power: stored.power)
        guard started else { throw KeepyUppyIntentError.daemonRefused }
        return .result(dialog: "Keeping this Mac awake.")
    }
}

struct StopKeepingAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Keeping Mac Awake"
    static var description = IntentDescription(
        "Ends the sessions this app started, including ones a Shortcut started. Command-line and other accounts' sessions are left alone.",
        categoryName: "Sessions")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let daemon = try appDaemon()
        // `all: false` — the same scope as the menu's stop row and the stop hot
        // key. A Shortcut that swept away a `keepy-uppy on` session from a
        // build script would be a surprise nobody asked for, and the wording
        // above promises it does not.
        guard let stopped = await daemon.stopAllSessions(all: false) else {
            throw KeepyUppyIntentError.daemonUnreachable
        }
        // Three literal returns rather than one ternary. `IntentDialog` is
        // built from a *literal* — a ternary hands it an already-formed
        // `String`, which does not convert, and whether that compiles turns out
        // to depend on the Xcode version. It also gets the plural right, which
        // an inline `s` never quite does.
        if stopped == 0 {
            return .result(dialog: "Nothing this app started was keeping the Mac awake.")
        }
        if stopped == 1 {
            return .result(dialog: "Stopped 1 session.")
        }
        return .result(dialog: "Stopped \(stopped) sessions.")
    }
}

struct IsKeepingAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Mac Being Kept Awake"
    static var description = IntentDescription(
        "Answers whether anything is keeping this Mac awake, including sessions from the command line, a trigger, or another account.",
        categoryName: "Sessions")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let daemon = try appDaemon()
        guard await daemon.refresh() else {
            throw KeepyUppyIntentError.daemonUnreachable
        }
        let awake = daemon.keepingAwake
        if awake {
            return .result(value: true, dialog: "This Mac is being kept awake.")
        }
        return .result(value: false, dialog: "This Mac is not being kept awake.")
    }
}

struct KeepyUppyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: KeepAwakeIntent(),
                    phrases: ["Keep \(.applicationName) awake",
                              "Start \(.applicationName)"],
                    shortTitle: "Keep Awake",
                    systemImageName: "sun.max")
        AppShortcut(intent: StopKeepingAwakeIntent(),
                    phrases: ["Stop \(.applicationName)"],
                    shortTitle: "Stop Keeping Awake",
                    systemImageName: "moon.zzz")
        AppShortcut(intent: IsKeepingAwakeIntent(),
                    phrases: ["Is \(.applicationName) keeping this Mac awake"],
                    shortTitle: "Is Mac Awake",
                    systemImageName: "questionmark.circle")
    }
}
