# Keepy Uppy (Swift) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Keepy Uppy as a native Swift/SwiftUI macOS app: a signed, notarizable menu-bar app that keeps a MacBook awake with the lid closed by toggling `pmset -a disablesleep`.

**Architecture:** An Xcode project with a system-logic layer with no SwiftUI/AppKit dependency (`PowerService.swift` for `pmset`/`osascript`, `LoginItemService.swift` for `SMAppService`), a single `ObservableObject` (`PowerMonitor`) holding all published UI state and the 30-second sync loop, and a thin SwiftUI shell (`MenuBarExtra` + a minimal `AppDelegate` for the one lifecycle hook SwiftUI's `App` protocol doesn't expose). Every published state update comes from re-reading real `pmset` output — never from an assumption about what a prior command did.

**Tech Stack:** Swift 5 / SwiftUI (macOS 13+ `MenuBarExtra`), Foundation `Process` for `pmset`/`osascript`, `ServiceManagement.SMAppService`, `UserNotifications`, `xcodegen` for non-interactive project generation, `xcodebuild`/`notarytool`/`hdiutil` for build and distribution, orchestrated through `just`.

## Global Constraints

- Target macOS 13+ (Ventura) — `deploymentTarget: "13.0"` in `project.yml`, `LSMinimumSystemVersion` `13.0` in `Info.plist`. This is the floor for both `SMAppService` and `MenuBarExtra`.
- Requires Xcode + Xcode Command Line Tools, and **`xcodegen`** (`brew install xcodegen`). `xcodegen` is a new tooling dependency not mentioned in the spec's packaging section — it's used because `.xcodeproj` has no supported way to be created non-interactively from a script, and hand-writing a `.pbxproj` file directly is fragile and error-prone. `xcodegen` produces a completely normal `.xcodeproj` from a checked-in `project.yml`; once generated, it opens and behaves in Xcode exactly like a project created through the New Project wizard.
- Naming: bundle id `au.com.workwireless.keepy-uppy`; Xcode project `Keepy Uppy.xcodeproj`; app target and scheme both named `Keepy Uppy`; test target `Keepy UppyTests`; Swift module name pinned explicitly to `KeepyUppy` (via `PRODUCT_MODULE_NAME`) so `@testable import KeepyUppy` doesn't depend on Xcode's automatic space-to-underscore sanitization of the product name.
- Privilege model: every privileged state change goes through `osascript -e '... with administrator privileges'` via `Process`, producing the native macOS auth dialog. No sudoers modification, no privileged helper daemon (spec §5).
- Every `xcodebuild` invocation in this plan uses `-derivedDataPath build` for a predictable, repo-local output location (`build/Build/Products/...`) instead of Xcode's default per-user DerivedData path. Add `build/`, `*.xcuserstate`, and `xcuserdata/` to `.gitignore` in Task 1.
- `xcodegen generate` assigns fresh internal UUIDs to `.xcodeproj` contents on every run. Expect the committed `.xcodeproj` to show as a full-file diff each time a task adds new source files and re-runs `generate` — this is expected `xcodegen` behavior, not corruption.
- Testing: `PowerService`'s parsing functions are pure and unit-tested via XCTest, run with `xcodebuild test`. Everything touching SwiftUI/AppKit/`SMAppService`/`UNUserNotificationCenter` cannot be unit-tested; each such task's "test" step is `xcodebuild build` plus a manual check, accumulated into the README's checklist in Task 9.
- Unlike the Rust/`objc2` version of this plan, none of the APIs used here needed independent source verification — `MenuBarExtra`, `NSApplicationDelegateAdaptor`, `SMAppService`, `UNUserNotificationCenter`, and `Process` are all stable, first-party, extensively documented Apple APIs. There is no "known API risk" section in this plan.

---

### Task 1: Project scaffold

**Files:**
- Create: `project.yml`
- Create: `Sources/KeepyUppyApp.swift`
- Create: `Resources/Info.plist`
- Create: `.gitignore`

