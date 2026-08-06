# Keepy Uppy v2 — Plan 1 of 3: Privileged Helper Daemon

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v1's per-action `osascript` admin prompt with a root helper daemon over XPC, so the app prompts once at approval and never again — and so sleep is restored whenever the app stops running.

**Scope:** This is plan 1 of 3 for the v2 release, covering spec §1–§9 and §14. Sessions (§10–§11) and triggers + safety (§12–§13) get their own plans on top of this one. At the end of this plan the app has **exactly v1's feature set** — toggle, launch at login, low-battery cutoff, restore on quit — with the privilege architecture swapped underneath. That makes it independently shippable and lets the security review land on a clean diff before any UI work builds on it.

**Architecture:** Three build targets — the existing menu-bar app, a new root LaunchDaemon (`KeepyUppyHelper`) embedded at `Contents/MacOS/`, and a small signed CLI (`keepy-uppy`) that drives the same XPC service. The helper owns all privileged state; the app holds no privileges and merely makes requests. A shared source directory carries the XPC protocol and signing requirement into all three targets.

**Tech Stack:** Swift/SwiftUI, `NSXPCConnection`/`NSXPCListener`, `SMAppService.daemon`, IOKit (`IOPMSetSystemPowerSetting` via a bridging header; `IOPSCopyPowerSourcesInfo` public), xcodegen, just/xcodebuild.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-daemon-design.md`. Where this plan and the spec disagree, the spec wins — report the conflict rather than guessing.
- Deployment target stays **macOS 13.0**. Both load-bearing APIs (`SMAppService.daemon(plistName:)`, `NSXPCConnection.setCodeSigningRequirement`) are `API_AVAILABLE(macos(13.0))` — verified in the SDK.
- Identifiers, exactly: app `au.com.workwireless.keepy-uppy`; helper label and Mach service `au.com.workwireless.keepy-uppy.helper`; CLI `au.com.workwireless.keepy-uppy.cli`.
- **Signing is required to verify anything past the XPC handshake.** `SMAppService` will not register a daemon from an ad-hoc-signed build. Builds and unit tests run unsigned; registration, approval, and the end-to-end toggle are manual steps on a signed build, deferred to human verification (§ each task says which of its checks are deferred).
- The following were verified on this machine before this plan was written. Treat them as known-good and do not redesign around them:
  - The xcodegen embedding syntax in Task 1 produces exactly `Contents/MacOS/{KeepyUppyHelper,keepy-uppy}` and `Contents/Library/LaunchDaemons/<label>.plist`. Verified by building a scratch project and listing the bundle.
  - Both the wildcard requirement (`identifier = "au.com.workwireless.keepy-uppy*"`) and an explicit OR-list compile under `csreq`. The plan uses the wildcard per spec §5; the OR-list is the documented fallback if runtime matching misbehaves on a signed build.
- **Never run a command that triggers a macOS password or permission dialog** (`sudo`, `osascript … with administrator privileges`). Reading `pmset -g` without sudo is safe. Implementers cannot click, type passwords, or approve System Settings items — every such check is deferred to human verification and must be listed in the task report.
- Dev/test builds use `-derivedDataPath build CODE_SIGN_IDENTITY=-`.
- Commit style: plain imperative subjects, exactly the message each task's commit step specifies. Stage only the paths named — never `git add .`.
- xcodegen reassigns internal UUIDs on every `generate`; a whole-file `.xcodeproj` diff per task is expected, not corruption.

---

### Task 1: Three-target project structure

**Files:**
- Modify: `project.yml`
- Create: `Helper/main.swift`, `CLI/main.swift`, `Shared/XPCProtocol.swift`
- Create: `Launchd/au.com.workwireless.keepy-uppy.helper.plist`

**Interfaces:**
- Produces: a bundle containing the app plus an embedded helper and CLI, and the daemon plist in the right place. Later tasks fill in the executables.

- [ ] **Step 1: Create the launchd plist**

`Launchd/au.com.workwireless.keepy-uppy.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>au.com.workwireless.keepy-uppy.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/KeepyUppyHelper</string>
    <key>MachServices</key>
    <dict>
        <key>au.com.workwireless.keepy-uppy.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>au.com.workwireless.keepy-uppy</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Create the shared XPC protocol**

`Shared/XPCProtocol.swift`:

