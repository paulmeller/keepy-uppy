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
}