**Interfaces:**
- Produces: a buildable, runnable `Keepy Uppy.xcodeproj` with a single app target showing a static balloon icon in the menu bar with a placeholder menu. Later tasks add files to `Sources/` and must re-run `xcodegen generate` to pick them up.

- [ ] **Step 1: Create `.gitignore`**

```
build/
*.xcuserstate
xcuserdata/
DerivedData/
```

- [ ] **Step 2: Create `project.yml`**

```yaml
name: Keepy Uppy
options:
  createIntermediateGroups: true
targets:
  Keepy Uppy:
    type: application
    platform: macOS
    deploymentTarget: "13.0"
    sources:
      - Sources
    info:
      path: Resources/Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: au.com.workwireless.keepy-uppy
        PRODUCT_MODULE_NAME: KeepyUppy
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        SWIFT_VERSION: "5.0"
schemes:
  Keepy Uppy:
    build:
      targets:
        Keepy Uppy: all
    run:
      config: Debug
    archive:
      config: Release
```

- [ ] **Step 3: Create `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Keepy Uppy</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Keepy Uppy</string>
</dict>
</plist>
```

`CFBundleIconName` references an `AppIcon` asset catalog entry that doesn't exist until Task 8 — harmless until then, the OS just falls back to a generic app icon.

- [ ] **Step 4: Create `Sources/KeepyUppyApp.swift`**

```swift
import SwiftUI

@main
struct KeepyUppyApp: App {
    var body: some Scene {
        MenuBarExtra("Keepy Uppy", systemImage: "balloon") {
            Text("Keepy Uppy is starting up…")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 5: Generate the Xcode project and build**

Run: `xcodegen generate`
Expected: `Generated project at Keepy Uppy.xcodeproj`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manually verify the smoke test**

Run: `open "build/Build/Products/Debug/Keepy Uppy.app"`
Expected: no Dock icon appears (confirming `LSUIElement` took effect); a balloon icon appears in the menu bar; clicking it shows a menu with "Keepy Uppy is starting up…". Quit via `killall "Keepy Uppy"` (no real Quit item exists yet — added in Task 7).

- [ ] **Step 7: Commit**

```bash
git add .gitignore project.yml "Keepy Uppy.xcodeproj" Sources/KeepyUppyApp.swift Resources/Info.plist
git commit -m "Scaffold Keepy Uppy Xcode project via xcodegen"
```

---

### Task 2: `PowerService` — sleep-state parsing

**Files:**
- Create: `Sources/PowerService.swift`
- Create: `Tests/PowerServiceTests.swift`
- Modify: `project.yml` (add the `Keepy UppyTests` target and wire it into the scheme's `test:` action)

**Interfaces:**
- Produces: `enum SleepState: Equatable { case disabled, enabled, unknown }`; `enum PowerService { static func parseSleepDisabled(_ output: String) -> SleepState }`.

- [ ] **Step 1: Add the test target to `project.yml`**

Add a second target under `targets:`:

```yaml
  Keepy UppyTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "13.0"
    sources:
      - Tests
    dependencies:
      - target: Keepy Uppy
```

Replace the `schemes:` block to wire the test target into the "Keepy Uppy" scheme:

```yaml
schemes:
  Keepy Uppy:
    build:
      targets:
        Keepy Uppy: all
        Keepy UppyTests: [test]
    run:
      config: Debug
    test:
      targets:
        - Keepy UppyTests
    archive:
      config: Release
```

- [ ] **Step 2: Write the failing tests**

Create `Sources/PowerService.swift`:

```swift
import Foundation

enum SleepState: Equatable {
    case disabled
    case enabled
    case unknown
}