```swift
import Foundation

/// Mach service name shared by helper, app, and CLI.
let helperMachServiceName = "au.com.workwireless.keepy-uppy.helper"

@objc protocol HelperProtocol {
    /// Registers this client's desire to keep the Mac awake.
    /// The helper keeps sleep disabled while any client wants it.
    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    /// The helper's view of the real system state.
    func currentState(reply: @escaping (Bool) -> Void)
    /// Helper build version, used by the app to detect version skew.
    func version(reply: @escaping (String) -> Void)
}
```

- [ ] **Step 3: Create placeholder executables**

`Helper/main.swift`:

```swift
import Foundation

// Replaced in Task 4 with the real XPC listener.
RunLoop.main.run()
```

`CLI/main.swift`:

```swift
import Foundation

// Replaced in Task 9 with the real CLI.
print("keepy-uppy: not yet implemented")
```

- [ ] **Step 4: Add the two targets and embedding to `project.yml`**

Add to `targets:` (alongside the existing `Keepy Uppy` and `Keepy UppyTests`):

```yaml
  KeepyUppyHelper:
    type: tool
    platform: macOS
    deploymentTarget: "13.0"
    sources: [Helper, Shared]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: au.com.workwireless.keepy-uppy.helper
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        SWIFT_VERSION: "5.0"

  keepy-uppy:
    type: tool
    platform: macOS
    deploymentTarget: "13.0"
    sources: [CLI, Shared]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: au.com.workwireless.keepy-uppy.cli
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        SWIFT_VERSION: "5.0"
```

On the `Keepy Uppy` target, add `Shared` and the plist to `sources:`, and add the `dependencies:` block:

```yaml
    sources:
      - Sources
      - Shared
      - Resources/Assets.xcassets
      - path: Launchd/au.com.workwireless.keepy-uppy.helper.plist
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchDaemons
    dependencies:
      - target: KeepyUppyHelper
        embed: true
        codeSign: true
        copy:
          destination: executables
      - target: keepy-uppy
        embed: true
        codeSign: true
        copy:
          destination: executables
```

- [ ] **Step 5: Generate, build, and verify the actual bundle layout**

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

Run: `find "build/Build/Products/Debug/Keepy Uppy.app" -type f | sed 's|.*Keepy Uppy.app|Keepy Uppy.app|' | sort`

Expected to include all three of these lines — this is the check that matters, because a silently-ignored key would still "build":

```
Keepy Uppy.app/Contents/Library/LaunchDaemons/au.com.workwireless.keepy-uppy.helper.plist
Keepy Uppy.app/Contents/MacOS/KeepyUppyHelper
Keepy Uppy.app/Contents/MacOS/keepy-uppy
```

If any is missing, stop and report — do not hand-edit the `.xcodeproj`.

- [ ] **Step 6: Confirm tests still pass**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 8/8.

- [ ] **Step 7: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Helper CLI Shared Launchd
git commit -m "Add helper daemon and CLI targets with bundle embedding"
```

---

### Task 2: IOKit power layer

**Files:**
- Create: `Shared/PowerSPI.h`, `Shared/PowerControl.swift`
- Modify: `project.yml` (bridging header + IOKit framework on helper and app targets)
- Test: `Tests/PowerControlTests.swift`

**Interfaces:**
- Produces: `enum PowerControl` with `static func sleepDisabled() -> Bool`, `static func setSleepDisabled(_:) -> Bool` (returns success), and `static func batteryState() -> BatteryState`; plus `static func parseBattery(from description: [String: Any]) -> BatteryState` as the pure, testable half.
- `BatteryState`/`PowerSource` keep v1's shape so nothing downstream changes.

- [ ] **Step 1: Declare the IOKit SPI**

`Shared/PowerSPI.h` — these two symbols are exported by IOKit but declared in no public header (spec §7):

```c
#ifndef PowerSPI_h
#define PowerSPI_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>

extern IOReturn IOPMSetSystemPowerSetting(CFStringRef key, CFTypeRef value);
extern CFDictionaryRef IOPMCopySystemPowerSettings(void);

