# Keepy Uppy v2 — Plan 1 of 3: Daemon Core

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md`

**Goal:** Build the root daemon that *is* Keepy Uppy — the authoritative session table, the session and safety engines, and the privileged write — so that later plans can add the agent, CLI, and optional UI as clients of it.

**Scope:** Plan 1 of 3, covering spec §2 (daemon), §4 (security), §5 (session model), §6 (bundle self-check) and §7 (safety). Plan 2 adds the agent and CLI, at which point the **headless product is complete**. Plan 3 adds the optional menu-bar UI.

At the end of this plan the daemon is functionally complete but has no clients: the v1 menu-bar app keeps working through its existing `osascript` path, untouched, and is rewired in plan 3. That is deliberate — the optional component is built last, and nothing breaks in between.

**Architecture:** A root LaunchDaemon (`KeepyUppyHelper`) embedded in the app bundle owns everything authoritative. Its two engines — session and safety — are **pure reducers with injected time and no I/O**, so the code running as root is small, deterministic, and fully unit-tested. Observation and actuation live in thin wrappers around them.

**Tech Stack:** Swift, `NSXPCListener`, `SMAppService.daemon`, IOKit (`IOPMSetSystemPowerSetting` via a bridging header; `IOPSCopyPowerSourcesInfo`, `ProcessInfo.thermalState`, and `AppleClamshellState` for safety inputs), xcodegen, just/xcodebuild.

**Tasks 1–5 are already complete** (project structure, IOKit power layer, client-table reducer, XPC listener, signature pinning) and carry forward unchanged from the pre-rearchitecture draft of this plan. Task 6 onward is written against the headless-first spec.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md`. Where this plan and the spec disagree, the spec wins — report the conflict rather than guessing.
- Identifiers now also include the per-user agent, `au.com.workwireless.keepy-uppy.agent`, built in plan 2. The signing requirement's bundle-prefix scoping already admits it; no security change is needed when it arrives.
- Deployment target stays **macOS 13.0**. Both load-bearing APIs (`SMAppService.daemon(plistName:)`, `NSXPCConnection.setCodeSigningRequirement`) are `API_AVAILABLE(macos(13.0))` — verified in the SDK.
- Identifiers, exactly: app `au.com.workwireless.keepy-uppy`; helper label and Mach service `au.com.workwireless.keepy-uppy.helper`; CLI `au.com.workwireless.keepy-uppy.cli`.
- **Signing is required to verify anything past the XPC handshake.** `SMAppService` will not register a daemon from an ad-hoc-signed build. Builds and unit tests run unsigned; registration, approval, and the end-to-end toggle are manual steps on a signed build, deferred to human verification (§ each task says which of its checks are deferred).
- The following were verified on this machine before this plan was written. Treat them as known-good and do not redesign around them:
  - The xcodegen embedding syntax in Task 1 produces exactly `Contents/MacOS/{KeepyUppyHelper,keepy-uppy}` and `Contents/Library/LaunchDaemons/<label>.plist`. Verified by building a scratch project and listing the bundle.
  - The signing requirement must use an explicit, **parenthesised** OR-list of the four exact identifiers. Verified with `codesign -R` against ad-hoc-signed binaries: the requirement language has NO wildcard for `identifier` (a trailing `*` is a literal asterisk, matching nothing real), and `and` binds tighter than `or`, so omitting the parentheses would admit any binary claiming the last identifier with no Team ID check at all. `csreq` proves a requirement parses, never that it matches — semantics need `codesign -R`.
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

### Task 6: Session model and session table

**Files:**
- Create: `Shared/Session.swift`, `Shared/SessionTable.swift`
- Test: `Tests/SessionTableTests.swift`

`ClientTable` and its tests are deliberately **left in place** until Task 9
repoints the helper off them. Deleting them here would orphan
`Helper/HelperService.swift`'s reference and leave the branch red for three
tasks; additive-then-delete keeps every task green.

**Interfaces:**
- Produces: `ClientID`, `SessionKind`, `SessionPersistence`, `SessionOrigin`, `Session`, and `SessionTable` with `insert`, `remove(id:)`, `removeAll(ownedBy:)`, `sessions`, `desiredKeepAwake`.

