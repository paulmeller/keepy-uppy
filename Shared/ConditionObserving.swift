import Foundation

// MARK: - Observing protocols shared between the agent's evidence loop
// (Agent/EvidenceLoop.swift) and the pure trigger evaluator
// (Shared/TriggerRule.swift). Declared here, not in
// Agent/ConditionObservers.swift, because Shared/ compiles into every
// target — including the daemon and CLI — which must not gain those live
// implementations' AppKit/CoreGraphics dependency. The live implementations
// (SystemAppRunningObserver, SystemDisplayObserver) stay in
// Agent/ConditionObservers.swift.

protocol AppRunningObserving {
    func isRunning(bundleID: String) -> Bool
}

protocol DisplayObserving {
    func hasExternalDisplay() -> Bool
}

/// Unlike `AppRunningObserving`, which matches a bundle ID against
/// `NSWorkspace.runningApplications`, this matches a plain executable name
/// (e.g. `claude`, `codex`) against the live process table — for CLI tools
/// that have no bundle ID or `NSRunningApplication` entry at all. Exact-name
/// matching only: no path, no arguments. A generic name (`pi`, `agent`) can
/// therefore match an unrelated process of the same name — the Settings UI
/// warns on the two presets where that's a realistic risk.
protocol ProcessRunningObserving {
    func isRunning(processName: String) -> Bool
}