#endif /* PowerSPI_h */
```

- [ ] **Step 2: Write the failing test**

`Tests/PowerControlTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class PowerControlBatteryTests: XCTestCase {
    func testParsesDischargingBattery() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 87,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .battery)
        XCTAssertEqual(state.percentage, 87)
    }

    func testParsesACPower() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "AC Power",
            "Current Capacity": 100,
            "Max Capacity": 100,
        ])
        XCTAssertEqual(state.source, .acPower)
        XCTAssertEqual(state.percentage, 100)
    }

    func testScalesWhenMaxCapacityIsNotOneHundred() {
        let state = PowerControl.parseBattery(from: [
            "Power Source State": "Battery Power",
            "Current Capacity": 25,
            "Max Capacity": 50,
        ])
        XCTAssertEqual(state.percentage, 50)
    }

    func testMissingKeysYieldUnknown() {
        let state = PowerControl.parseBattery(from: [:])
        XCTAssertEqual(state.source, .unknown)
        XCTAssertNil(state.percentage)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: compile failure — `PowerControl` does not exist yet.

- [ ] **Step 4: Implement `PowerControl`**

`Shared/PowerControl.swift`:

```swift
import Foundation
import IOKit
import IOKit.ps

enum PowerControl {
    // MARK: - Sleep setting (privileged write, unprivileged read)

    private static let sleepDisabledKey = "SleepDisabled" as CFString

    static func sleepDisabled() -> Bool {
        // takeRetainedValue, not takeUnretainedValue: this is a CF "Copy"
        // function returning +1 ownership. And the unwrap is required — the
        // bridging header carries no CF ownership annotations, so Swift
        // imports this returning Unmanaged, and casting it directly to a
        // dictionary silently always fails.
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (settings["SleepDisabled"] as? Bool) ?? false
    }

    /// Requires root. Returns true on success.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value = (disabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        return IOPMSetSystemPowerSetting(sleepDisabledKey, value) == kIOReturnSuccess
    }

    // MARK: - Battery (public API)

    static func batteryState() -> BatteryState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryState(percentage: nil, source: .unknown)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            return parseBattery(from: description)
        }
        // No battery (desktop Mac): report AC without a percentage.
        return BatteryState(percentage: nil, source: .acPower)
    }

    /// Pure half, split out so battery logic is testable without hardware.
    static func parseBattery(from description: [String: Any]) -> BatteryState {
        let source: PowerSource
        switch description[kIOPSPowerSourceStateKey as String] as? String {
        case kIOPSBatteryPowerValue as String: source = .battery
        case kIOPSACPowerValue as String: source = .acPower
        default: source = .unknown
        }

        var percentage: Int?
        if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
           let max = description[kIOPSMaxCapacityKey as String] as? Int,
           max > 0 {
            percentage = Int((Double(current) / Double(max) * 100).rounded())
        }

        return BatteryState(percentage: percentage, source: source)
    }
}
```

- [ ] **Step 5: Wire the bridging header and IOKit into `project.yml`**

On **all three** of the `Keepy Uppy`, `KeepyUppyHelper`, and `keepy-uppy` targets — every target that compiles `Shared/` needs this, including the CLI — add to `settings.base`:

```yaml
        SWIFT_OBJC_BRIDGING_HEADER: Shared/PowerSPI.h
```

and add to each target:

```yaml
    dependencies:
      - sdk: IOKit.framework
```

(For `Keepy Uppy`, append the `sdk:` entry to its existing `dependencies:` list from Task 1.)

`SleepState`, `PowerSource`, and `BatteryState` must also **move** from
`Sources/PowerService.swift` into `Shared/PowerControl.swift` as part of this
task. `Sources/` is app-only, so the helper and CLI cannot see those types
otherwise. Leave the rest of `PowerService.swift` intact — Task 7 deletes it.

- [ ] **Step 6: Regenerate, build, and run the tests**

Run: `xcodegen generate`

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 12/12 (8 existing + 4 new).

Note: `setSleepDisabled` is **not** exercised here — it needs root and lives in the helper. Its first real run is human-verified in Task 10.

- [ ] **Step 7: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Shared/PowerSPI.h Shared/PowerControl.swift Tests/PowerControlTests.swift
git commit -m "Add IOKit power layer replacing pmset text parsing"
```

---

### Task 3: Client table reducer (the dead man's switch logic)

**Files:**
- Create: `Shared/ClientTable.swift`
- Test: `Tests/ClientTableTests.swift`

**Interfaces:**
- Produces: `struct ClientTable<ID: Hashable>` with `mutating func set(_ id: ID, wantsAwake: Bool)`, `mutating func remove(_ id: ID)`, `var desiredKeepAwake: Bool`, `var clientCount: Int`.
- Generic over `ID` specifically so tests can use `Int` while the helper uses `ObjectIdentifier`.

This is the whole dead man's switch, isolated as pure logic (spec §6). TDD strictly.

- [ ] **Step 1: Write the failing tests**

`Tests/ClientTableTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class ClientTableTests: XCTestCase {
    func testEmptyTableWantsSleepEnabled() {
        let table = ClientTable<Int>()
        XCTAssertFalse(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 0)
    }

    func testSingleClientRequestingKeepsAwake() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testAnyClientWantingIsEnough() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(2, wantsAwake: false)
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testLastRequesterDisconnectingRestoresSleep() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(2, wantsAwake: true)
        table.remove(1)
        XCTAssertTrue(table.desiredKeepAwake, "second client still wants it")
        table.remove(2)
        XCTAssertFalse(table.desiredKeepAwake, "no clients left, sleep must come back")
    }

    func testClientWithdrawingRequestRestoresSleep() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.set(1, wantsAwake: false)
        XCTAssertFalse(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 1, "still connected, just not requesting")
    }

    func testRemovingUnknownClientIsHarmless() {
        var table = ClientTable<Int>()
        table.set(1, wantsAwake: true)
        table.remove(99)
        XCTAssertTrue(table.desiredKeepAwake)
        XCTAssertEqual(table.clientCount, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: compile failure — `ClientTable` does not exist.

- [ ] **Step 3: Implement**

`Shared/ClientTable.swift`:

```swift
import Foundation

/// Tracks which connected clients want the Mac kept awake.
/// The desired system state is simply "any client wants it", so losing a
/// client — by disconnect, crash, or termination — restores sleep on its own.
struct ClientTable<ID: Hashable> {
    private var wants: [ID: Bool] = [:]

    var desiredKeepAwake: Bool { wants.values.contains(true) }
    var clientCount: Int { wants.count }

    mutating func set(_ id: ID, wantsAwake: Bool) {
        wants[id] = wantsAwake
    }

    mutating func remove(_ id: ID) {
        wants.removeValue(forKey: id)
    }
}
```

- [ ] **Step 4: Regenerate, run tests**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 18/18.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Shared/ClientTable.swift Tests/ClientTableTests.swift
git commit -m "Add client table reducer for the dead man's switch"
```

---

### Task 4: Helper — XPC listener and safe-start behaviour

**Files:**
- Modify: `Helper/main.swift`
- Create: `Helper/HelperService.swift`, `Helper/HelperListenerDelegate.swift`

**Interfaces:**
- Consumes: `HelperProtocol`, `helperMachServiceName` (Task 1); `PowerControl` (Task 2); `ClientTable` (Task 3).
- Produces: a working daemon executable. Security pinning is deliberately **not** here — it is Task 5, so it reviews on its own diff.

- [ ] **Step 1: Implement the service state and exported object**

`Helper/HelperService.swift`:

```swift
import Foundation
import os

let helperLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.helper", category: "helper")

/// Serialises all state behind one queue: XPC replies arrive on arbitrary threads.
final class HelperState {
    private let queue = DispatchQueue(label: "au.com.workwireless.keepy-uppy.helper.state")
    private var table = ClientTable<ObjectIdentifier>()

    /// Called at daemon startup: converge to the safe state before serving
    /// anyone, so a helper crash can never strand the Mac awake (spec §6).
    func resetToSafeState() {
        queue.sync {
            PowerControl.setSleepDisabled(false)
            helperLogger.log("Helper started; forced sleep enabled as safe baseline")
        }
    }

    func set(_ id: ObjectIdentifier, wantsAwake: Bool) -> Bool {
        queue.sync {
            table.set(id, wantsAwake: wantsAwake)
            return applyLocked()
        }
    }

    func remove(_ id: ObjectIdentifier) {
        queue.sync {
            table.remove(id)
            helperLogger.log("Client disconnected; \(self.table.clientCount) remain")
            _ = applyLocked()
        }
    }

    func currentState() -> Bool {
        queue.sync { PowerControl.sleepDisabled() }
    }

    private func applyLocked() -> Bool {
        let desired = table.desiredKeepAwake
        let ok = PowerControl.setSleepDisabled(desired)
        helperLogger.log("Applied keepAwake=\(desired) success=\(ok)")
        return ok
    }
}

final class HelperService: NSObject, HelperProtocol {
    private let state: HelperState
    private let clientID: ObjectIdentifier

    init(state: HelperState, clientID: ObjectIdentifier) {
        self.state = state
        self.clientID = clientID
    }

    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        let ok = state.set(clientID, wantsAwake: enabled)
        reply(ok, ok ? nil : "Failed to apply power setting")
    }

    func currentState(reply: @escaping (Bool) -> Void) {
        reply(state.currentState())
    }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
```

- [ ] **Step 2: Implement the listener delegate**

`Helper/HelperListenerDelegate.swift`:

```swift
import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let state = HelperState()

    func startup() {
        state.resetToSafeState()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Task 5 adds peer code-signing verification here. Until then this
        // helper accepts any local connection and MUST NOT be shipped.
        let id = ObjectIdentifier(newConnection)

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(state: state, clientID: id)

        newConnection.invalidationHandler = { [state] in state.remove(id) }
        newConnection.interruptionHandler = { [state] in state.remove(id) }

        newConnection.resume()
        helperLogger.log("Accepted connection \(String(describing: id))")
        return true
    }
}
```

- [ ] **Step 3: Wire up `main.swift`**

`Helper/main.swift`:

```swift
import Foundation

let delegate = HelperListenerDelegate()
delegate.startup()

let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
```

- [ ] **Step 4: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`, no new warnings.

Run: `xcodebuild test …` (same flags) — expected 18/18 unaffected.

Do **not** attempt to launch or register the daemon; that needs signing and is human-verified in Task 10.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Helper
git commit -m "Add helper XPC listener with safe-start reset"
```

---

### Task 5: Security — peer code-signing verification

**Files:**
- Create: `Shared/SigningRequirement.swift`
- Modify: `Helper/HelperListenerDelegate.swift`

**Interfaces:**
- Produces: `enum SigningRequirement` with `static let requirement: String` and `static var isEnforced: Bool`.

This task exists separately so it reviews on its own diff (spec §15). It is the single most security-sensitive change in the plan.

- [ ] **Step 1: Create the requirement**

`Shared/SigningRequirement.swift`:

```swift
import Foundation
import os

/// Code-signing requirement pinning both ends of the XPC connection.
///
/// Scoped to our Team ID plus a bundle-identifier prefix (spec §5) so the app,
/// the CLI, and any future companion are admitted — all of which still require
/// our signing key. Widening a boundary later is where mistakes get made.
enum SigningRequirement {
    /// Substituted at build time from KEEPY_UPPY_TEAM_ID (Task 10).
    static let teamID = "REPLACE_WITH_TEAM_ID"

    static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
        + "and identifier = \"au.com.workwireless.keepy-uppy*\""

    /// Ad-hoc builds have no Team ID, so the requirement cannot be satisfied
    /// locally. Enforcement is therefore compiled out in DEBUG — loudly.
    /// A build that silently skipped verification would be far worse than one
    /// that refuses to run.
    static var isEnforced: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}
```

- [ ] **Step 2: Enforce it in the listener**

In `Helper/HelperListenerDelegate.swift`, replace the two comment lines at the top of `listener(_:shouldAcceptNewConnection:)` with:

```swift
        if SigningRequirement.isEnforced {
            newConnection.setCodeSigningRequirement(SigningRequirement.requirement)
        } else {
            // One string literal, not concatenation: os.Logger takes an
            // OSLogMessage built from a compile-time interpolation literal,
            // and `+` forces resolution to a plain String, which won't compile.
            helperLogger.error("⚠️ DEBUG BUILD: XPC peer code-signing requirement NOT enforced. This build must never be distributed.")
        }
```

`setCodeSigningRequirement` must be called before `resume()` — it is an XPC error to call it twice, and connections that stop matching are invalidated automatically.

- [ ] **Step 3: Build and verify the requirement string compiles**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`.

Verify the requirement grammar independently (this catches a malformed string, which would otherwise throw at runtime):

```bash
echo 'anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier = "au.com.workwireless.keepy-uppy*"' | csreq -r- -b /tmp/kureq.bin && echo "REQUIREMENT COMPILES" && rm -f /tmp/kureq.bin
```
Expected: `REQUIREMENT COMPILES`.

Runtime matching against real signatures cannot be checked unsigned — deferred to Task 10's human verification.

- [ ] **Step 4: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Shared/SigningRequirement.swift Helper/HelperListenerDelegate.swift
git commit -m "Pin XPC connections to our signing identity"
```

---

### Task 6: App — XPC client

**Files:**
- Create: `Sources/HelperConnection.swift`

**Interfaces:**
- Consumes: `HelperProtocol`, `helperMachServiceName`, `SigningRequirement`.
- Produces: `@MainActor final class HelperConnection` with `func setKeepAwake(_:) async -> Bool`, `func currentState() async -> Bool`, `func helperVersion() async -> String?`, and `var isConnected: Bool`.

- [ ] **Step 1: Implement**

`Sources/HelperConnection.swift`:

```swift
import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

@MainActor
final class HelperConnection {
    private var connection: NSXPCConnection?

    var isConnected: Bool { connection != nil }

    private func proxy() -> HelperProtocol? {
        if connection == nil { connect() }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            appLogger.error("XPC error: \(error.localizedDescription)")
        } as? HelperProtocol
    }

    private func connect() {
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            new.setCodeSigningRequirement(SigningRequirement.requirement)
        }
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        new.resume()
        connection = new
    }

    func setKeepAwake(_ enabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: false) }
            proxy.requestKeepAwake(enabled) { ok, message in
                if let message { appLogger.error("Helper refused: \(message)") }
                continuation.resume(returning: ok)
            }
        }
    }

    func currentState() async -> Bool {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: false) }
            proxy.currentState { continuation.resume(returning: $0) }
        }
    }

    func helperVersion() async -> String? {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: nil) }
            proxy.version { continuation.resume(returning: $0) }
        }
    }
}
```

- [ ] **Step 2: Regenerate, build, test**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 18/18.

- [ ] **Step 3: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/HelperConnection.swift
git commit -m "Add app-side XPC client for the helper"
```