`ClientTable` is superseded rather than extended — a session table keyed by session id with an owner field expresses everything the old client table did (a client's keep-awake request is one session it owns) plus everything it could not. Its six tests are re-expressed here, so this is not a coverage regression.

- [ ] **Step 1: Write the failing tests**

`Tests/SessionTableTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class SessionTableTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")
    private let bob = ClientID(rawValue: "bob")

    private func session(_ id: String, owner: ClientID,
                         persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                kind: .indefinite, owner: owner,
                persistence: persistence, origin: .manual, startedAt: t0)
    }

    func testEmptyTableWantsSleepEnabled() {
        XCTAssertFalse(SessionTable().desiredKeepAwake)
    }

    func testAnySessionKeepsAwake() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemovingLastSessionRestoresSleep() {
        var table = SessionTable()
        let a = session("01", owner: alice)
        let b = session("02", owner: bob)
        table.insert(a); table.insert(b)
        table.remove(id: a.id)
        XCTAssertTrue(table.desiredKeepAwake, "bob's session still holds it")
        table.remove(id: b.id)
        XCTAssertFalse(table.desiredKeepAwake, "no sessions left, sleep must come back")
    }

    func testRemoveAllOwnedByEndsOnlyClientBoundSessions() {
        var table = SessionTable()
        table.insert(session("01", owner: alice, persistence: .clientBound))
        table.insert(session("02", owner: alice, persistence: .detached))
        let ended = table.removeAll(ownedBy: alice)
        XCTAssertEqual(ended.count, 1, "detached sessions survive their owner")
        XCTAssertTrue(table.desiredKeepAwake)
    }

    func testRemoveAllOwnedByLeavesOtherOwnersAlone() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.insert(session("02", owner: bob))
        _ = table.removeAll(ownedBy: alice)
        XCTAssertEqual(table.sessions.count, 1)
        XCTAssertEqual(table.sessions.first?.owner, bob)
    }

    func testRemovingUnknownSessionIsHarmless() {
        var table = SessionTable()
        table.insert(session("01", owner: alice))
        table.remove(id: UUID())
        XCTAssertTrue(table.desiredKeepAwake)
        XCTAssertEqual(table.sessions.count, 1)
    }
}
```

Also add, in the same file:

```swift
/// `isDaemonEvaluable` decides whether a session survives the agent going
/// away (spec §5). A wrong answer is a safety bug the type checker cannot
/// catch — a switch stays exhaustive whichever branch a case is in — so
/// every case is pinned explicitly.
final class SessionKindEvaluationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDaemonEvaluableKinds() {
        XCTAssertTrue(SessionKind.indefinite.isDaemonEvaluable)
        XCTAssertTrue(SessionKind.duration(until: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.untilTime(t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.lease(expires: t0).isDaemonEvaluable)
        XCTAssertTrue(SessionKind.whileOnACPower.isDaemonEvaluable)
    }

    func testAgentEvaluatedKinds() {
        XCTAssertFalse(SessionKind.whileAppRunning(bundleID: "com.apple.dt.Xcode").isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileExternalDisplay.isDaemonEvaluable)
        XCTAssertFalse(SessionKind.whileCPUBusy(threshold: 0.5).isDaemonEvaluable)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: compile failure — none of these types exist yet.

- [ ] **Step 3: Implement the model**

`Shared/Session.swift`:

```swift
import Foundation

struct ClientID: Hashable, Codable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

enum SessionKind: Equatable, Codable {
    case indefinite
    case duration(until: Date)
    case untilTime(Date)
    case lease(expires: Date)
    case whileAppRunning(bundleID: String)
    case whileExternalDisplay
    case whileOnACPower
    case whileCPUBusy(threshold: Double)

    /// Kinds the daemon can evaluate alone. Everything else needs the agent,
    /// and so cannot outlive it (spec §5).
    var isDaemonEvaluable: Bool {
        switch self {
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower: return true
        case .whileAppRunning, .whileExternalDisplay, .whileCPUBusy: return false
        }
    }
}

enum SessionPersistence: String, Codable { case clientBound, detached }
enum SessionOrigin: String, Codable { case manual, trigger }

struct Session: Equatable, Codable, Identifiable {
    let id: UUID
    let kind: SessionKind
    let owner: ClientID
    let persistence: SessionPersistence
    let origin: SessionOrigin
    let startedAt: Date
}
```

`Shared/SessionTable.swift`:

```swift
import Foundation

/// The authoritative set of live sessions. Sleep is disabled while any
/// session is alive; removing the last one restores it (spec §5).
struct SessionTable {
    private var storage: [UUID: Session] = [:]

    var sessions: [Session] { Array(storage.values) }
    var desiredKeepAwake: Bool { !storage.isEmpty }

    mutating func insert(_ session: Session) {
        storage[session.id] = session
    }

    @discardableResult
    mutating func remove(id: UUID) -> Session? {
        storage.removeValue(forKey: id)
    }

    /// Ends the client-bound sessions of a departing owner. Detached
    /// sessions deliberately survive — that is what lets `keepy-uppy on`
    /// outlive the process that asked for it.
    @discardableResult
    mutating func removeAll(ownedBy owner: ClientID) -> [Session] {
        let doomed = storage.values.filter {
            $0.owner == owner && $0.persistence == .clientBound
        }
        for session in doomed { storage.removeValue(forKey: session.id) }
        return doomed
    }
}
```

- [ ] **Step 4: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 26/26 (18 carried forward + 8 new). Both tables coexist for now; the client table's 6 tests still pass and are retired in Task 9.

- [ ] **Step 5: Commit**

```bash
git add Shared/Session.swift Shared/SessionTable.swift Tests/SessionTableTests.swift "Keepy Uppy.xcodeproj"
git commit -m "Add session table alongside the client table"
```

---

### Task 7: Session engine

**Files:**
- Create: `Shared/SessionEngine.swift`
- Test: `Tests/SessionEngineTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionTable` (Task 6).
- Produces: `SessionEvent`, `SessionEngine` with `mutating func apply(_ event: SessionEvent, now: Date) -> [Session]` (returns ended sessions) and `var desiredKeepAwake: Bool`.

**Time is always injected, never read inside the engine.** That is what lets an eight-hour session be tested instantly, and it is not optional.

- [ ] **Step 1: Write the failing tests**

`Tests/SessionEngineTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class SessionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = ClientID(rawValue: "alice")

    private func make(_ kind: SessionKind,
                      persistence: SessionPersistence = .clientBound) -> Session {
        Session(id: UUID(), kind: kind, owner: alice,
                persistence: persistence, origin: .manual, startedAt: t0)
    }

    func testStartingASessionKeepsAwake() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite)), now: t0)
        XCTAssertTrue(engine.desiredKeepAwake)
    }

    func testDurationSessionExpiresOnTick() {
        var engine = SessionEngine()
        let session = make(.duration(until: t0.addingTimeInterval(3600)))
        _ = engine.apply(.start(session), now: t0)

        let early = engine.apply(.tick, now: t0.addingTimeInterval(3599))
        XCTAssertTrue(early.isEmpty)
        XCTAssertTrue(engine.desiredKeepAwake)

        let late = engine.apply(.tick, now: t0.addingTimeInterval(3601))
        XCTAssertEqual(late.count, 1)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testEightHourSessionIsTestedInstantly() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.duration(until: t0.addingTimeInterval(8 * 3600)))), now: t0)
        XCTAssertTrue(engine.apply(.tick, now: t0.addingTimeInterval(8 * 3600 - 1)).isEmpty)
        XCTAssertEqual(engine.apply(.tick, now: t0.addingTimeInterval(8 * 3600 + 1)).count, 1)
    }

    func testExpiredLeaseEndsButRenewalExtendsIt() {
        var engine = SessionEngine()
        let session = make(.lease(expires: t0.addingTimeInterval(60)))
        _ = engine.apply(.start(session), now: t0)
        _ = engine.apply(.renewLease(id: session.id, until: t0.addingTimeInterval(120)), now: t0.addingTimeInterval(30))
        XCTAssertTrue(engine.apply(.tick, now: t0.addingTimeInterval(90)).isEmpty, "renewed")
        XCTAssertEqual(engine.apply(.tick, now: t0.addingTimeInterval(121)).count, 1, "expired")
    }

    func testClientDisconnectEndsClientBoundButNotDetached() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite, persistence: .clientBound)), now: t0)
        _ = engine.apply(.start(make(.indefinite, persistence: .detached)), now: t0)
        let ended = engine.apply(.clientDisconnected(alice), now: t0)
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(engine.desiredKeepAwake, "the detached session survives")
    }

    func testAgentDisappearanceEndsOnlyAgentEvaluatedSessions() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.duration(until: t0.addingTimeInterval(3600)))), now: t0)
        _ = engine.apply(.start(make(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))), now: t0)
        let ended = engine.apply(.agentDisappeared, now: t0)
        XCTAssertEqual(ended.count, 1, "the app-watching session cannot be verified any more")
        XCTAssertEqual(ended.first?.kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(engine.desiredKeepAwake, "the daemon-evaluable session is unaffected")
    }

    func testConditionEndedStopsThatSession() {
        var engine = SessionEngine()
        let session = make(.whileExternalDisplay)
        _ = engine.apply(.start(session), now: t0)
        XCTAssertEqual(engine.apply(.conditionEnded(id: session.id), now: t0).count, 1)
        XCTAssertFalse(engine.desiredKeepAwake)
    }

    func testStopAllEndsEverythingIncludingDetached() {
        var engine = SessionEngine()
        _ = engine.apply(.start(make(.indefinite, persistence: .detached)), now: t0)
        _ = engine.apply(.start(make(.indefinite, persistence: .clientBound)), now: t0)
        XCTAssertEqual(engine.apply(.stopAll, now: t0).count, 2)
        XCTAssertFalse(engine.desiredKeepAwake)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — `SessionEngine` does not exist.

- [ ] **Step 3: Implement**

`Shared/SessionEngine.swift`:

```swift
import Foundation

enum SessionEvent {
    case start(Session)
    case stop(id: UUID)
    case stopAll
    case clientDisconnected(ClientID)
    /// The user-session agent went away, so agent-evaluated conditions can no
    /// longer be verified (spec §5: no session outlives its evidence).
    case agentDisappeared
    case conditionEnded(id: UUID)
    case renewLease(id: UUID, until: Date)
    case tick
}

/// Pure reducer over the session table. Holds no clock, performs no I/O:
/// `now` is supplied by the caller on every event.
struct SessionEngine {
    private var table = SessionTable()

    var sessions: [Session] { table.sessions }
    var desiredKeepAwake: Bool { table.desiredKeepAwake }

    @discardableResult
    mutating func apply(_ event: SessionEvent, now: Date) -> [Session] {
        var ended: [Session] = []

        switch event {
        case .start(let session):
            table.insert(session)

        case .stop(let id):
            if let session = table.remove(id: id) { ended.append(session) }

        case .stopAll:
            ended.append(contentsOf: table.sessions)
            for session in table.sessions { table.remove(id: session.id) }

        case .clientDisconnected(let owner):
            ended.append(contentsOf: table.removeAll(ownedBy: owner))

        case .agentDisappeared:
            for session in table.sessions where !session.kind.isDaemonEvaluable {
                table.remove(id: session.id)
                ended.append(session)
            }

        case .conditionEnded(let id):
            if let session = table.remove(id: id) { ended.append(session) }

        case .renewLease(let id, let until):
            guard let existing = table.remove(id: id) else { break }
            table.insert(Session(id: existing.id, kind: .lease(expires: until),
                                 owner: existing.owner, persistence: existing.persistence,
                                 origin: existing.origin, startedAt: existing.startedAt))

        case .tick:
            break
        }

        // Time-based expiry is re-evaluated after every event, not only on
        // ticks, so a stale session can never be observed as alive.
        for session in table.sessions where Self.hasExpired(session, at: now) {
            table.remove(id: session.id)
            ended.append(session)
        }

        return ended
    }

    private static func hasExpired(_ session: Session, at now: Date) -> Bool {
        switch session.kind {
        case .duration(let until), .untilTime(let until), .lease(let until):
            return now >= until
        case .indefinite, .whileAppRunning, .whileExternalDisplay,
             .whileOnACPower, .whileCPUBusy:
            return false
        }
    }
}
```

Two further tests are required, because the properties they guard are
invisible to the eight above — a reviewer confirmed every one of them would
still pass with the regression in place:

- `testNonTickEventStillSweepsAnExpiredSession` — drives a NON-tick event
  while an unrelated session has already passed its deadline, and asserts the
  expired one is reported in `ended`. Without it, moving the expiry sweep
  inside `case .tick` goes unnoticed, and a stale session can be observed
  alive between ticks.
- `testRenewLeasePreservesIdentityAndOnlyMovesDeadline` — asserts `id`,
  `owner`, `persistence`, `origin`, and `startedAt` all survive a renewal and
  only the deadline moves. Dropping `startedAt` would silently corrupt the
  max-duration backstop the safety engine depends on; minting a fresh `id`
  would otherwise pass too.

Prove both are real by injecting each regression, confirming the suite fails
in that specific test, and reverting.

- [ ] **Step 4: Run tests**

Run: `xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, 36/36 (26 + 10 new).

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Shared/SessionEngine.swift Tests/SessionEngineTests.swift
git commit -m "Add pure session engine with injected time"
```

---

### Task 8: Safety engine

**Files:**
- Create: `Shared/SafetyEngine.swift`
- Test: `Tests/SafetyEngineTests.swift`

**Interfaces:**
- Produces: `ThermalLevel`, `SafetyConfig`, `SafetyInputs`, `SafetyReason`, `SafetyOutcome`, and `SafetyEngine` with `mutating func evaluate(_ inputs: SafetyInputs) -> SafetyOutcome` and `var triggersSuppressed: Bool`.

This is the differentiating feature and it runs as root, so it is written as a pure reducer and tested hard — including an explicit regression test for the fight-the-user loop (spec §7).

- [ ] **Step 1: Write the failing tests**

`Tests/SafetyEngineTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class SafetyEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(thermal: ThermalLevel = .nominal,
                        battery: Int? = 80,
                        onBattery: Bool = false,
                        lidClosed: Bool = false,
                        oldestAge: TimeInterval? = 60,
                        now: Date? = nil) -> SafetyInputs {
        SafetyInputs(thermal: thermal, batteryPercentage: battery, onBattery: onBattery,
                     lidClosed: lidClosed, oldestSessionAge: oldestAge, now: now ?? t0)
    }

    func testNominalConditionsDoNothing() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs()), .none)
    }

    func testCriticalThermalStopsEverythingImmediately() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    func testLowBatteryOnBatteryPowerStops() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(battery: 5, onBattery: true, lidClosed: true)),
                       .stopAll(reason: .lowBattery))
    }

    func testLowBatteryOnACPowerDoesNotStop() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(battery: 5, onBattery: false)), .none)
    }

    func testMaxDurationBackstopStopsIndefiniteSessions() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(oldestAge: 9 * 3600, lidClosed: true)),
                       .stopAll(reason: .maxDuration))
    }

    func testLidOpenGetsAGraceWarningFirst() {
        var engine = SafetyEngine(config: .default)
        let outcome = engine.evaluate(inputs(thermal: .serious, lidClosed: false))
        XCTAssertEqual(outcome, .warn(reason: .thermal, actAt: t0.addingTimeInterval(60)))
    }

    func testLidClosedSkipsTheWarningNobodyCouldSee() {
        var engine = SafetyEngine(config: .default)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, lidClosed: true)),
                       .stopAll(reason: .thermal))
    }

    func testWarningBecomesAStopWhenTheGracePeriodElapses() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .serious, now: t0.addingTimeInterval(61))),
                       .stopAll(reason: .thermal))
    }

    func testRecoveryDuringGraceCancelsTheStop() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .serious))
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(30))), .none)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .nominal, now: t0.addingTimeInterval(90))), .none)
    }

    /// The regression test for the worst bug this product could ship: a
    /// safety stop that a still-true trigger condition immediately undoes.
    func testTriggersStaySuppressedUntilTheConditionClearsWithHysteresis() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(thermal: .critical, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)

        // Still hot: suppressed.
        _ = engine.evaluate(inputs(thermal: .serious, lidClosed: true, now: t0.addingTimeInterval(120)))
        XCTAssertTrue(engine.triggersSuppressed)

        // Cooled to nominal but inside the cooldown: still suppressed.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(150)))
        XCTAssertTrue(engine.triggersSuppressed)

        // Nominal and past the cooldown: released.
        _ = engine.evaluate(inputs(thermal: .nominal, lidClosed: true, now: t0.addingTimeInterval(400)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    func testBatterySuppressionNeedsHysteresisNotJustCrossingBack() {
        var engine = SafetyEngine(config: .default)
        _ = engine.evaluate(inputs(battery: 9, onBattery: true, lidClosed: true))
        XCTAssertTrue(engine.triggersSuppressed)
        // 11% is above the 10% cutoff but inside the hysteresis band.
        _ = engine.evaluate(inputs(battery: 11, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(400)))
        XCTAssertTrue(engine.triggersSuppressed)
        _ = engine.evaluate(inputs(battery: 20, onBattery: true, lidClosed: true, now: t0.addingTimeInterval(500)))
        XCTAssertFalse(engine.triggersSuppressed)
    }

    func testDisabledGuardsDoNothing() {
        var config = SafetyConfig.default
        config.thermalGuardEnabled = false
        config.batteryCutoff = nil
        config.maxSessionDuration = nil
        var engine = SafetyEngine(config: config)
        XCTAssertEqual(engine.evaluate(inputs(thermal: .critical, battery: 1,
                                              onBattery: true, oldestAge: 100 * 3600)), .none)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — `SafetyEngine` does not exist.

- [ ] **Step 3: Implement**

`Shared/SafetyEngine.swift`:

```swift
import Foundation

enum ThermalLevel: Int, Comparable, Codable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

enum SafetyReason: String, Equatable, Codable {
    case thermal, lowBattery, maxDuration
}

enum SafetyOutcome: Equatable {
    case none
    case warn(reason: SafetyReason, actAt: Date)
    case stopAll(reason: SafetyReason)
}

struct SafetyConfig {
    var thermalGuardEnabled: Bool
    /// nil disables the guard.
    var batteryCutoff: Int?
    /// nil disables the backstop.
    var maxSessionDuration: TimeInterval?
    var lidClosedStricter: Bool
    var gracePeriod: TimeInterval
    var cooldown: TimeInterval
    /// Percentage points above the cutoff the battery must recover before
    /// triggers are released again.
    var batteryHysteresis: Int

    static let `default` = SafetyConfig(
        thermalGuardEnabled: true,
        batteryCutoff: 10,
        maxSessionDuration: 8 * 3600,
        lidClosedStricter: true,
        gracePeriod: 60,
        cooldown: 300,
        batteryHysteresis: 5
    )
}

struct SafetyInputs {
    let thermal: ThermalLevel
    let batteryPercentage: Int?
    let onBattery: Bool
    let lidClosed: Bool
    let oldestSessionAge: TimeInterval?
    let now: Date
}

/// Pure reducer. No I/O, no clock of its own — every input including `now`
/// arrives in `SafetyInputs`, so all of this is testable instantly.
struct SafetyEngine {
    let config: SafetyConfig
    private var pendingWarning: (reason: SafetyReason, actAt: Date)?
    private var suppressedSince: Date?
    private var suppressionReason: SafetyReason?

    init(config: SafetyConfig) { self.config = config }

    /// True while a trigger-driven start must not be honoured. Manual starts
    /// are always allowed; this only gates automation (spec §7).
    var triggersSuppressed: Bool { suppressedSince != nil }

    mutating func evaluate(_ inputs: SafetyInputs) -> SafetyOutcome {
        releaseSuppressionIfClear(inputs)

        guard let reason = breach(inputs) else {
            pendingWarning = nil
            return .none
        }

        // The lid being shut means nobody can see a warning, so acting late
        // to display one is exactly backwards.
        let warningIsPointless = inputs.lidClosed
        if warningIsPointless || reason == .maxDuration {
            return stop(reason: reason, at: inputs.now)
        }

        if let pending = pendingWarning, pending.reason == reason {
            return inputs.now >= pending.actAt
                ? stop(reason: reason, at: inputs.now)
                : .warn(reason: reason, actAt: pending.actAt)
        }

        let actAt = inputs.now.addingTimeInterval(config.gracePeriod)
        pendingWarning = (reason, actAt)
        return .warn(reason: reason, actAt: actAt)
    }

    private mutating func stop(reason: SafetyReason, at now: Date) -> SafetyOutcome {
        pendingWarning = nil
        suppressedSince = now
        suppressionReason = reason
        return .stopAll(reason: reason)
    }

    private func breach(_ inputs: SafetyInputs) -> SafetyReason? {
        if config.thermalGuardEnabled {
            let limit: ThermalLevel = (inputs.lidClosed && config.lidClosedStricter)
                ? .serious : .critical
            if inputs.thermal >= limit { return .thermal }
        }
        if let cutoff = config.batteryCutoff, inputs.onBattery,
           let level = inputs.batteryPercentage {
            let effective = (inputs.lidClosed && config.lidClosedStricter) ? cutoff + 5 : cutoff
            if level <= effective { return .lowBattery }
        }
        if let maximum = config.maxSessionDuration, let age = inputs.oldestSessionAge,
           age >= maximum {
            return .maxDuration
        }
        return nil
    }

    private mutating func releaseSuppressionIfClear(_ inputs: SafetyInputs) {
        guard let since = suppressedSince, let reason = suppressionReason else { return }
        guard inputs.now.timeIntervalSince(since) >= config.cooldown else { return }

        let recovered: Bool
        switch reason {
        case .thermal:
            recovered = inputs.thermal == .nominal
        case .lowBattery:
            guard let cutoff = config.batteryCutoff else { recovered = true; break }
            recovered = (inputs.batteryPercentage ?? 100) >= cutoff + config.batteryHysteresis
        case .maxDuration:
            recovered = (inputs.oldestSessionAge ?? 0) < (config.maxSessionDuration ?? .infinity)
        }

        if recovered {
            suppressedSince = nil
            suppressionReason = nil
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, 48/48 (36 + 12 new).

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Shared/SafetyEngine.swift Tests/SafetyEngineTests.swift
git commit -m "Add pure safety engine with hysteresis and trigger suppression"
```

---

### Task 9: Daemon runtime — observers, engine wiring, bundle self-check

**Files:**
- Create: `Helper/SafetyObservers.swift`, `Helper/DaemonRuntime.swift`
- Modify: `Helper/HelperService.swift` (replace `ClientTable` usage), `Helper/main.swift`

**Interfaces:**
- Consumes: `SessionEngine` (Task 7), `SafetyEngine` (Task 8), `PowerControl` (Task 2).
- Produces: `SafetyObserving` protocol plus its live implementation, and `DaemonRuntime` — the single serialised owner of both engines that all XPC calls funnel through.

This task repoints `HelperService` off `ClientTable` and onto the runtime, and **deletes `Shared/ClientTable.swift` and `Tests/ClientTableTests.swift`** — Task 6 deliberately left them in place so the branch stayed green in between. Their six tests are already re-expressed as session-table tests, so this is not a coverage regression. The engines stay pure: every clock read, IOKit call, and notification lives here.

- [ ] **Step 1: Implement the observers behind a protocol**

`Helper/SafetyObservers.swift`:

```swift
import Foundation
import IOKit

/// Everything the safety engine needs to see, behind a protocol so the
/// engine's tests never touch a framework.
protocol SafetyObserving {
    func thermalLevel() -> ThermalLevel
    func batteryPercentage() -> Int?
    func isOnBatteryPower() -> Bool
    func isLidClosed() -> Bool
}

struct SystemSafetyObserver: SafetyObserving {
    func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    func batteryPercentage() -> Int? { PowerControl.batteryState().percentage }

    func isOnBatteryPower() -> Bool { PowerControl.batteryState().source == .battery }

    /// AppleClamshellState on IOPMrootDomain reports whether the lid is
    /// actually shut — the genuinely dangerous configuration, where the
    /// machine has no way to dump heat.
    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        else { return false }
        return property
    }
}
```

- [ ] **Step 2: Implement the runtime**

`Helper/DaemonRuntime.swift`:

```swift
import Foundation
import os

let helperLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.helper", category: "daemon")

/// Serialises both engines behind one queue: XPC replies arrive on arbitrary
/// threads, and the engines are value types with no locking of their own.
final class DaemonRuntime {
    private let queue = DispatchQueue(label: "au.com.workwireless.keepy-uppy.helper.runtime")
    private var sessions = SessionEngine()
    private var safety = SafetyEngine(config: .default)
    private let observer: SafetyObserving
    private let bundlePath: String
    private var timer: DispatchSourceTimer?

    init(observer: SafetyObserving = SystemSafetyObserver(),
         bundlePath: String = Bundle.main.bundlePath) {
        self.observer = observer
        self.bundlePath = bundlePath
    }

    /// Converge to safe before serving anyone, so a daemon crash — or an
    /// upgrade from v1, which left disablesleep set persistently — cannot
    /// leave the Mac stranded awake.
    func start() {
        queue.sync {
            let ok = PowerControl.setSleepDisabled(false)
            helperLogger.log("Daemon start: forced sleep enabled, success=\(ok)")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tickLocked() }
        timer.resume()
        self.timer = timer
    }

    func startSession(_ session: Session) -> Bool {
        queue.sync {
            sessions.apply(.start(session), now: Date())
            return applyLocked()
        }
    }

    func stopSession(id: UUID) { queue.sync { _ = sessions.apply(.stop(id: id), now: Date()); _ = applyLocked() } }

    func stopAll() { queue.sync { _ = sessions.apply(.stopAll, now: Date()); _ = applyLocked() } }

    func clientDisconnected(_ owner: ClientID) {
        queue.sync {
            let ended = sessions.apply(.clientDisconnected(owner), now: Date())
            if !ended.isEmpty { helperLogger.log("Client \(owner.rawValue) left; ended \(ended.count) session(s)") }
            _ = applyLocked()
        }
    }

    func agentDisappeared() {
        queue.sync {
            let ended = sessions.apply(.agentDisappeared, now: Date())
            if !ended.isEmpty {
                helperLogger.log("Agent gone; ended \(ended.count) unverifiable session(s)")
            }
            _ = applyLocked()
        }
    }

    func conditionEnded(id: UUID) { queue.sync { _ = sessions.apply(.conditionEnded(id: id), now: Date()); _ = applyLocked() } }

    func currentSessions() -> [Session] { queue.sync { sessions.sessions } }

    func isKeepingAwake() -> Bool { queue.sync { PowerControl.sleepDisabled() } }

    // MARK: - Private, always called on `queue`

    private func tickLocked() {
        guard bundleStillExists() else {
            helperLogger.error("App bundle is gone; restoring sleep and exiting")
            _ = PowerControl.setSleepDisabled(false)
            exit(0)
        }

        let now = Date()
        _ = sessions.apply(.tick, now: now)

        let oldest = sessions.sessions.map { now.timeIntervalSince($0.startedAt) }.max()
        let outcome = safety.evaluate(SafetyInputs(
            thermal: observer.thermalLevel(),
            batteryPercentage: observer.batteryPercentage(),
            onBattery: observer.isOnBatteryPower(),
            lidClosed: observer.isLidClosed(),
            oldestSessionAge: oldest,
            now: now))

        switch outcome {
        case .none:
            break
        case .warn(let reason, let actAt):
            helperLogger.log("Safety warning: \(reason.rawValue), acting at \(actAt)")
        case .stopAll(let reason):
            let ended = sessions.apply(.stopAll, now: now)
            helperLogger.error("Safety stop (\(reason.rawValue)); ended \(ended.count) session(s)")
        }

        _ = applyLocked()
    }

    private func bundleStillExists() -> Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }

    @discardableResult
    private func applyLocked() -> Bool {
        let desired = sessions.desiredKeepAwake
        return PowerControl.setSleepDisabled(desired)
    }
}
```

- [ ] **Step 3: Repoint `HelperService` at the runtime**

Replace `HelperState` in `Helper/HelperService.swift` entirely — the runtime supersedes it. `HelperService` keeps its per-client `clientID` and now forwards to `DaemonRuntime`:

```swift
import Foundation

final class HelperService: NSObject, HelperProtocol {
    private let runtime: DaemonRuntime
    private let clientID: ClientID

    init(runtime: DaemonRuntime, clientID: ClientID) {
        self.runtime = runtime
        self.clientID = clientID
    }

    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if enabled {
            let session = Session(id: UUID(), kind: .indefinite, owner: clientID,
                                  persistence: .clientBound, origin: .manual,
                                  startedAt: Date())
            reply(runtime.startSession(session), nil)
        } else {
            runtime.stopAll()
            reply(true, nil)
        }
    }

    func currentState(reply: @escaping (Bool) -> Void) { reply(runtime.isKeepingAwake()) }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
```

The richer session-oriented XPC surface lands in Task 10; this keeps the existing protocol working so the branch always builds.

- [ ] **Step 4: Update the listener delegate and `main.swift`**

In `Helper/HelperListenerDelegate.swift`, hold a `DaemonRuntime` instead of `HelperState`, derive a `ClientID` from the connection, and call `runtime.clientDisconnected(id)` from both `invalidationHandler` and `interruptionHandler`. Keep the `setCodeSigningRequirement` block from Task 5 exactly as it is, still before `resume()`.

```swift
        let id = ClientID(rawValue: String(UInt(bitPattern: ObjectIdentifier(newConnection).hashValue)))
        newConnection.exportedObject = HelperService(runtime: runtime, clientID: id)
        newConnection.invalidationHandler = { [runtime] in runtime.clientDisconnected(id) }
        newConnection.interruptionHandler = { [runtime] in runtime.clientDisconnected(id) }
```

In `Helper/main.swift`, replace `delegate.startup()` with the runtime's `start()`.

- [ ] **Step 5: Build and test**

Run: `xcodegen generate && xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, 42/42 (48 minus the 6 retired client-table tests), no new warnings.

Do not launch, load, or register the daemon — that needs root and signing, and is human-verified later.

- [ ] **Step 6: Commit**

```bash
git rm Shared/ClientTable.swift Tests/ClientTableTests.swift
git add "Keepy Uppy.xcodeproj" Helper
git commit -m "Wire session and safety engines into the daemon runtime"
```

Expected after deletion: 42 tests (the 6 client-table tests retire; session,
safety, and existing suites remain).

---

### Task 10: Session-oriented XPC surface

**Files:**
- Modify: `Shared/XPCProtocol.swift`, `Helper/HelperService.swift`, `Helper/HelperListenerDelegate.swift`

**Interfaces:**
- Produces: the protocol plan 2's agent and CLI are written against — session start/stop/list, lease renewal, and agent-only condition reporting.

- [ ] **Step 1: Extend the protocol**

Sessions cross the XPC boundary as JSON `Data` rather than as objects: `NSSecureCoding` whitelisting for a Swift enum with associated values is far more ceremony than encoding a `Codable` struct.

```swift
@objc protocol HelperProtocol {
    /// `sessionJSON` is a JSON-encoded `Session`. Replies with its id, or an error.
    func startSession(_ sessionJSON: Data, reply: @escaping (String?, String?) -> Void)
    func stopSession(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)
    func stopAllSessions(reply: @escaping (Bool, String?) -> Void)
    /// Replies with a JSON-encoded `[Session]`.
    func listSessions(reply: @escaping (Data?, String?) -> Void)
    func renewLease(_ sessionID: String, until: Date, reply: @escaping (Bool, String?) -> Void)

    /// Agent-only (spec §4): the daemon ignores this from any other client.
    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void)
    /// Agent-only. Registers this connection as the user-session observer, so
    /// its disappearance ends sessions whose evidence it was providing.
    func registerAsAgent(reply: @escaping (Bool, String?) -> Void)

    func currentState(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)
}
```

- [ ] **Step 1b: Close the cross-client isolation gaps (mandatory)**

Task 9's review identified three isolation defects that this task must fix
rather than inherit. All three are about one client being able to affect
another's sessions, which contradicts spec §4 ("every client is equally
entitled to start and stop **its own** sessions").

1. **`stopAllSessions` must scope to the caller by default.** Today
   `requestKeepAwake(false)` ends every client's sessions, including a
   `detached` CLI session started by someone else. Default behaviour stops
   only the caller's own; affecting everyone requires an explicit flag,
   matching the CLI's documented `off [--all | --session ID]` surface.
2. **`stopSession(_:)` must verify ownership.** `DaemonRuntime.stopSession(id:)`
   takes a bare UUID and ends any session regardless of owner. Before exposing
   it over XPC, check `session.owner == callerClientID` and reject otherwise,
   logging the rejection.
3. **`ClientID` must be genuinely unique, not a hash.** It is currently
   derived from `ObjectIdentifier(connection).hashValue`. Every isolation
   guarantee rests on client identity, so it must not be a value that can
   collide: mint a `UUID` per accepted connection instead.

`currentSessions()` returning all sessions daemon-wide is intentional and
stays — the UI must be able to show *why* the Mac is awake regardless of which
client started it (spec §9).

- [ ] **Step 2: Enforce the agent role**

Role is derived from the peer's signing identity, not from anything the client asserts. In `HelperListenerDelegate`, capture the connection's `processIdentifier` and resolve its bundle identifier; pass an `isAgent` flag into `HelperService`. In DEBUG, where signature checking is off, treat the flag as `true` and log loudly that role enforcement is disabled.

`HelperService` guards both agent-only methods:

```swift
    func reportConditionEnded(_ sessionID: String, reply: @escaping (Bool, String?) -> Void) {
        guard isAgent else {
            helperLogger.error("Rejected condition report from non-agent client")
            return reply(false, "not authorised")
        }
        guard let uuid = UUID(uuidString: sessionID) else { return reply(false, "bad id") }
        runtime.conditionEnded(id: uuid)
        reply(true, nil)
    }
```

- [ ] **Step 3: Route agent disappearance**

When the connection registered as the agent invalidates, call `runtime.agentDisappeared()` in addition to `clientDisconnected` — that is what enforces "no session outlives its evidence" for agent-evaluated kinds.

- [ ] **Step 4: Build and test**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, 42/42.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Shared/XPCProtocol.swift Helper
git commit -m "Add session-oriented XPC surface with agent role enforcement"
```

---

### Task 11: Agent plist, Team ID substitution, and README

**Files:**
- Create: `Launchd/au.com.workwireless.keepy-uppy.agent.plist`
- Modify: `project.yml`, `justfile`, `README.md`

**Interfaces:**
- Produces: the LaunchAgent plist shipped in the bundle ready for plan 2, build-time Team ID substitution, and documentation of the architecture.

The agent's *plist* ships now so the bundle layout is settled and reviewed once; its executable arrives in plan 2.

- [ ] **Step 1: Create the agent plist**

`Launchd/au.com.workwireless.keepy-uppy.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>au.com.workwireless.keepy-uppy.agent</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/KeepyUppyAgent</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>au.com.workwireless.keepy-uppy</string>
    </array>
</dict>
</plist>
```

Add it to the app target's `sources:` with a `copyFiles` build phase, destination `wrapper`, subpath `Contents/Library/LaunchAgents` — the same shape Task 1 verified for the daemon plist.

- [ ] **Step 2: Substitute the Team ID at build time**

The requirement string needs the real Team ID, which must not be committed. Add to `justfile`:

```just
teamid:
    @test -n "{{team_id}}" || { echo "Set KEEPY_UPPY_TEAM_ID (see README)"; exit 1; }
    sed -i '' 's/REPLACE_WITH_TEAM_ID/{{team_id}}/' Shared/SigningRequirement.swift
    @echo "Substituted Team ID into SigningRequirement.swift"

restore-teamid:
    git checkout -- Shared/SigningRequirement.swift
```

Make `archive` depend on `teamid` (`archive: generate teamid`) and end `export` with `just restore-teamid` so the placeholder is never left substituted in the working tree.

- [ ] **Step 3: Verify recipes and the dev flow**

Run: `just --list` → all recipes, no parse errors.
Run: `just test` → `** TEST SUCCEEDED **`, 42/42.
Run: `unset KEEPY_UPPY_TEAM_ID; just teamid` → fails with the guard message, and `git diff --quiet Shared/SigningRequirement.swift` exits 0 (source untouched).

- [ ] **Step 4: Document the architecture in the README**

Replace the "How it works" section with:

```markdown
## How it works

Keepy Uppy is headless-first. A small privileged daemon holds the actual
setting and enforces every safety guard; a per-user agent watches things
only your login session can see (which apps are running, which displays are
connected); and the menu-bar app is an optional view on top. The command
line drives the same daemon, so everything works over SSH with no UI.

macOS asks you to approve the background items once, in System Settings →
General → Login Items & Extensions. After that nothing ever prompts again.

No session outlives its evidence: timed sessions end on their own clock,
condition-based ones end when the condition ends or when the agent watching
it goes away, indefinite ones are capped by a maximum-duration backstop, and
any session ends the moment a safety guard fires. The daemon resets to normal
sleep when it starts and if the app is deleted, so your Mac can never be left
silently awake.
```

Add to the manual checklist:

```markdown
- [ ] Daemon and agent both register and appear as "Keepy Uppy" in Login Items
- [ ] Approving once is enough; no later prompts
- [ ] Deleting the app while a session is active restores sleep
- [ ] Killing the agent ends condition-based sessions but not timed ones
- [ ] A Release build refuses XPC connections from an unsigned binary
- [ ] A non-agent client's condition report is rejected and logged
```

- [ ] **Step 5: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Launchd justfile README.md
git commit -m "Ship agent plist, substitute Team ID at build time, document architecture"
```

- [ ] **Step 6: Report deferred verification**

Everything in the Step 4 checklist needs a signed build and a human. List it explicitly as deferred in the task report — do not present this plan as verified.
