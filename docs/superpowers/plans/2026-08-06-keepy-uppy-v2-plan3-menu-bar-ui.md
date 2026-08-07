# Keepy Uppy v2 — Plan 3 of 3: Menu-Bar UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md`

**Goal:** Rewire the existing v1 menu-bar UI to be a client of the daemon over XPC — per spec §11, "genuinely additive": the headless product (plans 1-2) is already complete and usable without this. This plan is what most users will actually open, per spec §1's "headless-first... for most users, menu bar will be main [interface] though."

**Scope:** Plan 3 of 3, covering spec §9's UI paragraph in full: session list with remaining time/condition/origin, start-session submenu, per-session stop, Settings (General/Safety/Triggers tabs), Quit.

**Architecture:** `Sources/` (the existing v1 app target) stops talking to `pmset`/`osascript` entirely and becomes an XPC client of the daemon, structurally the same client role the CLI and agent already have (plan 2) — connects to `helperMachServiceName`, pins `SigningRequirement.helperRequirement`. **Corrected by the final whole-branch review:** this originally said `SigningRequirement.requirement`. `setCodeSigningRequirement` validates the **peer** (the daemon), never the caller's own identity, so a client must pin a requirement describing the *daemon*. `SigningRequirement.requirement` is the daemon's *inbound* requirement for its clients and deliberately omits the daemon's own identifier, so pinning it app-side invalidates the connection on the first real message and the menu bar shows "Not connected" forever in any signed build. `Sources/PowerService.swift` (the osascript/pmset shell-out layer) is deleted outright: v2's daemon is the only process on the machine allowed to touch `pmset`/`IOPMSetSystemPowerSetting`, and the UI must not have its own back door around that boundary.

**Tech Stack:** SwiftUI (`MenuBarExtra`, `Settings` scene), `NSXPCConnection` (same pattern as plan 2's agent/CLI clients), `SMAppService` (both `.mainApp` for the UI's own login item — already wired in `LoginItemService.swift` — and `.daemon`/`.agent` for onboarding, paralleling the CLI's `setup` command from plan 2 Task 10), `UserDefaults(suiteName:)` (reads/writes the same shared suite as plan 2's `TriggerStore`, plus a new `SafetyConfigStore`).

## Global Constraints

