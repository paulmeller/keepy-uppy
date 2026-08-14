import Foundation

/// The five tabs, as a value rather than five `.tabItem` calls in a row.
///
/// It exists because search has to be able to *name* a destination, and until
/// now the tabs were anonymous positions in a `TabView`. Being `CaseIterable`
/// is also what lets the index below be checked for completeness by a test
/// rather than by eye.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, triggers, display, safety, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .triggers: return "Triggers"
        case .display: return "Display"
        case .safety: return "Safety & Guards"
        case .advanced: return "CLI & Advanced"
        }
    }

    /// Verified available at this project's 13.0 target, for the reason the tab
    /// bar's own comment gives: an unavailable SF Symbol renders as nothing at
    /// all, with no warning and no crash.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .triggers: return "bolt"
        case .display: return "display"
        case .safety: return "exclamationmark.shield"
        case .advanced: return "terminal"
        }
    }
}

/// One findable setting: what it is called, where it lives, and the words
/// somebody might look for it under.
///
/// `keywords` is the whole point. People do not search for the label — they
/// search for the *problem*. "hot", "throttle" and "temperature" all have to
/// find a control actually labelled "Overheating", and "password" has to find
/// the honest answer that this app cannot change the lock screen, rather than
/// nothing at all.
struct SettingsIndexEntry: Equatable {
    let title: String
    let tab: SettingsTab
    let keywords: [String]
}

/// Everything the Settings window can be searched for.
///
/// Hand-maintained, and that is a known cost — a sixth control added without a
/// line here is a control search cannot find. It is a list of *labels*, not of
/// behaviour, so it cannot be derived from the types the way
/// `TriggerConditionKind.allCases` is; `testEveryTabIsReachableFromSearch`
/// catches a whole tab going missing, which is the failure worth automating.
let settingsIndex: [SettingsIndexEntry] = [
    .init(title: "Launch at login", tab: .general,
          keywords: ["startup", "login item", "boot", "start automatically"]),
    .init(title: "Background services", tab: .general,
          keywords: ["daemon", "agent", "enable", "root", "privileged", "helper", "install"]),
    .init(title: "Default session", tab: .general,
          keywords: ["duration", "how long", "indefinite", "hours", "menu default"]),
    .init(title: "Notifications", tab: .general,
          keywords: ["notify", "banner", "alert", "announce", "when a session ends"]),

    .init(title: "Triggers", tab: .triggers,
          keywords: ["rule", "automatic", "automation", "when", "condition"]),
    .init(title: "Schedule", tab: .triggers,
          keywords: ["time of day", "weekdays", "weekend", "recurring", "9 to 5", "office hours", "calendar"]),
    .init(title: "On session end", tab: .triggers,
          keywords: ["script", "webhook", "hook", "post", "run a command", "finished"]),

    .init(title: "Wake mode", tab: .display,
          keywords: ["lid", "clamshell", "closed", "screen", "display sleep", "keep screen on"]),
    .init(title: keepDisksAwakeSettingsTitle, tab: .display,
          keywords: ["disk", "drive", "spin down", "external", "volume", "idle"]),
    .init(title: menuBarIconSettingsTitle, tab: .display,
          keywords: ["icon", "menu bar", "balloon", "appearance", "symbol", "status item"]),

    .init(title: "Overheating", tab: .safety,
          keywords: ["hot", "heat", "thermal", "temperature", "throttle", "fan"]),
    .init(title: "Battery", tab: .safety,
          keywords: ["power", "percent", "low battery", "cutoff", "charge"]),
    .init(title: "Maximum length", tab: .safety,
          keywords: ["limit", "backstop", "too long", "forgot", "time limit", "session limit"]),

    .init(title: "Install command line tool", tab: .advanced,
          keywords: ["cli", "path", "terminal", "usr local bin", "symlink", "keepy-uppy command"]),
    .init(title: "Keyboard shortcuts", tab: .advanced,
          keywords: ["hot key", "hotkey", "shortcut", "keystroke", "binding"]),
    .init(title: "Diagnostics", tab: .advanced,
          keywords: ["log", "version", "debug", "issue", "report a bug", "support"]),
]

/// Matches on the title first, then the keywords, and returns nothing for a
/// blank query.
///
/// Case- and diacritic-insensitive, and matched on *substrings* rather than
/// whole words: somebody typing "therm" has not finished the word yet, and a
/// search that waits for "thermal" is a search that looks broken while you use
/// it. Title matches sort above keyword matches so that typing an exact label
/// puts it first, which is the one ordering guarantee worth having.
func searchSettings(_ query: String, in index: [SettingsIndexEntry] = settingsIndex)
    -> [SettingsIndexEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }

    func contains(_ haystack: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    let byTitle = index.filter { contains($0.title) }
    let byKeyword = index.filter { entry in
        !contains(entry.title) && entry.keywords.contains(where: contains)
    }
    return byTitle + byKeyword
}
