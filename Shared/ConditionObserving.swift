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