enum PowerService {
    static func parseSleepDisabled(_ output: String) -> SleepState {
        fatalError("not implemented")
    }
}
```

Create `Tests/PowerServiceTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class PowerServiceSleepStateTests: XCTestCase {
    func testParsesDisabledState() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.disabledOutput), .disabled)
    }

    func testDefaultsToEnabledWhenLineAbsent() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.defaultOutput), .enabled)
    }

    func testUnknownStateOnUnexpectedValue() {
        XCTAssertEqual(PowerService.parseSleepDisabled(Self.malformedOutput), .unknown)
    }

    static let disabledOutput = """
    System-wide power settings:
     SleepDisabled      1
    Currently in use:
     standbydelaylow      10
     sleep                 1
     hibernatemode         3
     lidwake               1
    """

    static let defaultOutput = """
    Currently in use:
     standbydelaylow      10
     sleep                 10
     hibernatemode         3
     lidwake               1
    """

    static let malformedOutput = """
    System-wide power settings:
     SleepDisabled      maybe
    Currently in use:
     sleep                 10
    """
}
```

- [ ] **Step 3: Regenerate the project and run the tests to verify they fail**

Run: `xcodegen generate`

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: build fails or crashes at `fatalError("not implemented")` — the tests do not pass yet.

- [ ] **Step 4: Implement `parseSleepDisabled`**

Replace the `fatalError` body in `Sources/PowerService.swift`:

```swift
enum PowerService {
    static func parseSleepDisabled(_ output: String) -> SleepState {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.first == "SleepDisabled" else { continue }
            guard parts.count > 1 else { return .unknown }
            switch parts[1] {
            case "1": return .disabled
            case "0": return .enabled
            default: return .unknown
            }
        }
        return .enabled
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 6: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Sources/PowerService.swift Tests/PowerServiceTests.swift
git commit -m "Add pmset SleepDisabled parsing with XCTest target"
```

---

### Task 3: `PowerService` — battery parsing

**Files:**
- Modify: `Sources/PowerService.swift`
- Modify: `Tests/PowerServiceTests.swift`

**Interfaces:**
- Produces: `enum PowerSource: Equatable { case battery, acPower, unknown }`; `struct BatteryState: Equatable { let percentage: Int?; let source: PowerSource }`; `static func parseBattery(_ output: String) -> BatteryState` on `PowerService`.

- [ ] **Step 1: Write the failing tests**

Add to `Sources/PowerService.swift`, above `enum PowerService`:

```swift
enum PowerSource: Equatable {
    case battery
    case acPower
    case unknown
}

struct BatteryState: Equatable {
    let percentage: Int?
    let source: PowerSource
}
```

Add inside `enum PowerService`:

```swift
    static func parseBattery(_ output: String) -> BatteryState {
        fatalError("not implemented")
    }
```

Add to `Tests/PowerServiceTests.swift`:

```swift
final class PowerServiceBatteryTests: XCTestCase {
    func testParsesDischargingBattery() {
        let state = PowerService.parseBattery(Self.batteryDischarging)
        XCTAssertEqual(state.source, .battery)
        XCTAssertEqual(state.percentage, 87)
    }

    func testParsesChargedOnAC() {
        let state = PowerService.parseBattery(Self.acCharged)
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 100)
    }

    func testDesktopMacHasNoPercentage() {
        let state = PowerService.parseBattery(Self.acNoBattery)
        XCTAssertEqual(state.source, .acPower)
        XCTAssertNil(state.percentage)
    }

    static let batteryDischarging = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4325027)\t87%; discharging; 3:48 remaining present: true\n"
    static let acCharged = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4325027)\t100%; charged; 0:00 remaining present: true\n"
    static let acNoBattery = "Now drawing from 'AC Power'\n"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: crash at `fatalError("not implemented")`.

- [ ] **Step 3: Implement `parseBattery`**

Replace the `fatalError` body:

```swift
    static func parseBattery(_ output: String) -> BatteryState {
        let source: PowerSource
        if output.contains("'Battery Power'") {
            source = .battery
        } else if output.contains("'AC Power'") {
            source = .acPower
        } else {
            source = .unknown
        }

        var percentage: Int?
        outer: for line in output.split(separator: "\n") {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let percentIndex = token.firstIndex(of: "%") else { continue }
                let digits = token[token.startIndex..<percentIndex].filter { $0.isNumber }
                if let value = Int(digits) {
                    percentage = value
                    break outer
                }
            }
        }

        return BatteryState(percentage: percentage, source: source)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`, 6 tests passed total.