---

### Task 7: App — switch `PowerMonitor` onto the helper

**Files:**
- Modify: `Sources/PowerMonitor.swift`
- Delete: `Sources/PowerService.swift`, `Tests/PowerServiceTests.swift`

**Interfaces:**
- Consumes: `HelperConnection` (Task 6), `PowerControl` (Task 2).
- Produces: `PowerMonitor` with its v1 public surface unchanged (`sleepState`, `batteryState`, `loginItemEnabled`, `refresh()`, `toggle()`, `toggleLoginItem()`, `restoreSleepOnQuit()`), so `MenuContent` and `AppDelegate` need no changes.

The v1 `pmset` layer and its tests are deleted here: sleep state now comes from the helper, battery from `PowerControl`. Deleting the tests is correct, not a coverage regression — the code under test no longer exists, and Task 2 replaced its coverage.

- [ ] **Step 1: Rewrite the monitor's power plumbing**

In `Sources/PowerMonitor.swift`, replace the `PowerService` usages:

```swift
    private let helper = HelperConnection()

    func refresh() async {
        let disabled = await helper.currentState()
        sleepState = disabled ? .disabled : .enabled
        batteryState = PowerControl.batteryState()
        loginItemEnabled = LoginItemService.status() == .enabled
    }

    func toggle() {
        let target = sleepState != .disabled
        Task {
            let ok = await helper.setKeepAwake(target)
            if !ok { appLogger.error("Toggle to \(target) failed") }
            await refresh()
        }
    }

    /// No longer needs to do anything privileged: dropping the XPC connection
    /// at exit is itself what restores sleep (spec §6). Kept as an explicit,
    /// synchronous belt-and-braces request so the common case is immediate
    /// rather than waiting on connection teardown.
    func restoreSleepOnQuit() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            _ = await helper.setKeepAwake(false)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
```