- **Read the current `Sources/` before starting Task 1** — it is the real v1 UI this plan rewires, not a description of it. As of this plan being written: `KeepyUppyApp.swift` (scene), `AppDelegate.swift` (owns `PowerMonitor`, calls `restoreSleepOnQuit()` on terminate), `MenuContent.swift` (single toggle + login-item toggle + quit), `PowerService.swift` (osascript/pmset shell-out — **delete this file in Task 3**, nothing in v2 may call `pmset`/`osascript` from the UI), `PowerMonitor.swift` (30s-polling `ObservableObject`, low-battery auto-off via direct `PowerService` calls — **replaced**, the daemon's own `SafetyEngine` already does low-battery auto-off for every session, so the UI does not need its own copy of that logic at all), `LoginItemService.swift` (thin `SMAppService.mainApp` wrapper — this one stays, unchanged; it is the UI's own login item, a different thing from the daemon/agent registration this plan's Task 4 adds).
- **`clientBound` is the UI's default persistence, deliberately different from the CLI's `detached` default (plan 2).** A session started by clicking the menu is, by user intent, tied to "while the menu-bar app is running" — the same behavior v1's toggle always had (`restoreSleepOnQuit`). This is not new logic to write: `SessionTable.removeAll(ownedBy:)` (plan 1) already ends a caller's `clientBound` sessions the instant its XPC connection tears down, so quitting the app is sufient by itself — there is no `restoreSleepOnQuit`-equivalent method to write in this plan; do not reintroduce one.
- **The Settings window needs `NSApp.activate(ignoringOtherApps: true)` before it opens** (spec §9): an `LSUIElement` app (no Dock icon, confirmed already set in `Resources/Info.plist`) does not automatically bring its own windows to the front the way a normal app does.
- **Safety config is not currently user-configurable at all** — `Helper/DaemonRuntime.swift` hardcodes `SafetyEngine(config: .default)` at daemon startup and never reads it from anywhere else. A Safety settings tab that writes to `UserDefaults` and nothing reads would be a UI that changes nothing. Task 6 makes `SafetyConfig` a first-class, daemon-read, live-reloadable setting *before* Task 7 builds a tab over it — do these in that order.
- Trigger rules and safety config both live in the same shared, unsandboxed `UserDefaults(suiteName: "au.com.workwireless.keepy-uppy")` suite plan 2's `TriggerStore` already established — reuse that suite name exactly, do not invent a second one.
- **Deployment target is `13.0`** (confirmed in `project.yml`, all four targets). SwiftUI APIs introduced in macOS 14+ are not available: notably the two-parameter `.onChange(of:) { oldValue, newValue in }` (use the one-parameter `.onChange(of:) { newValue in }` form instead) and `SettingsLink` (Task 3 uses the pre-14 `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)` idiom instead — do not swap it for `SettingsLink`). Check any other SwiftUI API introduced after macOS 13 the same way before using it.
- This plan reuses plan 2's `SessionKind`/`Session`/`TriggerRule`/`TriggerStore` types and the `HelperProtocol`/`SigningRequirement.helperRequirement` XPC pattern verbatim — read `Shared/XPCProtocol.swift`, `Shared/Session.swift`, and `Shared/TriggerRule.swift` (once plan 2 lands) before Task 1, the same discipline plan 2 itself required against plan 1's output.
- Dev/test builds: `-derivedDataPath build CODE_SIGN_IDENTITY=-`. Never run a command that could trigger a macOS password/permission dialog, and never programmatically drive the actual menu-bar UI (clicking `MenuBarExtra` items, opening `Settings`, granting notification/login-item permissions) — those need a human on a signed build. Building and unit tests (for the pure logic pieces) are this plan's automated verification; the interactive flows are the manual checklist in Task 9.
- Commit style, `.xcodeproj` UUID churn expectations, and the review discipline all carry over unchanged from plans 1 and 2.
- **This is the last plan.** Task 9 ends with the spec §10-mandated "dedicated security review of the XPC boundary before merge" — run it against the *whole* branch (all three plans), not just this plan's diff, since plan 1's own review (already done, per its plan) predates plan 2's new XPC clients and plan 3's new Settings-writable surface.

---

### Task 1: App-side daemon connection

**Files:**
- Create: `Sources/DaemonConnection.swift`
- Delete: `Sources/PowerService.swift`

**Interfaces:**
- Consumes: `HelperProtocol`, `helperMachServiceName`, `SigningRequirement.helperRequirement` (the constant that pins the daemon peer — **not** `.requirement`, which is the daemon's inbound requirement for clients), `Session` (all `Shared/`, plans 1-2).
- Produces: `DaemonConnection`, an `ObservableObject` with `@Published private(set) var sessions: [Session]`, `@Published private(set) var keepingAwake: Bool`, polling on a timer (same shape as plan 2's agent `EvidenceLoop` — XPC has no push mechanism here, so polling is the established pattern, not a new one), plus `startSession(_:)`/`stopSession(_:)`/`stopAllSessions(all:)` methods the UI calls directly.

- [ ] **Step 1: Implement**

`Sources/DaemonConnection.swift`:

```swift
import Foundation
import os

let appLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy", category: "app")

@MainActor
final class DaemonConnection: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var keepingAwake = false
    @Published private(set) var isConnected = false

    private var connection: NSXPCConnection?
    private var pollTimer: Timer?

    func start() {
        connect()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func connect() {
        let new = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            // Pins the PEER (the daemon), not the app's own identity.
            new.setCodeSigningRequirement(SigningRequirement.helperRequirement)
        }
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.isConnected = false }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.isConnected = false }
        }
        new.resume()
        connection = new
    }

    private func proxy() -> HelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            appLogger.error("XPC error: \(error.localizedDescription)")
            Task { @MainActor in self?.isConnected = false }
        } as? HelperProtocol
    }

    func refresh() async {
        guard let proxy = proxy() else { return }
        isConnected = true

        let state: Bool = await withCheckedContinuation { continuation in
            proxy.currentState { continuation.resume(returning: $0) }
        }
        keepingAwake = state

        let list: [Session] = await withCheckedContinuation { continuation in
            proxy.listSessions { data, _ in
                guard let data, let decoded = try? JSONDecoder().decode([Session].self, from: data) else {
                    return continuation.resume(returning: [])
                }
                continuation.resume(returning: decoded)
            }
        }
        sessions = list
    }

    @discardableResult
    func startSession(kind: SessionKind, persistence: SessionPersistence = .clientBound,
                      origin: SessionOrigin = .manual) async -> Bool {
        guard let proxy = proxy() else { return false }
        let session = Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "app"),
                              persistence: persistence, origin: origin, startedAt: Date())
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let ok: Bool = await withCheckedContinuation { continuation in
            proxy.startSession(data) { sessionID, error in
                if let error { appLogger.error("startSession failed: \(error)") }
                continuation.resume(returning: sessionID != nil)
            }
        }
        await refresh()
        return ok
    }

    func stopSession(_ id: UUID) async {
        guard let proxy = proxy() else { return }
        _ = await withCheckedContinuation { continuation in
            proxy.stopSession(id.uuidString) { ok, _ in continuation.resume(returning: ok) }
        }
        await refresh()
    }

    func stopAllSessions(all: Bool) async {
        guard let proxy = proxy() else { return }
        _ = await withCheckedContinuation { continuation in
            proxy.stopAllSessions(all: all) { ok, _ in continuation.resume(returning: ok) }
        }
        await refresh()
    }
}
```

Delete `Sources/PowerService.swift` in this same commit — nothing in `Sources/` may call `pmset`/`osascript` after this task, and leaving the file around unused invites it to be "helpfully" wired back in by a future edit.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: build error — `PowerMonitor.swift`/`MenuContent.swift` still reference the now-deleted `PowerService`. That is expected and resolved in Task 3; do not fix it here by resurrecting `PowerService.swift`.

- [ ] **Step 3: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/DaemonConnection.swift
git rm Sources/PowerService.swift
git commit -m "Add the app's XPC connection to the daemon; remove the old pmset/osascript layer"
```

(This commit is expected to leave the build red until Task 3 — that is fine; plan 1/2's own precedent (plan 1 Task 6) already established that an implementer correctly reporting BLOCKED-by-design here, rather than papering over it, is the right call. Proceed directly to Task 2.)

---

### Task 2: Pure helpers — default session kind and display formatting

**Files:**
- Create: `Sources/SessionDisplay.swift`
- Test: `Tests/SessionDisplayTests.swift`

**Interfaces:**
- Produces: `enum DefaultSessionKind` (the small, fixed menu choice set — Indefinite / 1 Hour / 4 Hours / 8 Hours — stored as the Settings General tab's preference) and pure formatting functions `func remainingTimeText(for session: Session, now: Date) -> String` and `func originText(for session: Session) -> String`, both fully unit-tested since they are the one piece of this plan's UI logic with real branching to get wrong.

- [ ] **Step 1: Write the failing tests**

`Tests/SessionDisplayTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class SessionDisplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ kind: SessionKind, origin: SessionOrigin = .manual) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"),
               persistence: .clientBound, origin: origin, startedAt: t0)
    }

    func testIndefiniteHasNoRemainingTimeText() {
        XCTAssertEqual(remainingTimeText(for: session(.indefinite), now: t0), "Indefinite")
    }

    func testDurationShowsRoundedMinutesRemaining() {
        let s = session(.duration(until: t0.addingTimeInterval(90 * 60)))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "1h 30m left")
    }

    func testDurationUnderAnHourShowsMinutesOnly() {
        let s = session(.duration(until: t0.addingTimeInterval(45 * 60)))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "45m left")
    }

    func testWhileAppRunningShowsTheAppCondition() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(remainingTimeText(for: s, now: t0), "While Xcode is running")
    }

    func testWhileExternalDisplayShowsItsCondition() {
        XCTAssertEqual(remainingTimeText(for: session(.whileExternalDisplay), now: t0), "While an external display is connected")
    }

    func testOriginTextDistinguishesManualAndTrigger() {
        XCTAssertEqual(originText(for: session(.indefinite, origin: .manual)), "Started manually")
        XCTAssertEqual(originText(for: session(.indefinite, origin: .trigger)), "Started automatically")
    }

    func testDefaultSessionKindMapsToRealSessionKind() {
        XCTAssertEqual(DefaultSessionKind.indefinite.sessionKind(now: t0), .indefinite)
        XCTAssertEqual(DefaultSessionKind.oneHour.sessionKind(now: t0), .duration(until: t0.addingTimeInterval(3600)))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: compile failure — none of these exist yet. (The app target itself is still red from Task 1; that's expected — the test target only needs `Sources/SessionDisplay.swift` and `Shared/` to compile, and `xcodegen`'s test target already depends on the app target for its host, so this may still fail to build for the unrelated `PowerService` reason. If so, that's fine — proceed to Task 3 immediately after Step 3 below, then re-run the full suite once both are done.)

- [ ] **Step 3: Implement**

`Sources/SessionDisplay.swift`:

```swift
import Foundation

/// The small, fixed set of quick-start choices shown in the menu and
/// configurable as a default in Settings' General tab. Deliberately not
/// arbitrary custom durations or `--while-app` (the CLI already covers
/// those, per spec §9's CLI/UI split) — the menu is meant to cover the
/// common case with one or two clicks, not replicate every CLI flag.
enum DefaultSessionKind: String, CaseIterable, Codable, Identifiable {
    case indefinite, oneHour, fourHours, eightHours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .indefinite: return "Indefinitely"
        case .oneHour: return "For 1 Hour"
        case .fourHours: return "For 4 Hours"
        case .eightHours: return "For 8 Hours"
        }
    }

    func sessionKind(now: Date) -> SessionKind {
        switch self {
        case .indefinite: return .indefinite
        case .oneHour: return .duration(until: now.addingTimeInterval(3600))
        case .fourHours: return .duration(until: now.addingTimeInterval(4 * 3600))
        case .eightHours: return .duration(until: now.addingTimeInterval(8 * 3600))
        }
    }
}

func remainingTimeText(for session: Session, now: Date) -> String {
    switch session.kind {
    case .indefinite:
        return "Indefinite"
    case .duration(let until), .untilTime(let until), .lease(let until):
        let seconds = max(0, until.timeIntervalSince(now))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        return "\(minutes)m left"
    case .whileAppRunning(let bundleID):
        let name = appDisplayName(bundleID: bundleID)
        return "While \(name) is running"
    case .whileExternalDisplay:
        return "While an external display is connected"
    case .whileOnACPower:
        return "While on AC power"
    case .whileCPUBusy:
        return "While the CPU is busy"
    }
}

func originText(for session: Session) -> String {
    session.origin == .trigger ? "Started automatically" : "Started manually"
}

/// Best-effort friendly name for a bundle id, falling back to the id
/// itself when the app isn't installed/discoverable — this is display
/// text only, never used for matching logic.
func appDisplayName(bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let bundle = Bundle(url: url),
          let name = bundle.infoDictionary?["CFBundleName"] as? String
    else { return bundleID }
    return name
}
```

Add `import AppKit` (for `NSWorkspace`) at the top of the same file.

- [ ] **Step 4: Run tests**

Run: `xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **` once Task 3 has also landed (see Step 2's note) — do not spend time forcing this task's tests green in isolation if the only blocker is Task 1's deliberately-red build; verify both together after Task 3.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/SessionDisplay.swift Tests/SessionDisplayTests.swift
git commit -m "Add pure session display formatting and the default-kind menu choice"
```

---

### Task 3: Menu content rewrite

**Files:**
- Modify: `Sources/KeepyUppyApp.swift`, `Sources/AppDelegate.swift`, `Sources/MenuContent.swift`
- Delete: `Sources/PowerMonitor.swift`

**Interfaces:**
- Consumes: `DaemonConnection` (Task 1), `SessionDisplay` helpers (Task 2).
- Produces: the real menu — session list, start-session submenu, per-session stop, Settings, Quit — replacing v1's single toggle. This is what takes the build from red (Task 1) back to green.

- [ ] **Step 1: Rewrite `AppDelegate.swift`**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemon = DaemonConnection()

    func applicationDidFinishLaunching(_ notification: Notification) {
        daemon.start()
    }
}
```

No `applicationWillTerminate`/`restoreSleepOnQuit` — see Global Constraints: `clientBound` sessions already end themselves when this process's XPC connection tears down on quit, which happens automatically as part of normal process exit. Writing an explicit terminate-time cleanup here would be redundant with, not a replacement for, that daemon-side guarantee — the daemon must stay correct even if the UI is force-quit or crashes, so the safety net cannot depend on this method running at all.

- [ ] **Step 2: Rewrite `KeepyUppyApp.swift`**

```swift
import SwiftUI

@main
struct KeepyUppyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(daemon: appDelegate.daemon)
        } label: {
            MenuBarIcon(daemon: appDelegate.daemon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(daemon: appDelegate.daemon)
        }
    }
}
```

(`SettingsView` is created in Task 4; this file references it now so Task 3's own build only goes green once Task 4 lands too — same "expected red until the next task" pattern as Task 1, and for the same reason: these tasks are small and tightly coupled, not because sequencing broke down.)

- [ ] **Step 3: Rewrite `MenuContent.swift`**

```swift
import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        Image(systemName: daemon.keepingAwake ? "balloon.fill" : "balloon")
    }
}

struct MenuContent: View {
    @ObservedObject var daemon: DaemonConnection
    @AppStorage("defaultSessionKind", store: UserDefaults(suiteName: "au.com.workwireless.keepy-uppy"))
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue

    var body: some View {
        if !daemon.isConnected {
            Text("Not connected to Keepy Uppy daemon")
        } else if daemon.sessions.isEmpty {
            Text("Not keeping awake")
        } else {
            ForEach(daemon.sessions) { session in
                Button {
                    Task { await daemon.stopSession(session.id) }
                } label: {
                    Text("\(remainingTimeText(for: session, now: Date())) — \(originText(for: session)) — Stop")
                }
            }
        }

        Divider()

        Menu("Start…") {
            ForEach(DefaultSessionKind.allCases) { kind in
                Button(kind.label) {
                    Task { await daemon.startSession(kind: kind.sessionKind(now: Date())) }
                }
            }
        }

        if !daemon.sessions.isEmpty {
            Button("Stop All") {
                Task { await daemon.stopAllSessions(all: false) }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Quit Keepy Uppy") {
            NSApplication.shared.terminate(nil)
        }
    }
}
```

Note: `SettingsLink`, the modern one-line way to open the `Settings` scene, requires macOS 14+ — this project's deployment target is `13.0` (`project.yml`), so it is not available and must not be used here. The `Button` above calling `showSettingsWindow:` is the pre-14 idiom for opening a SwiftUI `Settings` scene programmatically, and pairing it with an explicit `NSApp.activate(ignoringOtherApps:)` is exactly the workaround spec §9 calls out by name ("An `LSUIElement` app must call `NSApp.activate` when opening Settings, or the window appears behind everything") — belt-and-braces with `SettingsView`'s own `.onAppear` activate call in Task 4, since either call site alone is enough but neither is guaranteed to run before the other.

- [ ] **Step 4: Delete the old monitor**

`Sources/PowerMonitor.swift` is now fully superseded — its polling, its direct `PowerService` calls, and its own low-battery auto-off logic (redundant with the daemon's `SafetyEngine`, which already applies to every session regardless of which client started it) are all gone. Delete the file.

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: still red until Task 4 supplies `SettingsView` — confirm the *only* remaining error is the missing `SettingsView` symbol, not anything else left over from `PowerMonitor`/`PowerService`. If anything else fails, fix it now rather than carrying an unrelated break into Task 4.

- [ ] **Step 6: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/KeepyUppyApp.swift Sources/AppDelegate.swift Sources/MenuContent.swift
git rm Sources/PowerMonitor.swift
git commit -m "Rewrite the menu as a session list over the daemon connection"
```

---

### Task 4: Onboarding + Settings — General tab

**Files:**
- Create: `Sources/OnboardingService.swift`, `Sources/SettingsView.swift`

**Interfaces:**
- Consumes: `SMAppService` (`.daemon`/`.agent`, paralleling plan 2 Task 10's CLI `setup`; `.mainApp` via the existing `LoginItemService.swift`).
- Produces: `SettingsView` (tab container, satisfying Task 3's reference to it), its General tab, and the onboarding status/enable flow.

Most users' only path to getting the daemon and agent registered is through this UI (spec §1: "for most users, menu bar will be main [interface]") — they will never run `keepy-uppy setup`. This task is what makes the menu-bar app self-sufficient rather than secretly dependent on the CLI having been run first.

- [ ] **Step 1: Implement the onboarding service**

`Sources/OnboardingService.swift`:

```swift
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
```

- [ ] **Step 2: Implement the Settings container and General tab**

`Sources/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            // SafetySettingsTab and TriggersSettingsTab are added in Tasks 7-8.
        }
        .frame(width: 420, height: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct GeneralSettingsTab: View {
    @StateObject private var onboarding = OnboardingService()
    @State private var launchAtLoginEnabled = LoginItemService.status() == .enabled
    @AppStorage("defaultSessionKind", store: UserDefaults(suiteName: "au.com.workwireless.keepy-uppy"))
    private var defaultKindRaw: String = DefaultSessionKind.indefinite.rawValue

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { enabled in
                    try? enabled ? LoginItemService.register() : LoginItemService.unregister()
                }

            Picker("Default Session", selection: $defaultKindRaw) {
                ForEach(DefaultSessionKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }

            Divider()

            LabeledContent("Background Service") {
                Text(statusText(onboarding.daemonStatus, onboarding.agentStatus))
            }
            if onboarding.daemonStatus != .enabled || onboarding.agentStatus != .enabled {
                Button("Enable Keepy Uppy") {
                    onboarding.enable()
                }
            }
        }
        .padding()
        .onAppear { onboarding.refresh() }
    }

    private func statusText(_ daemon: ServiceStatus, _ agent: ServiceStatus) -> String {
        if daemon == .enabled && agent == .enabled { return "Running" }
        if daemon == .requiresApproval || agent == .requiresApproval { return "Needs approval in System Settings" }
        return "Not enabled"
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **` — this is the task that takes the build green again after Tasks 1 and 3's deliberate interim breaks.

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, including Task 2's tests now that the app target compiles.

Do not run `onboarding.enable()` for real — it registers a real LaunchDaemon/LaunchAgent and needs a signed build plus human approval. Deferred to Task 9's manual checklist.

- [ ] **Step 4: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/OnboardingService.swift Sources/SettingsView.swift
git commit -m "Add onboarding and the Settings General tab; build is green again"
```

---

### Task 5: Safety config becomes daemon-configurable

**Files:**
- Create: `Shared/SafetyConfigStore.swift`
- Modify: `Helper/DaemonRuntime.swift`
- Test: `Tests/SafetyConfigStoreTests.swift`

**Interfaces:**
- Produces: `SafetyConfigStore` (Codable read/write over the shared `UserDefaults` suite, same shape as plan 2's `TriggerStore`), and daemon-side live reload — the actual prerequisite for Task 6's Safety tab to mean anything.

`SafetyConfig` (`Shared/SafetyEngine.swift`, plan 1) already exists with a `.default` and every field a Safety tab needs (`thermalSensitivity`, `batteryCutoff`, `maxSessionDuration`, `lidClosedStricter`, `gracePeriod`, `cooldown`, `batteryHysteresis`). What is missing is anywhere to persist a *non-default* value and anything on the daemon side that ever reads it — `DaemonRuntime` hardcodes `SafetyEngine(config: .default)` once, at `init()`, forever.

- [ ] **Step 1: Write the failing tests**

`Tests/SafetyConfigStoreTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class SafetyConfigStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: "au.com.workwireless.keepy-uppy")?.removePersistentDomain(forName: "au.com.workwireless.keepy-uppy")
    }

    func testLoadWithNothingSavedReturnsDefault() {
        XCTAssertEqual(SafetyConfigStore.load().thermalSensitivity, SafetyConfig.default.thermalSensitivity)
    }

    func testSaveThenLoadRoundTrips() {
        var config = SafetyConfig.default
        config.thermalSensitivity = .cautious
        config.batteryCutoff = 20
        SafetyConfigStore.save(config)

        let loaded = SafetyConfigStore.load()
        XCTAssertEqual(loaded.thermalSensitivity, .cautious)
        XCTAssertEqual(loaded.batteryCutoff, 20)
    }
}
```

Note `SafetyConfig` needs `Codable` conformance for this to compile — check `Shared/SafetyEngine.swift` first; if it is not already `Codable` (it was not as of plan 1), add the conformance there as part of this step. `ThermalSensitivity` is already `Codable`; the rest of `SafetyConfig`'s fields are all `Codable`-native types, so this should be a plain `: Codable` addition to the struct declaration, no custom `Codable` implementation needed.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — `SafetyConfigStore` does not exist.

- [ ] **Step 3: Implement the store**

`Shared/SafetyConfigStore.swift`:

```swift
import Foundation

/// Shared with the Settings Safety tab (plan 3). Same suite as
/// `TriggerStore` (plan 2) — `au.com.workwireless.keepy-uppy` — deliberately;
/// this is not a second, separate suite.
enum SafetyConfigStore {
    private static let suiteName = "au.com.workwireless.keepy-uppy"
    private static let key = "safetyConfig"

    static func load() -> SafetyConfig {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(SafetyConfig.self, from: data)
        else { return .default }
        return config
    }

    static func save(_ config: SafetyConfig) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(config)
        else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Wire live reload into the daemon**

In `Shared/SafetyEngine.swift`, change `SafetyEngine.config` from `let` to `var` — this is the only change needed to allow reconfiguration, since `SafetyEngine`'s other state (`pendingWarning`, `suppressionReason`, `recoveredSince`) is unrelated to which config values are in effect and must survive a config change untouched (e.g. changing the thermal sensitivity mid-cooldown must not reset an unrelated battery-triggered suppression).

In `Helper/DaemonRuntime.swift`, initialize from the store instead of the hardcoded default:

```swift
private var safety = SafetyEngine(config: SafetyConfigStore.load())
```

and in `tickLocked()` (which already runs every 5s), re-read and apply any change before evaluating:

```swift
    private func tickLocked() {
        guard bundleStillExists() else { ... }  // unchanged

        let now = Date()
        _ = sessions.apply(.tick, now: now)

        let freshConfig = SafetyConfigStore.load()
        if freshConfig != safety.config { safety.config = freshConfig }

        // ...rest of the method unchanged
```

This needs `SafetyConfig: Equatable` in addition to `Codable` from Step 1 — add both in the same declaration. Polling `UserDefaults` on the existing 5s tick (rather than `NSUserDefaultsDidChangeNotification`, which does not cross between separate `UserDefaults(suiteName:)` instances in different processes reliably) means a Settings change takes effect within 5 seconds — acceptable for a setting a user tunes rarely, and it reuses a timer that already exists rather than adding a second one.

- [ ] **Step 5: Build and test**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 2.

- [ ] **Step 6: Commit**

```bash
git add -A Shared Helper Tests "Keepy Uppy.xcodeproj"
git commit -m "Make safety config persisted and daemon-reloadable, not hardcoded"
```

---

### Task 6: Settings — Safety tab

**Files:**
- Create: `Sources/SafetySettingsTab.swift`
- Modify: `Sources/SettingsView.swift`

**Interfaces:**
- Consumes: `SafetyConfigStore`, `SafetyConfig`, `ThermalSensitivity` (Task 5, `Shared/`).
- Produces: the Safety tab UI, wired to the store Task 5 made real.

- [ ] **Step 1: Implement**

`Sources/SafetySettingsTab.swift`:

```swift
import SwiftUI

struct SafetySettingsTab: View {
    @State private var config = SafetyConfigStore.load()

    var body: some View {
        Form {
            Picker("Thermal Sensitivity", selection: $config.thermalSensitivity) {
                ForEach(ThermalSensitivity.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }

            Toggle("Stricter Battery Cutoff While Lid Closed", isOn: $config.lidClosedStricter)

            Stepper(value: Binding(
                get: { config.batteryCutoff ?? 0 },
                set: { config.batteryCutoff = $0 }
            ), in: 0...50) {
                Text("Battery Cutoff: \(config.batteryCutoff ?? 0)%")
            }

            Stepper(value: Binding(
                get: { Int((config.maxSessionDuration ?? 0) / 3600) },
                set: { config.maxSessionDuration = TimeInterval($0) * 3600 }
            ), in: 1...24) {
                Text("Max Session Duration: \(Int((config.maxSessionDuration ?? 0) / 3600))h")
            }
        }
        .padding()
        .onChange(of: config) { newValue in
            SafetyConfigStore.save(newValue)
        }
    }
}
```

This needs `SafetyConfig: Equatable`, already added in Task 5. `ThermalSensitivity.off` is a real, valid case (disables the guard entirely) — the picker deliberately includes it rather than hiding it, since a user choosing to disable thermal protection is exactly the kind of explicit, reviewable choice the signing-requirement work earlier in this project treats as a first-class principle: widening a safety boundary should be a visible, deliberate action, not a default.

- [ ] **Step 2: Wire the tab into `SettingsView`**

```swift
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "shield") }
            // TriggersSettingsTab is added in Task 7.
        }
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/SafetySettingsTab.swift Sources/SettingsView.swift
git commit -m "Add the Settings Safety tab"
```

---

### Task 7: Settings — Triggers tab

**Files:**
- Create: `Sources/TriggersSettingsTab.swift`
- Modify: `Sources/SettingsView.swift`

**Interfaces:**
- Consumes: `TriggerRule`, `TriggerCondition`, `TriggerStore` (plan 2, `Shared/`).
- Produces: the Triggers tab — list, add, remove, enable-toggle.

- [ ] **Step 1: Implement**

`Sources/TriggersSettingsTab.swift`:

```swift
import SwiftUI

struct TriggersSettingsTab: View {
    @State private var rules = TriggerStore.load()
    @State private var newConditionKind: NewRuleConditionKind = .appLaunched
    @State private var newBundleID = ""
    @State private var newSessionKind: DefaultSessionKind = .indefinite

    enum NewRuleConditionKind: String, CaseIterable, Identifiable {
        case appLaunched = "App Launched"
        case externalDisplayConnected = "External Display Connected"
        case acPowerConnected = "AC Power Connected"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(rules) { rule in
                    HStack {
                        Toggle("", isOn: binding(for: rule).enabled)
                            .labelsHidden()
                        Text(describe(rule))
                        Spacer()
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                            TriggerStore.save(rules)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Divider()

            HStack {
                Picker("Condition", selection: $newConditionKind) {
                    ForEach(NewRuleConditionKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if newConditionKind == .appLaunched {
                    TextField("Bundle ID (e.g. com.apple.dt.Xcode)", text: $newBundleID)
                }
                Picker("Starts", selection: $newSessionKind) {
                    ForEach(DefaultSessionKind.allCases) { Text($0.label).tag($0) }
                }
                Button("Add") {
                    addRule()
                }
                .disabled(newConditionKind == .appLaunched && newBundleID.isEmpty)
            }
        }
        .padding()
    }

    private func binding(for rule: TriggerRule) -> Binding<TriggerRule> {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return .constant(rule)
        }
        return Binding(
            get: { rules[index] },
            set: { rules[index] = $0; TriggerStore.save(rules) }
        )
    }

    private func addRule() {
        let condition: TriggerCondition
        switch newConditionKind {
        case .appLaunched: condition = .appLaunched(bundleID: newBundleID)
        case .externalDisplayConnected: condition = .externalDisplayConnected
        case .acPowerConnected: condition = .acPowerConnected
        }
        let rule = TriggerRule(id: UUID(), condition: condition,
                               sessionKind: newSessionKind.sessionKind(now: Date()), enabled: true)
        rules.append(rule)
        TriggerStore.save(rules)
        newBundleID = ""
    }

    private func describe(_ rule: TriggerRule) -> String {
        let conditionText: String
        switch rule.condition {
        case .appLaunched(let bundleID): conditionText = "When \(appDisplayName(bundleID: bundleID)) launches"
        case .externalDisplayConnected: conditionText = "When an external display connects"
        case .acPowerConnected: conditionText = "When AC power connects"
        }
        return "\(conditionText) — keep awake \(remainingTimeText(for: previewSession(rule), now: Date()).lowercased())"
    }

    private func previewSession(_ rule: TriggerRule) -> Session {
        Session(id: UUID(), kind: rule.sessionKind, owner: ClientID(rawValue: "preview"),
               persistence: .detached, origin: .trigger, startedAt: Date())
    }
}
```

Note `Binding<TriggerRule>.enabled` in `binding(for:)`'s use (`Toggle("", isOn: binding(for: rule).enabled)`) relies on `TriggerRule` exposing `enabled` as a settable `var` — confirm this against `Shared/TriggerRule.swift` (plan 2); it already is (`var enabled: Bool`), so no change needed there.

- [ ] **Step 2: Wire the tab into `SettingsView`**

```swift
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "shield") }
            TriggersSettingsTab()
                .tabItem { Label("Triggers", systemImage: "bolt") }
        }
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, unchanged count (this task is UI-only, no new pure logic — plan 2's `TriggerRule`/`TriggerStore`/`triggersToFire` are already fully tested).

- [ ] **Step 4: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Sources/TriggersSettingsTab.swift Sources/SettingsView.swift
git commit -m "Add the Settings Triggers tab"
```

---

### Task 8: Documentation and manual verification checklist

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: accurate documentation of the finished v2 architecture (daemon + agent + CLI + UI, all four executables) and the complete manual checklist accumulated across all three plans.

- [ ] **Step 1: Rewrite the README's top-level description**

Confirm it accurately states: four executables (`Keepy Uppy.app`, `KeepyUppyHelper`, `KeepyUppyAgent`, `keepy-uppy`), headless-usable via CLI alone (`keepy-uppy setup` then `on`/`off`/`status`/`sessions`), or via the menu-bar app which can self-onboard (Settings → General → "Enable Keepy Uppy"). Remove any remaining v1-era description of `pmset`/`osascript` toggling — that mechanism no longer exists anywhere in the codebase as of Task 1.

- [ ] **Step 2: Consolidate the full manual verification checklist**

Merge plan 1's and plan 2's existing checklists with the following, so the README carries one authoritative list rather than three scattered ones:

```markdown
- [ ] Fresh install: open the app, Settings → General shows "Not enabled"; clicking "Enable Keepy Uppy" registers both background items and, if approval is needed, opens System Settings to the right pane
- [ ] After approval, Settings → General shows "Running" without needing to reopen the app
- [ ] Menu "Start… → Indefinitely" keeps the Mac awake with the lid closed; quitting the app ends that session (clientBound) and sleep resumes
- [ ] A session started via `keepy-uppy on --for 2h` (detached) is NOT ended by quitting the menu-bar app, and appears in the menu's session list with the right remaining time
- [ ] Settings → Safety: lowering the battery cutoff and confirming (via `keepy-uppy status`) the daemon picks it up within ~5s without restarting anything
- [ ] Settings → Triggers: adding an "App Launched" rule for a real installed app, launching it, confirming a session starts automatically and is tagged "Started automatically" in the menu; quitting that app ends the session within ~5s
- [ ] A trigger does not fire again while its session is still active (leave the triggering app running, confirm no duplicate session appears)
- [ ] Triggering a real safety stop (or lowering the thermal sensitivity to `cautious` under load) suppresses a trigger from firing again until the configured cooldown elapses, while a manual "Start…" click still works immediately
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the complete v2 architecture and consolidate the manual checklist"
```

---

### Task 9: Whole-branch security review

Not a code task — this is the spec §10-mandated gate before merge: **"A dedicated security review of the XPC boundary before merge, separate from per-task gates: the requirement string on both ends, the DEBUG asymmetry, role enforcement for observation messages, and the privilege boundary generally."**

Plan 1 already ran a version of this review against the daemon core alone. Re-run it now against the full branch, since plan 2 added two new XPC client roles (agent, CLI) and plan 3 added a fourth (the UI), and both plans added new writable-by-any-local-process surface (the shared `UserDefaults` suite backing `TriggerStore`/`SafetyConfigStore`) that did not exist when plan 1's review happened. In particular, confirm:

- Every new XPC client (agent in plan 2, CLI in plan 2, UI in this plan) pins the correct requirement before first use — none of them skip `setCodeSigningRequirement`.
- The trigger/safety-config `UserDefaults` suite being writable by any process sharing the bundle-id prefix (no entitlement boundary, since the app is unsandboxed) is an accepted, documented tradeoff, not an overlooked hole — worst case, a malicious local process can write bogus trigger rules or loosen safety settings for itself, but it still cannot bypass the daemon's own code-signing-pinned XPC boundary to control sleep state directly, and every value it could set (a lease duration, a thermal sensitivity) is bounded by the same validation the pure engines already enforce server-side regardless of where the value came from.
- The detached-session fairness fix (plan 2 Task 7) and the trigger-suppression enforcement (plan 2 Task 6) both still hold under the full, integrated system now that real callers exist for both.

Once this review's findings (if any) are resolved, `keepy-uppy-v2` is ready to merge to `main`.