- [ ] **Step 5: Commit**

```bash
git add Sources/PowerService.swift Tests/PowerServiceTests.swift
git commit -m "Add pmset battery-state parsing"
```

---

### Task 4: `PowerService` — system calls (read/set state)

**Files:**
- Modify: `Sources/PowerService.swift`

**Interfaces:**
- Consumes: `SleepState`, `BatteryState`, `parseSleepDisabled`, `parseBattery` (Tasks 2-3).
- Produces: `enum PowerError: Error { case commandFailed(Error), nonZeroExit(String), decodingFailed }` with `var isUserCancelled: Bool`; `static func readSleepState() throws -> SleepState`; `static func readBatteryState() throws -> BatteryState`; `static func setSleepDisabled(_ disabled: Bool) throws`.

These call real system processes, so they are not unit-tested — verified by `xcodebuild build` here, exercised for real in Task 7's manual toggle test.

- [ ] **Step 1: Add `PowerError` and the three functions**

Add to `Sources/PowerService.swift`, above `enum PowerService`:

```swift
enum PowerError: Error {
    case commandFailed(Error)
    case nonZeroExit(String)
    case decodingFailed
}

extension PowerError {
    // osascript's exact error text when the user dismisses the admin-auth
    // dialog is "User canceled. (-128)" — this is the only reliable way to
    // distinguish a deliberate cancel from a real failure.
    var isUserCancelled: Bool {
        if case .nonZeroExit(let message) = self {
            return message.contains("User canceled")
        }
        return false
    }
}
```

Add inside `enum PowerService`:

```swift
    static func readSleepState() throws -> SleepState {
        parseSleepDisabled(try run("/usr/bin/pmset", ["-g"]))
    }

    static func readBatteryState() throws -> BatteryState {
        parseBattery(try run("/usr/bin/pmset", ["-g", "batt"]))
    }

    static func setSleepDisabled(_ disabled: Bool) throws {
        let flag = disabled ? "1" : "0"
        let script = "do shell script \"pmset -a disablesleep \(flag)\" with administrator privileges"
        _ = try run("/usr/bin/osascript", ["-e", script])
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PowerError.commandFailed(error)
        }
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw PowerError.decodingFailed
            }
            return text
        } else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw PowerError.nonZeroExit(String(data: data, encoding: .utf8) ?? "")
        }
    }
```

- [ ] **Step 2: Build and verify existing tests still pass**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`, all 6 tests still passing, no build errors.

- [ ] **Step 3: Manually sanity-check against the real system**

Run `pmset -g | grep -i sleepdisabled` in a terminal and compare its output shape against what `parseSleepDisabled` expects — this is the last check of `PowerService` against reality before it's wired into the UI in Task 7.

- [ ] **Step 4: Commit**

```bash
git add Sources/PowerService.swift
git commit -m "Add pmset read/write system calls via osascript admin prompt"
```

---

### Task 5: `LoginItemService` — SMAppService wrapper

**Files:**
- Create: `Sources/LoginItemService.swift`
- Modify: `project.yml` (add `Sources` file — no change needed, `xcodegen` picks up new files under the existing `sources: [Sources]` glob on regenerate)

**Interfaces:**
- Produces: `enum LoginItemStatus { case notRegistered, enabled, requiresApproval, notFound }`; `enum LoginItemService { static func status() -> LoginItemStatus; static func register() throws; static func unregister() throws }`.

Wraps a real macOS login-item registration, so it's not unit-tested — verified by `xcodebuild build` here, exercised for real in Task 7's manual "Launch at Login" test.

- [ ] **Step 1: Create `Sources/LoginItemService.swift`**

```swift
import Foundation
import ServiceManagement

enum LoginItemStatus {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LoginItemService {
    static func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    static func register() throws {
        try SMAppService.mainApp.register()
    }

