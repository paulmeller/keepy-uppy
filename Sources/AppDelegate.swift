import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemon = DaemonConnection()

    func applicationDidFinishLaunching(_ notification: Notification) {
        daemon.start()
    }
}
