import Foundation

/// Shared with the Settings Safety tab (plan 3). Same suite as
/// `TriggerStore` (plan 2) — `PreferencesSuite` — deliberately; this is not
/// a second, separate suite. That constant is also where the `.standard`
/// fallback and the reason it is required are documented; the suite name was
/// hardcoded separately here until the final whole-branch review (Item 5)
/// consolidated it.
enum SafetyConfigStore {
    private static let key = "safetyConfig"

    private static var defaults: UserDefaults { PreferencesSuite.defaults }

    static func load() -> SafetyConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(SafetyConfig.self, from: data)
        else { return .default }
        return config
    }

    static func save(_ config: SafetyConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Reading a specific user's config (root daemon only)

    /// The config **`userID` saved**, rather than the one belonging to
    /// whichever user the calling process happens to run as.
    ///
    /// `load()` above is correct for the app, agent, and CLI and wrong for
    /// the helper, which runs as root and therefore reads root's own empty
    /// preference domain — see `PreferencesSuite.account(forUserID:)` for
    /// the full account of that bug. `DaemonRuntime` calls this instead,
    /// naming the user whose signed agent is currently connected.
    ///
    /// Returns nil — not `.default` — when there is nothing to read: no such
    /// account, no saved config, or a config that will not decode. The
    /// distinction matters to the caller, which keeps the last config it
    /// successfully loaded rather than silently reverting a user's chosen
    /// safety settings to the defaults on a transient read failure.
    static func load(forUserID userID: uid_t) -> SafetyConfig? {
        guard let account = PreferencesSuite.account(forUserID: userID) else { return nil }
        return load(fromHomeDirectory: account.homeDirectory)
            ?? load(forUserNamed: account.userName)
    }

    /// The on-disk half of `load(forUserID:)`, split out so it can be tested
    /// against a purpose-built home directory. See
    /// `PreferencesSuite.data(forKey:inHomeDirectory:)` for why this is tried
    /// first.
    static func load(fromHomeDirectory homeDirectory: String) -> SafetyConfig? {
        decode(PreferencesSuite.data(forKey: key, inHomeDirectory: homeDirectory))
    }

    /// The CoreFoundation half of `load(forUserID:)`, split out for the same
    /// reason — and testable directly, because reading the *current* user's
    /// domain by explicit name exercises exactly the same call the daemon
    /// makes for a different user.
    static func load(forUserNamed userName: String) -> SafetyConfig? {
        decode(PreferencesSuite.data(forKey: key, userName: userName))
    }

    private static func decode(_ data: Data?) -> SafetyConfig? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SafetyConfig.self, from: data)
    }
}