Keep `checkLowBatteryAutoOff()` from v1, but change its body's write to go through the helper:

```swift
        let ok = await helper.setKeepAwake(false)
        await refresh()
        postLowBatteryNotification(reEnabled: ok && sleepState == .enabled)
```

Everything else in the file — the latch, thresholds, the 30-second loop, notification text — is unchanged.

- [ ] **Step 2: Delete the superseded files**

```bash
git rm Sources/PowerService.swift Tests/PowerServiceTests.swift
```

`SleepState`, `PowerSource`, and `BatteryState` moved into `Shared/PowerControl.swift` in Task 2, so nothing else loses a type.

- [ ] **Step 3: Regenerate, build, test**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 10/10 (18 minus the 8 deleted `pmset` parser tests).

- [ ] **Step 4: Commit**

```bash
git add -A Sources Tests "Keepy Uppy.xcodeproj"
git commit -m "Drive sleep state through the helper and drop pmset parsing"
```

---

### Task 8: Registration and approval UX

**Files:**
- Create: `Sources/HelperInstaller.swift`
- Modify: `Sources/PowerMonitor.swift`, `Sources/MenuContent.swift`

**Interfaces:**
- Produces: `enum HelperInstaller` with `static func status() -> SMAppServiceStatus`, `static func register() throws`, `static func openApprovalSettings()`; `PowerMonitor.helperStatus` published property; a menu item surfacing approval.

