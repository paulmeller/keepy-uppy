import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PowerMonitor()

    func applicationWillTerminate(_ notification: Notification) {
        monitor.restoreSleepOnQuit()
    }
}