    static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Sources/LoginItemService.swift
git commit -m "Add SMAppService login-item wrapper"
```

---

### Task 6: `PowerMonitor` — published state, sync loop, low-battery auto-off

**Files:**
- Create: `Sources/PowerMonitor.swift`

**Interfaces:**
- Consumes: `PowerService.{readSleepState, readBatteryState, setSleepDisabled, SleepState, BatteryState, PowerSource, PowerError}` (Tasks 2-4), `LoginItemService.{status, register, unregister, LoginItemStatus}` (Task 5).
- Produces: `@MainActor final class PowerMonitor: ObservableObject` with `@Published private(set) var sleepState: SleepState`, `@Published private(set) var batteryState: BatteryState`, `@Published private(set) var loginItemEnabled: Bool`, and methods `refresh()`, `toggle()`, `toggleLoginItem()`, `restoreSleepOnQuit()`. This is the type Task 7's UI consumes.

Not unit-testable (timer, real system state, notification permissions). Verified by `xcodebuild build` here; exercised for real in Task 7's manual test.

- [ ] **Step 1: Create `Sources/PowerMonitor.swift`**

```swift
import Foundation
import UserNotifications

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var sleepState: SleepState = .enabled
    @Published private(set) var batteryState = BatteryState(percentage: nil, source: .unknown)
    @Published private(set) var loginItemEnabled = false

    private let syncInterval: Duration = .seconds(30)
    private let lowBatteryThreshold = 10
    private var syncTask: Task<Void, Never>?

    init() {
        refresh()
        requestNotificationAuthorization()
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.syncInterval)
                self.refresh()
                self.checkLowBatteryAutoOff()
            }
        }
    }

    deinit {
        syncTask?.cancel()
    }

    func refresh() {
        sleepState = (try? PowerService.readSleepState()) ?? .unknown
        batteryState = (try? PowerService.readBatteryState()) ?? BatteryState(percentage: nil, source: .unknown)
        loginItemEnabled = LoginItemService.status() == .enabled
    }

    func toggle() {
        let target = sleepState != .disabled
        // A cancel is a deliberate, silent no-op by design (spec §3) — no UI.
        // Any other failure has no dialog framework to surface through yet,
        // so it stays silent too, but is at least visible in the console for
        // debugging rather than vanishing entirely.
        do {
            try PowerService.setSleepDisabled(target)
        } catch let error as PowerError where error.isUserCancelled {
            // no-op
        } catch {
            print("keepy-uppy: failed to toggle sleep state: \(error)")
        }
        refresh()
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
        refresh()
    }

    func restoreSleepOnQuit() {
        guard sleepState == .disabled else { return }
        try? PowerService.setSleepDisabled(false)
    }

    private func checkLowBatteryAutoOff() {
        guard batteryState.source == .battery,
              let percentage = batteryState.percentage,
              percentage < lowBatteryThreshold,
              sleepState == .disabled
        else { return }

        try? PowerService.setSleepDisabled(false)
        postLowBatteryNotification()
        refresh()
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postLowBatteryNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Keepy Uppy"
        content.body = "Battery below 10% — sleep re-enabled automatically."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Sources/PowerMonitor.swift
git commit -m "Add PowerMonitor: published state, 30s sync loop, low-battery auto-off"
```

---

### Task 7: UI assembly — menu, icon, click behavior, quit handling

**Files:**
- Create: `Sources/MenuContent.swift`
- Create: `Sources/AppDelegate.swift`
- Modify: `Sources/KeepyUppyApp.swift` (replace the Task 1 placeholder)

**Interfaces:**
- Consumes: `PowerMonitor` (Task 6).
- Produces: a fully interactive menu bar app — clicking the icon opens a menu with live status, a toggle button, a "Launch at Login" toggle, and Quit; quitting while enabled re-enables sleep.

This is the biggest deliverable in this plan (mirrors the Rust plan's Task 7 in scope) but carries far less API risk. Verified by `xcodebuild build` plus a full manual click-through.

- [ ] **Step 1: Create `Sources/AppDelegate.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PowerMonitor()

    func applicationWillTerminate(_ notification: Notification) {
        monitor.restoreSleepOnQuit()
    }
}
```

- [ ] **Step 2: Create `Sources/MenuContent.swift`**

```swift
import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        Image(systemName: monitor.sleepState == .disabled ? "balloon.fill" : "balloon")
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: PowerMonitor

    var body: some View {
        Text(statusText)

        Divider()

        Button(toggleText) {
            monitor.toggle()
        }

        Toggle("Launch at Login", isOn: Binding(
            get: { monitor.loginItemEnabled },
            set: { _ in monitor.toggleLoginItem() }
        ))

        Divider()

        Button("Quit Keepy Uppy") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusText: String {
        switch monitor.sleepState {
        case .disabled: return "Status: Keeping Awake"
        case .enabled: return "Status: Normal Sleep"
        case .unknown: return "Status: Unknown"
        }
    }

    private var toggleText: String {
        monitor.sleepState == .disabled ? "Turn Off Keepy Uppy" : "Turn On Keepy Uppy"
    }
}
```

`MenuBarIcon` exists as its own `View` (rather than writing `Image(systemName:)` inline in the `MenuBarExtra` label closure) specifically so it can carry `@ObservedObject var monitor`, the same pattern `MenuContent` uses — that's what makes the icon actually re-render when `PowerMonitor`'s published state changes. Reading `appDelegate.monitor.sleepState` directly inside `KeepyUppyApp.body` without a wrapping `@ObservedObject` view would not reliably trigger re-renders.

- [ ] **Step 3: Replace `Sources/KeepyUppyApp.swift`**

```swift
import SwiftUI