- [ ] **Step 1: Implement the installer**

`Sources/HelperInstaller.swift`:

```swift
import Foundation
import ServiceManagement

enum HelperInstaller {
    static let plistName = "au.com.workwireless.keepy-uppy.helper.plist"

    private static var service: SMAppService { .daemon(plistName: plistName) }

    static func status() -> SMAppServiceStatus { service.status }

    static func register() throws { try service.register() }

    static func unregister() throws { try service.unregister() }

    static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
```

- [ ] **Step 2: Register on demand and publish status**

In `Sources/PowerMonitor.swift`, add:

```swift
    @Published private(set) var helperStatus: SMAppServiceStatus = .notRegistered

    /// Registers the helper if needed. Returns true when it is usable.
    private func ensureHelperRegistered() -> Bool {
        helperStatus = HelperInstaller.status()
        switch helperStatus {
        case .enabled:
            return true
        case .notRegistered, .notFound:
            do {
                try HelperInstaller.register()
                helperStatus = HelperInstaller.status()
                appLogger.log("Registered helper; status now \(self.helperStatus.rawValue)")
            } catch {
                appLogger.error("Helper registration failed: \(error.localizedDescription)")
            }
            return helperStatus == .enabled
        case .requiresApproval:
            return false
        @unknown default:
            return false
        }
    }

    func openApprovalSettings() { HelperInstaller.openApprovalSettings() }
```

