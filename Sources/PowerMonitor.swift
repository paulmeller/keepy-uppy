import Foundation
import UserNotifications

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var sleepState: SleepState = .unknown
    @Published private(set) var batteryState = BatteryState(percentage: nil, source: .unknown)
    @Published private(set) var loginItemEnabled = false

    private let syncInterval: Duration = .seconds(30)
    private let lowBatteryThreshold = 10
    private var syncTask: Task<Void, Never>?
    // One attempt per low-battery episode: without this latch, an unanswered
    // admin prompt would re-fire on every 30-second tick until the battery
    // died. Reset once the machine is charging or back above the threshold.
    private var hasAttemptedAutoOff = false

    init() {
        requestNotificationAuthorization()
        syncTask = Task { [weak self] in
            await self?.refresh()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.syncInterval)
                await self.refresh()
                await self.checkLowBatteryAutoOff()
            }
        }
    }

    deinit {
        syncTask?.cancel()
    }

    // pmset/osascript calls block until their process exits — in the toggle
    // case, for as long as the admin password dialog is on screen — so every
    // PowerService call hops off the main actor via Task.detached and only
    // the published-property writes happen back here (spec §2).
    func refresh() async {
        let (sleep, battery) = await Task.detached {
            ((try? PowerService.readSleepState()) ?? .unknown,
             (try? PowerService.readBatteryState()) ?? BatteryState(percentage: nil, source: .unknown))
        }.value
        sleepState = sleep
        batteryState = battery
        loginItemEnabled = LoginItemService.status() == .enabled
    }

    func toggle() {
        let target = sleepState != .disabled
        Task {
            await Task.detached {
                do {
                    try PowerService.setSleepDisabled(target)
                } catch let error as PowerError where error.isUserCancelled {
                    // Deliberate cancel: silent no-op by design (spec §3).
                } catch {
                    print("keepy-uppy: failed to toggle sleep state: \(error)")
                }
            }.value
            await refresh()
        }
    }

    func toggleLoginItem() {
        do {
            if loginItemEnabled {
                try LoginItemService.unregister()
            } else {
                try LoginItemService.register()
            }
        } catch {
            print("keepy-uppy: failed to update login item: \(error)")
        }
        loginItemEnabled = LoginItemService.status() == .enabled
    }

    // Blocking the main thread is correct here: this runs inside
    // applicationWillTerminate and must finish before the process exits.
    // State is re-read fresh rather than taken from the cached property,
    // which can be up to 30 seconds stale if sleep was disabled externally
    // (source-of-truth rule, spec §2).
    func restoreSleepOnQuit() {
        guard (try? PowerService.readSleepState()) == .disabled else { return }
        try? PowerService.setSleepDisabled(false)
    }

    private func checkLowBatteryAutoOff() async {
        let isLow = batteryState.source == .battery
            && batteryState.percentage.map { $0 < lowBatteryThreshold } ?? false
        guard isLow else {
            hasAttemptedAutoOff = false
            return
        }
        guard sleepState == .disabled, !hasAttemptedAutoOff else { return }
        hasAttemptedAutoOff = true

        await Task.detached {
            try? PowerService.setSleepDisabled(false)
        }.value
        await refresh()
        // Only claim success if sleep actually came back on — the admin
        // prompt may have been cancelled or left unanswered (spec §4's
        // known limitation), and a "re-enabled" notification would then lie.
        postLowBatteryNotification(reEnabled: sleepState == .enabled)
    }

    private func requestNotificationAuthorization() {
        // Skip under XCTest: xcodegen auto-hosts the test bundle in the app,
        // so `xcodebuild test` launches this whole app — and a TCC permission
        // dialog popping mid-test-run would stall the suite.
        guard NSClassFromString("XCTestCase") == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postLowBatteryNotification(reEnabled: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Keepy Uppy"
        content.body = reEnabled
            ? "Battery below \(lowBatteryThreshold)% — sleep re-enabled automatically."
            : "Battery below \(lowBatteryThreshold)% — couldn't re-enable sleep. Approve the prompt or plug in."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
