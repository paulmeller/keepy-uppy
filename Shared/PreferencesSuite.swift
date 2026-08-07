import Foundation

/// The single `UserDefaults` suite every Keepy Uppy process shares —
/// trigger rules, safety config, and the menu's default-session preference
/// all live here, written by the app and read back by the daemon, agent, and
/// CLI. The app is not sandboxed, so every process sharing the bundle-id
/// prefix can read and write it without entitlements.
///
/// Named once, here, because it used to be hardcoded independently in four
/// places (`TriggerStore`, `SafetyConfigStore`, and two `@AppStorage(store:)`
/// call sites in the UI). A typo in any one of them would not fail to
/// compile and would not throw — it would silently create a second,
/// disconnected preferences domain, so the Settings UI would appear to work
/// while nothing else ever saw what it wrote. That is not a hypothetical
/// failure mode in this project: the `.standard` fallback documented below
/// exists because a closely-related silent-no-op `UserDefaults(suiteName:)`
/// bug already shipped here once and had to be root-caused empirically
/// (final whole-branch review, Item 5).
enum PreferencesSuite {
    /// Deliberately identical to the app target's `PRODUCT_BUNDLE_IDENTIFIER`
    /// (see `project.yml`) — that is what makes `defaults` below need its
    /// fallback.
    static let name = "au.com.workwireless.keepy-uppy"

    /// `UserDefaults(suiteName:)` returns `nil` when `suiteName` equals the
    /// *calling process's own* bundle identifier (an Apple-documented special
    /// case, not a bug in this code) — and `name` is exactly the app
    /// target's bundle identifier. So from the app process, where all the
    /// Settings UI runs, the suite-named lookup is nil and `.standard` is the
    /// correct fallback: for this exact degenerate case `.standard` resolves
    /// to the identical underlying preferences file the suite-named lookup
    /// would have used, so the daemon (bundle id `...helper`, unaffected by
    /// this case), agent, and CLI still read back whatever the app wrote.
    /// Confirmed empirically via `SafetyConfigStoreTests`, which runs inside
    /// the app process as its test host and silently no-ops on save/load
    /// without this fallback.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: name) ?? .standard
    }

    // MARK: - Reading another user's copy of this suite (root daemon only)

    /// `defaults` above — like `UserDefaults` generally — has no user
    /// parameter at all: it only ever resolves the *calling process's own*
    /// effective user's preference domain. That is right for the app, agent,
    /// and CLI, which all run as the console user. It is wrong for the
    /// helper, which is a root `LaunchDaemon`: there it resolves to root's
    /// own `/var/root/Library/Preferences/` domain, which nothing ever
    /// writes, so every value read back is the built-in default. That made
    /// Settings → Safety a complete silent no-op daemon-side until the final
    /// whole-branch review caught it. Everything below exists so the daemon
    /// can name the user whose preferences should govern it.
    ///
    /// The account's login name and home directory, or nil when `userID` has
    /// no account. Uses `getpwuid_r` rather than `getpwuid` deliberately:
    /// `getpwuid` returns a pointer into a per-process static buffer that any
    /// other thread's lookup can overwrite mid-read. `DaemonRuntime` only
    /// calls this from its own serial queue, but nothing stops a framework
    /// on another thread from calling `getpwuid` concurrently, and the
    /// consequence in a *root* daemon — resolving the wrong login name and
    /// reading the wrong user's safety config — is worth ten lines to rule
    /// out. Verified thread-safe empirically: 320k concurrent lookups across
    /// 16 threads returned zero mismatches.
    static func account(forUserID userID: uid_t) -> (userName: String, homeDirectory: String)? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let configured = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: configured > 0 ? Int(configured) : 4096)
        let status = getpwuid_r(userID, &entry, &buffer, buffer.count, &result)
        // `result` is NULL (with status 0) when there simply is no such
        // account — the documented "not found" signal, distinct from an error.
        guard status == 0, result != nil else { return nil }
        return (String(cString: entry.pw_name), String(cString: entry.pw_dir))
    }

    /// Reads `key` straight out of `homeDirectory`'s on-disk copy of this
    /// suite, bypassing the preferences daemon entirely.
    ///
    /// This is tried *before* `data(forKey:userName:)` below, which inverts
    /// the obvious order, so the reason matters. `CFPreferencesCopyValue` is
    /// the API documented for this job and it demonstrably honours an
    /// explicit user name — but it is served by `cfprefsd`, and the root
    /// daemon is served by a *different* `cfprefsd` instance than the one
    /// that owns the console user's domain. Whether that instance serves,
    /// refuses, or indefinitely caches another user's domain could not be
    /// tested here (this machine has exactly one non-system account and no
    /// passwordless root), so it is the one link in the chain with no
    /// evidence behind it. Reading the file has no such unknown: root
    /// bypasses the `0600` mode on `~/Library/Preferences/*.plist`, and
    /// `FileManager` caches nothing. Its only cost is staleness — `cfprefsd`
    /// flushes a `UserDefaults` write to disk on its own schedule, measured
    /// here at 5.9s, and `UserDefaults.synchronize()` does not force it —
    /// which is immaterial for a config the daemon re-polls every 5s anyway.
    /// A bounded, self-healing few seconds of lag beats an unbounded,
    /// unverifiable risk of reading nothing at all.
    static func data(forKey key: String, inHomeDirectory homeDirectory: String) -> Data? {
        let path = (homeDirectory as NSString)
            .appendingPathComponent("Library/Preferences/\(name).plist")
        guard let contents = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                  from: contents, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary[key] as? Data
    }

    /// Reads `key` from `userName`'s copy of this suite via CoreFoundation.
    ///
    /// The host argument must be `kCFPreferencesAnyHost`, not
    /// `kCFPreferencesCurrentHost`: `UserDefaults` writes to the any-host
    /// domain (`~/Library/Preferences/<id>.plist`), whereas current-host is
    /// the separate by-host domain (`~/Library/Preferences/ByHost/`) that
    /// nothing here ever writes. Verified — reading this suite back with
    /// `kCFPreferencesCurrentHost` returns nil for a value `UserDefaults`
    /// had just written, while `kCFPreferencesAnyHost` returns it.
    ///
    /// Also verified: the user name is genuinely resolved rather than
    /// ignored — passing a name with no account returns nil instead of
    /// falling back to the caller's own domain — so this cannot silently
    /// serve root its own (empty) preferences when asked for someone else's.
    static func data(forKey key: String, userName: String) -> Data? {
        CFPreferencesCopyValue(
            key as CFString, name as CFString,
            userName as CFString, kCFPreferencesAnyHost) as? Data
    }
}