and make `toggle()` call it first:

```swift
    func toggle() {
        guard ensureHelperRegistered() else {
            appLogger.log("Helper not usable (status \(self.helperStatus.rawValue)); awaiting approval")
            return
        }
        // …existing body…
    }
```

Add version-skew handling to `refresh()` (spec §9), after the state read:

```swift
        if let helperVersion = await helper.helperVersion(),
           helperVersion != (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) {
            appLogger.log("Helper version \(helperVersion) differs from app; re-registering")
            try? HelperInstaller.register()
        }
```

- [ ] **Step 3: Surface approval in the menu**

In `Sources/MenuContent.swift`, insert immediately after the status `Text`:

```swift
        if monitor.helperStatus == .requiresApproval {
            Button("Approve Keepy Uppy in Settings…") {
                monitor.openApprovalSettings()
            }
        }
```

- [ ] **Step 4: Regenerate, build, test**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 10/10.

Registration itself cannot be exercised unsigned — deferred to Task 10.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/HelperInstaller.swift Sources/PowerMonitor.swift Sources/MenuContent.swift
git commit -m "Register the helper on demand and surface approval"
```

---

### Task 9: The CLI

**Files:**
- Modify: `CLI/main.swift`

**Interfaces:**
- Produces: `keepy-uppy on|off|status`, exiting 0 on success and 1 on failure. This is what makes the Shortcuts/SSH path work with no further Mac-side code (spec §14).

- [ ] **Step 1: Implement**

`CLI/main.swift`:

```swift
import Foundation

func connect() -> HelperProtocol? {
    let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    if SigningRequirement.isEnforced {
        connection.setCodeSigningRequirement(SigningRequirement.requirement)
    }
    connection.resume()
    return connection.remoteObjectProxyWithErrorHandler { error in
        FileHandle.standardError.write("keepy-uppy: \(error.localizedDescription)\n".data(using: .utf8)!)
    } as? HelperProtocol
}

