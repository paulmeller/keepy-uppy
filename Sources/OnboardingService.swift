import Foundation
import ServiceManagement

enum ServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

@MainActor
final class OnboardingService: ObservableObject {
    /// The single answer to "are the background services usable?", derived
    /// once here. The Settings pane previously worked it out three separate
    /// times — for the badge, the button, and the footnote — which let them
    /// disagree if only one was updated.
    enum State { case running, needsApproval, notEnabled }

    var state: State {
        if daemonStatus == .enabled && agentStatus == .enabled { return .running }
        if daemonStatus == .requiresApproval || agentStatus == .requiresApproval { return .needsApproval }
        return .notEnabled
    }

    @Published private(set) var daemonStatus: ServiceStatus = .notRegistered
    @Published private(set) var agentStatus: ServiceStatus = .notRegistered

    func refresh() {
        daemonStatus = ServiceStatus(SMAppService.daemon(plistName: helperPlistName).status)
        agentStatus = ServiceStatus(SMAppService.agent(plistName: agentPlistName).status)
    }

    func enable() {
        do { try SMAppService.daemon(plistName: helperPlistName).register() }
        catch { appLogger.error("daemon register failed: \(error.localizedDescription)") }
        do { try SMAppService.agent(plistName: agentPlistName).register() }
        catch { appLogger.error("agent register failed: \(error.localizedDescription)") }
        refresh()
        if daemonStatus == .requiresApproval || agentStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
