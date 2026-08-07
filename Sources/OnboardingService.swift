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
    @Published private(set) var daemonStatus: ServiceStatus = .notRegistered
    @Published private(set) var agentStatus: ServiceStatus = .notRegistered

    func refresh() {
        daemonStatus = ServiceStatus(SMAppService.daemon(plistName: "au.com.workwireless.keepy-uppy.helper.plist").status)
        agentStatus = ServiceStatus(SMAppService.agent(plistName: "au.com.workwireless.keepy-uppy.agent.plist").status)
    }

    func enable() {
        do { try SMAppService.daemon(plistName: "au.com.workwireless.keepy-uppy.helper.plist").register() }
        catch { appLogger.error("daemon register failed: \(error.localizedDescription)") }
        do { try SMAppService.agent(plistName: "au.com.workwireless.keepy-uppy.agent.plist").register() }
        catch { appLogger.error("agent register failed: \(error.localizedDescription)") }
        refresh()
        if daemonStatus == .requiresApproval || agentStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