@main
struct KeepyUppyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: appDelegate.monitor)
        } label: {
            MenuBarIcon(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 4: Regenerate and build**

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manually test the full click-through**

Run: `open "build/Build/Products/Debug/Keepy Uppy.app"`, then verify:
1. Click the balloon icon → menu appears showing "Status: Normal Sleep", "Turn On Keepy Uppy", "Launch at Login" (unchecked), "Quit Keepy Uppy". (Left-click and right-click both open this same menu — there is no separate direct-toggle click, per spec §3.)
2. Click "Turn On Keepy Uppy" → macOS admin prompt appears → enter password → reopen the menu, it now reads "Turn Off Keepy Uppy" and "Status: Keeping Awake"; icon becomes a filled balloon. Confirm with `pmset -g | grep SleepDisabled` in a terminal — should show `1`.
3. Toggle back off → confirm `pmset -g | grep SleepDisabled` shows `0` or is absent.
4. Cancel the admin dialog on a toggle attempt → confirm no crash and no error dialog (silent no-op).
5. Click "Launch at Login" → checkbox becomes checked, no admin prompt. Verify in System Settings → General → Login Items that "Keepy Uppy" appears (this should work correctly now, since — unlike the Rust plan's raw binary — this is already a real signed-enough `.app` bundle).
6. Click "Quit Keepy Uppy" while enabled → one final admin prompt appears; approve it; confirm `pmset -g | grep SleepDisabled` shows `0` or is absent after the app exits.

- [ ] **Step 6: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Sources/MenuContent.swift Sources/AppDelegate.swift Sources/KeepyUppyApp.swift
git commit -m "Wire up menu, icon, click handling, and quit-restores-sleep"
```

---

### Task 8: App icon

**Files:**
- Create: `packaging/generate_icon.swift`
- Create: `Resources/Assets.xcassets/Contents.json`
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Modify: `project.yml` (add `resources:` and the app-icon build setting)

**Interfaces:**
- Produces: a real balloon app icon shown in Finder, Get Info, and Activity Monitor (the menu bar icon from Task 7 is unaffected — it already uses the `balloon`/`balloon.fill` SF Symbol directly).

- [ ] **Step 1: Create the asset catalog scaffolding**

Create `Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {"idiom":"mac","size":"16x16","scale":"1x","filename":"icon_16x16.png"},
    {"idiom":"mac","size":"16x16","scale":"2x","filename":"icon_16x16@2x.png"},
    {"idiom":"mac","size":"32x32","scale":"1x","filename":"icon_32x32.png"},
    {"idiom":"mac","size":"32x32","scale":"2x","filename":"icon_32x32@2x.png"},
    {"idiom":"mac","size":"128x128","scale":"1x","filename":"icon_128x128.png"},
    {"idiom":"mac","size":"128x128","scale":"2x","filename":"icon_128x128@2x.png"},
    {"idiom":"mac","size":"256x256","scale":"1x","filename":"icon_256x256.png"},
    {"idiom":"mac","size":"256x256","scale":"2x","filename":"icon_256x256@2x.png"},
    {"idiom":"mac","size":"512x512","scale":"1x","filename":"icon_512x512.png"},
    {"idiom":"mac","size":"512x512","scale":"2x","filename":"icon_512x512@2x.png"}
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 2: Create the icon-generation script**

```swift
import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outputDir = "Resources/Assets.xcassets/AppIcon.appiconset"

guard let symbol = NSImage(systemSymbolName: "balloon.fill", accessibilityDescription: nil) else {
    fatalError("balloon.fill symbol not found")
}

for (size, name) in sizes {
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.8, weight: .regular)
    guard let configured = symbol.withSymbolConfiguration(config) else { continue }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    configured.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("Wrote iconset PNGs to \(outputDir)")
```

- [ ] **Step 3: Wire the asset catalog into `project.yml`**

Add `resources:` under the `Keepy Uppy` target (alongside the existing `sources:`):

```yaml
    resources:
      - Resources/Assets.xcassets
```

Add to the target's `settings.base`:

```yaml
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

- [ ] **Step 4: Generate the icon and rebuild**

Run: `swift packaging/generate_icon.swift`
Expected: 10 PNG files written under `Resources/Assets.xcassets/AppIcon.appiconset/`. The rendered symbol may appear as a flat, untinted glyph rather than a colorized balloon — acceptable for a v1 placeholder; note it if real art is wanted later.

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manually verify**

Run: `open "build/Build/Products/Debug"` in Finder and check "Keepy Uppy.app"'s icon shows the balloon (not the generic default). Get Info on the app should also show it.

- [ ] **Step 6: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" packaging/generate_icon.swift Resources/Assets.xcassets
git commit -m "Add app icon generated from the balloon SF Symbol"
```

---

### Task 9: Packaging — build/archive/notarize via `just`, and README

**Files:**
- Create: `justfile`
- Create: `packaging/ExportOptions.plist`
- Create: `README.md`

**Interfaces:**
- Produces: `just build`, `just test`, `just run`, `just archive`, `just export`, `just dmg`, `just notarize` targets; `README.md` with setup instructions, the accumulated manual test checklist, and the low-battery known limitation.

- [ ] **Step 1: Create `justfile`**

```just
app_name := "Keepy Uppy"
scheme := "Keepy Uppy"
project := "Keepy Uppy.xcodeproj"
derived_data := "build"
app_path := derived_data + "/Build/Products/Debug/" + app_name + ".app"
archive_path := derived_data + "/" + app_name + ".xcarchive"
export_path := derived_data + "/export"
dmg_path := derived_data + "/" + app_name + ".dmg"
signing_identity := env_var("KEEPY_UPPY_SIGNING_IDENTITY")
team_id := env_var("KEEPY_UPPY_TEAM_ID")
notary_profile := env_var("KEEPY_UPPY_NOTARY_PROFILE")

generate:
    xcodegen generate

build: generate
    xcodebuild build \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Debug \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGNING_ALLOWED=NO

test: generate
    xcodebuild test \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGNING_ALLOWED=NO

run: build
    open "{{app_path}}"

archive: generate
    xcodebuild archive \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Release \
        -archivePath "{{archive_path}}" \
        -derivedDataPath "{{derived_data}}" \
        CODE_SIGN_IDENTITY="{{signing_identity}}" \
        DEVELOPMENT_TEAM="{{team_id}}"

export: archive
    xcodebuild -exportArchive \
        -archivePath "{{archive_path}}" \
        -exportPath "{{export_path}}" \
        -exportOptionsPlist packaging/ExportOptions.plist

dmg: export
    rm -f "{{dmg_path}}"
    hdiutil create -volname "{{app_name}}" \
        -srcfolder "{{export_path}}/{{app_name}}.app" \
        -ov -format UDZO \
        "{{dmg_path}}"

notarize: dmg
    xcrun notarytool submit "{{dmg_path}}" \
        --keychain-profile "{{notary_profile}}" \
        --wait
    xcrun stapler staple "{{dmg_path}}"
```

- [ ] **Step 2: Create `packaging/ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
```

- [ ] **Step 3: Verify the justfile parses and the dev build/test targets still work**

Run: `just --list`
Expected: lists `generate`, `build`, `test`, `run`, `archive`, `export`, `dmg`, `notarize` with no parse errors.

Run: `just test`
Expected: `** TEST SUCCEEDED **` (uses the already-verified `generate`/`test` recipes from earlier tasks).

- [ ] **Step 4: Write `README.md`**

```markdown
# Keepy Uppy

Keeps a MacBook awake with the lid closed by toggling `pmset -a disablesleep`
through a menu-bar balloon icon. See
`docs/superpowers/specs/2026-08-06-keepy-uppy-swift-design.md` for the full
design rationale (and `2026-08-06-keepy-uppy-design.md` for the original
Rust/objc2 design this superseded).

## Prerequisites

- Xcode + Xcode Command Line Tools
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [`just`](https://github.com/casey/just): `brew install just`
- A Developer ID Application certificate in your login keychain (for `just archive`)
- A notarytool keychain profile: `xcrun notarytool store-credentials` (for `just notarize`)

## Build and run (development)

    just run

## Build the distributable app

    export KEEPY_UPPY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    export KEEPY_UPPY_TEAM_ID="TEAMID"
    export KEEPY_UPPY_NOTARY_PROFILE="your-notarytool-profile-name"
    just notarize   # signed, notarized, stapled .dmg in build/

## Manual test checklist

Run through this after any change to `PowerMonitor.swift`, `PowerService.swift`,
`LoginItemService.swift`, `MenuContent.swift`, or `AppDelegate.swift`:

- [ ] Clicking the icon (left or right click, both open the same menu) shows correct status text, toggle wording, and login-item checkbox state
- [ ] Toggling on prompts for admin password, icon fills in, `pmset -g | grep SleepDisabled` shows `1`
- [ ] Toggling off reverses all of the above
- [ ] Canceling the admin dialog is a silent no-op (no crash, no error dialog)
- [ ] "Launch at Login" registers/unregisters and is reflected in System Settings → General → Login Items
- [ ] External `sudo pmset -a disablesleep 1/0` is reflected in the icon within 30 seconds
- [ ] Low-battery auto-off re-enables sleep and posts a notification when tested with a lowered threshold
- [ ] Quitting while enabled re-enables sleep (one final admin prompt) before the app exits
- [ ] The app has no Dock icon and shows the balloon in the menu bar
- [ ] The app's Finder/Get Info icon shows the balloon (Task 8)
- [ ] The exported, notarized `.app` opens without Gatekeeper warnings

## Known limitation

Low-battery auto-off needs a password/Touch ID prompt to re-enable sleep,
same as every other state change (see spec §5's privilege model). If the
lid is closed and the Mac is unattended, that prompt has nobody to answer
it, so auto-off can't complete in exactly the scenario it exists for. It
works whenever the machine is attended. A future privileged-helper-daemon
version (SMAppService + XPC) would remove this gap — see spec §4 and §9.
```

- [ ] **Step 5: Commit**

```bash
git add justfile packaging/ExportOptions.plist README.md
git commit -m "Add just-based build/archive/notarize workflow and README"
```