func usage() -> Never {
    print("usage: keepy-uppy on|off|status")
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 2, let proxy = connect() else { usage() }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

switch arguments[1] {
case "on", "off":
    proxy.requestKeepAwake(arguments[1] == "on") { ok, message in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(message ?? "failed")\n".data(using: .utf8)!) }
        exitCode = ok ? 0 : 1
        semaphore.signal()
    }
case "status":
    proxy.currentState { disabled in
        print(disabled ? "keeping awake" : "normal sleep")
        semaphore.signal()
    }
default:
    usage()
}

_ = semaphore.wait(timeout: .now() + 10)
exit(exitCode)
```

- [ ] **Step 2: Build and check the usage path**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`.

Run: `"build/Build/Products/Debug/Keepy Uppy.app/Contents/MacOS/keepy-uppy"; echo "exit=$?"`
Expected: prints the usage line and `exit=2`. (`on`/`off`/`status` need a registered helper — deferred to Task 10.)

- [ ] **Step 3: Commit**

```bash
git add "Keepy Uppy.xcodeproj" CLI/main.swift
git commit -m "Add keepy-uppy CLI driving the helper"
```

---

### Task 10: Packaging, Team ID substitution, and README

**Files:**
- Modify: `justfile`, `README.md`

**Interfaces:**
- Produces: a build that substitutes the real Team ID into `SigningRequirement`, signs all three executables, and a README documenting the new approval flow, the CLI, and the manual verification checklist.

- [ ] **Step 1: Substitute the Team ID at build time**

The requirement string needs the real Team ID, which must not be committed. Add to `justfile` a recipe that rewrites the constant into the build tree, and make `archive` depend on it:

```just
teamid:
    @test -n "{{team_id}}" || { echo "Set KEEPY_UPPY_TEAM_ID (see README)"; exit 1; }
    sed -i '' 's/REPLACE_WITH_TEAM_ID/{{team_id}}/' Shared/SigningRequirement.swift
    @echo "Substituted Team ID into SigningRequirement.swift"

restore-teamid:
    git checkout -- Shared/SigningRequirement.swift
```

Change the `archive` recipe's dependency line to `archive: generate teamid` and append `restore-teamid` semantics by running it at the end of `export`:

```just
export: archive
    rm -rf "{{export_path}}"
    sed "s/KEEPY_UPPY_TEAM_ID/{{team_id}}/" packaging/ExportOptions.plist > "{{derived_data}}/ExportOptions.plist"
    xcodebuild -exportArchive \
        -archivePath "{{archive_path}}" \
        -exportPath "{{export_path}}" \
        -exportOptionsPlist "{{derived_data}}/ExportOptions.plist"
    just restore-teamid
```

- [ ] **Step 2: Verify recipes still parse and dev flow is unaffected**

Run: `just --list`
Expected: all recipes listed including `teamid` and `restore-teamid`, no parse errors.

Run: `just test`
Expected: `** TEST SUCCEEDED **`, 10/10.

Run: `unset KEEPY_UPPY_TEAM_ID; just teamid`
Expected: fails with `Set KEEPY_UPPY_TEAM_ID (see README)` and leaves the source file untouched (`git diff --quiet Shared/SigningRequirement.swift` exits 0).

- [ ] **Step 3: Update the README**

Replace the "Known limitation" section (the low-battery prompt caveat no longer applies) with:

```markdown
## How it works

Keepy Uppy installs a small privileged helper the first time you turn it on.
macOS asks you to approve it once in System Settings → General → Login Items
& Extensions; after that, toggling never prompts again.

The helper is a dead man's switch: it keeps sleep disabled only while Keepy
Uppy is connected. Quit the app, force-quit it, or delete it, and normal
sleep comes straight back. It also resets to normal sleep whenever it
starts, so a crash can never leave your Mac stranded awake.

## Command line

The bundled CLI drives the same helper:

    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" on
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" off
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" status

This is what makes remote control work: an iOS Shortcut using "Run Script
Over SSH" can call it from your Home Screen, Control Center, the Action
Button, or an NFC tag — no iOS app required.
```

Add to the manual test checklist:

```markdown
- [ ] First toggle registers the helper and prompts for approval exactly once
- [ ] After approval, toggling on and off never prompts again
- [ ] `pmset -g | grep SleepDisabled` tracks the menu state
- [ ] Force-quitting the app (Activity Monitor) restores sleep within seconds
- [ ] Deleting the app while enabled restores sleep
- [ ] `keepy-uppy on|off|status` works and agrees with the menu
- [ ] A Release build refuses connections from an unsigned binary
```

- [ ] **Step 4: Commit**

```bash
git add justfile README.md
git commit -m "Substitute Team ID at build time and document the helper"
```

- [ ] **Step 5: Report the deferred human verification**

Everything in the Step 3 checklist requires a signed build and a human. List it explicitly in the task report as deferred — do not mark this plan complete as if it were verified.
