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
}
