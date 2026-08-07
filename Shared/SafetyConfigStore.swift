import Foundation

/// Shared with the Settings Safety tab (plan 3). Same suite as
/// `TriggerStore` (plan 2) — `au.com.workwireless.keepy-uppy` — deliberately;
/// this is not a second, separate suite.
///
/// `UserDefaults(suiteName:)` returns `nil` when `suiteName` equals the
/// *calling process's own* bundle identifier (an Apple-documented special
/// case, not a bug in this code) — and that is exactly the app target's
/// bundle identifier here (`au.com.workwireless.keepy-uppy`, see
/// `project.yml`). So from the app process (where the Settings UI this
/// store exists for actually runs), `UserDefaults(suiteName: suiteName)`
/// is nil and `.standard` is the correct fallback: for this exact
/// degenerate case `.standard` resolves to the identical underlying
/// preferences file suite-named lookup would have used, so the daemon
/// (bundle id `...helper`, unaffected by this case) and CLI still read
/// back whatever the app wrote. Confirmed empirically via
/// `SafetyConfigStoreTests`, which runs inside the app process as the
/// test host and would silently no-op on save/load without this fallback.
enum SafetyConfigStore {
    private static let suiteName = "au.com.workwireless.keepy-uppy"
    private static let key = "safetyConfig"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

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
}
