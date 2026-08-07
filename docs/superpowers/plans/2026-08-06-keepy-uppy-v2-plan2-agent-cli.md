# Keepy Uppy v2 — Plan 2 of 3: Agent + CLI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md`

**Goal:** Build the per-user agent (the sensor for user-session conditions and triggers) and the real CLI. **At the end of this plan the headless product is complete and usable** — every session kind, every safety guard, and remote control via `keepy-uppy` all work with no UI installed.

**Scope:** Plan 2 of 3, covering spec §2 (agent/CLI components), §8 (triggers), §9 (interfaces). Plan 1 (daemon core) is complete and merged — this plan is client-side only; the daemon's XPC surface (`Shared/XPCProtocol.swift`) already has everything these clients need, including `agentRequirement`/`helperRequirement` constants that have been sitting unused since Task 5/10 specifically for this moment.

**Architecture:** Two new executables, both thin XPC clients of the existing daemon — neither holds authoritative state. The **agent** is a bare `tool` target (no UI, no `NSApplication`), structurally identical in shape to the daemon: a background process with a run loop, observing the login session and reporting to the daemon over the dedicated agent Mach service. The **CLI** is a one-shot command that connects, issues one request, prints a result, and exits.

**Tech Stack:** Swift, `NSXPCConnection`, `NSWorkspace` (running-application observation), `CGGetActiveDisplayList` (external-display detection via polling, verified against real headers), `host_statistics64`/`HOST_CPU_LOAD_INFO` (CPU load, verified by compiling and running a real probe on this machine), `UserDefaults(suiteName:)` (trigger rule storage shared with the future UI), `SMAppService`.

## Global Constraints

- Every API this plan's observers depend on was verified on this machine before writing, not assumed:
  - `host_statistics64` + `HOST_CPU_LOAD_INFO` (`= 3`) + `struct host_cpu_load_info { cpu_ticks[CPU_STATE_MAX] }` + `CPU_STATE_USER/SYSTEM/IDLE/NICE` — confirmed in `mach_host.h`/`host_info.h`/`machine.h`, **and** the exact Swift calling convention (`withUnsafeMutablePointer` + `withMemoryRebound`) was compiled and run, producing a real CPU-busy reading.
  - `NSWorkspace` notifications do not require a running `NSApplication` — they arrive via the system's distributed notification mechanism, which only needs an active run loop (the agent has one, same as the daemon).
  - Display observation does not need a registered reconfiguration callback: the evidence loop (Task 4) already polls every 5s for the CPU and app-running checks, so a plain `CGGetActiveDisplayList` count on the same tick is simpler than standing up `CGDisplayRegisterReconfigurationCallback` and gets the same answer — do not add the callback, it would be dead weight.
- **Read the current `Shared/`/`Helper/` source before starting any task, not this plan's prose summaries of it.** This plan was written after auditing the real files (not from memory of plan 1), but plan 1's branch kept moving through a dedicated security-hardening pass after its own summary was written — `Session` already carries an `ownerUID` field (default `0`), `SessionAdmission.evaluate` already has a full `origin == .trigger && triggersSuppressed` rejection path (tested by `testSafetySuppressionRejectsTriggersButAllowsManualStarts` in `Tests/SessionEngineTests.swift`), and the per-owner/global session caps (20/200) already exist. Tasks 5-7 below are written against that real state; if it has moved further since, re-verify before assuming this plan's task bodies are still accurate.
- Identifiers: agent bundle id `au.com.workwireless.keepy-uppy.agent` (already used throughout `Shared/`); agent executable name `KeepyUppyAgent`; agent Mach service `agentMachServiceName` (already defined in `Shared/XPCProtocol.swift`).
- **`SKIP_INSTALL: YES` on the agent target from the start.** Plan 1's Task 11 shipped without this on the two `tool` targets and it silently broke every subsequent archive export until root-caused against a real signed build — see plan 1's Task 1 for the full mechanism. Do not repeat that mistake here.
- Agent and CLI both pin a code-signing requirement before using their connection, per spec §4:
  - Agent connects to `agentMachServiceName`, pins `SigningRequirement.helperRequirement` (pins the daemon's own identifier — this is that constant's first real caller).
  - CLI connects to `helperMachServiceName`, pins `SigningRequirement.requirement` (the general one, already admits the CLI's own identifier).
  - Both respect `SigningRequirement.isEnforced`/`InsecureDebugGate` exactly as the daemon does — copy the pattern, do not invent a new one.
- **Fairness fix, closing the spec §5 known limitation — read the spec section itself, not a paraphrase.** The documented gap is specifically that orphaned `detached` sessions (legitimate ones — that persistence exists so `keepy-uppy on --for 2h` survives its own process exiting) can accumulate from disconnected owners and exhaust the shared 200-session global cap, starving every other client including the menu-bar app. A per-connection rate limiter does not fix this (an attacker can just open connections slowly, one at a time); Task 7 implements the spec's own suggested fix instead — reserving global-cap headroom by sub-capping detached sessions specifically, since only detached sessions can ever become orphaned garbage (`clientBound` ones die with their owner by construction).
- **Trigger-suppression enforcement already has a real gate — it just has no caller yet.** `SessionAdmission.evaluate` already rejects `.trigger`-origin starts while `SafetyEngine.triggersSuppressed` is true, and this is already unit-tested. Nothing has ever exercised that path end-to-end simply because nothing could originate a trigger-started session before this plan's agent exists. Task 6 is agent-side wiring only — do not re-implement the daemon-side check, it is already there.
- Trigger rules are stored via `UserDefaults(suiteName: "au.com.workwireless.keepy-uppy")` — the app is not sandboxed, so this suite is readable/writable by every process sharing the bundle-id prefix without entitlements. Plan 3's Settings UI writes to the same suite; this plan only needs to read it (and ships a safe empty default, since triggers are off by default per spec §8).
- Dev/test builds: `-derivedDataPath build CODE_SIGN_IDENTITY=-`. Never run a command that could trigger a macOS password/permission dialog. Do not launch/load/register the daemon or agent — building and unit tests are the verification; real registration and the interactive flows are deferred to human verification on a signed build (the credentials now exist — see the session record — but every task in this plan is still written so an implementer without them can still complete and verify their diff via build + tests).
- Commit style, `.xcodeproj` UUID churn expectations, and the review discipline all carry over unchanged from plan 1.

---

### Task 1: Agent target scaffold

**Files:**
- Modify: `project.yml`
- Create: `Agent/main.swift`

**Interfaces:**
- Produces: a fourth executable, `KeepyUppyAgent`, embedded in the app bundle at `Contents/MacOS/KeepyUppyAgent`, alongside the already-shipped `Launchd/au.com.workwireless.keepy-uppy.agent.plist` from plan 1 Task 11.

- [ ] **Step 1: Add the target to `project.yml`**

```yaml
  KeepyUppyAgent:
    type: tool
    platform: macOS
    deploymentTarget: "13.0"
    sources: [Agent, Shared]
    dependencies:
      - sdk: AppKit.framework
      - sdk: CoreGraphics.framework
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: au.com.workwireless.keepy-uppy.agent
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        SWIFT_VERSION: "5.0"
        GENERATE_INFOPLIST_FILE: YES
        CREATE_INFOPLIST_SECTION_IN_BINARY: YES
        # See project.yml's KeepyUppyHelper/keepy-uppy for why this is
        # mandatory, not optional: without it this target additionally
        # installs standalone at /usr/local/bin during archiving, which
        # breaks `xcodebuild -exportArchive` for the whole app in a way
        # that produces no useful error message.
        SKIP_INSTALL: YES
```

On the `Keepy Uppy` app target, add to the existing `dependencies:` list:

```yaml
      - target: KeepyUppyAgent
        embed: true
        codeSign: true
        copy:
          destination: executables
```

- [ ] **Step 2: Create the placeholder executable**

`Agent/main.swift`:

```swift
import Foundation

// Replaced in Task 2 with the real agent.
RunLoop.main.run()
```

- [ ] **Step 3: Regenerate, build, and verify the bundle layout**

Run: `xcodegen generate`

Run: `xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

Run: `find "build/Build/Products/Debug/Keepy Uppy.app" -name "KeepyUppyAgent" -o -name "*.agent.plist"`
Expected two lines: `Contents/MacOS/KeepyUppyAgent` and `Contents/Library/LaunchAgents/au.com.workwireless.keepy-uppy.agent.plist`. If either is missing, stop and report — do not proceed to Task 2 on an unconfirmed bundle layout (this is exactly the class of silent failure that broke plan 1's export).

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: unaffected, same count as before this task.

- [ ] **Step 4: Commit**

```bash
git add project.yml "Keepy Uppy.xcodeproj" Agent/main.swift
git commit -m "Add agent target with SKIP_INSTALL from the start"
```

---

### Task 2: Agent XPC connection and registration

**Files:**
- Create: `Agent/DaemonConnection.swift`
- Modify: `Agent/main.swift`

**Interfaces:**
- Consumes: `HelperProtocol`, `agentMachServiceName`, `SigningRequirement.helperRequirement` (all from `Shared/`, plan 1).
- Produces: `AgentDaemonConnection` with `func connect()`, `func requestKeepAwake` — actually the full session-oriented surface: `func startSession(_:) async -> Result<String, String>`, `func reportConditionEnded(_:) async -> Bool`, `func listSessions() async -> [Session]?`, plus automatic reconnection.

- [ ] **Step 1: Implement the connection wrapper**

```swift
import Foundation
import os

let agentLogger = Logger(subsystem: "au.com.workwireless.keepy-uppy.agent", category: "agent")

/// The agent's XPC client. Connects to the daemon's AGENT-ONLY Mach
/// service — never the general one — so the daemon's structural role
/// derivation (plan 1, spec §4) sees this process as the agent.
@MainActor
final class DaemonConnection {
    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?

    func connect() {
        let new = NSXPCConnection(machServiceName: agentMachServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if SigningRequirement.isEnforced {
            new.setCodeSigningRequirement(SigningRequirement.helperRequirement)
        }
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.resume()
        connection = new

        proxy()?.registerAsAgent { ok, message in
            if !ok { agentLogger.error("registerAsAgent rejected: \(message ?? "unknown")") }
        }
    }

    private func handleDisconnect() {
        connection = nil
        agentLogger.log("Daemon connection lost; reconnecting in 5s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func proxy() -> HelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            agentLogger.error("XPC error: \(error.localizedDescription)")
        } as? HelperProtocol
    }

    func startSession(_ session: Session) async -> Result<String, String> {
        guard let data = try? JSONEncoder().encode(session) else { return .failure("encode failed") }
        return await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: .failure("not connected")) }
            proxy.startSession(data) { sessionID, error in
                if let sessionID { continuation.resume(returning: .success(sessionID)) }
                else { continuation.resume(returning: .failure(error ?? "unknown")) }
            }
        }
    }

    func reportConditionEnded(_ sessionID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: false) }
            proxy.reportConditionEnded(sessionID) { ok, _ in continuation.resume(returning: ok) }
        }
    }

    func listSessions() async -> [Session]? {
        await withCheckedContinuation { continuation in
            guard let proxy = proxy() else { return continuation.resume(returning: nil) }
            proxy.listSessions { data, _ in
                guard let data, let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: sessions)
            }
        }
    }
}
```

- [ ] **Step 2: Wire up `main.swift`**

```swift
import Foundation

let connection = DaemonConnection()
connection.connect()

RunLoop.main.run()
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

Do not launch or register the agent — that needs a signed build and is human-verified later.

- [ ] **Step 4: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Agent/DaemonConnection.swift Agent/main.swift
git commit -m "Add agent XPC connection pinned to the agent-only Mach service"
```

---

### Task 3: Condition observers

**Files:**
- Create: `Agent/ConditionObservers.swift`
- Test: `Tests/ConditionObserverTests.swift`

**Interfaces:**
- Produces: `AppRunningObserving`, `DisplayObserving`, `CPUBusyObserving` protocols plus live implementations, and a pure `CPULoadSample` → sustained-busy evaluator, generic over injected time exactly like the session/safety engines.

Following the daemon's `SafetyObserving` pattern (plan 1 Task 9): protocols so the pure logic in Task 4 never touches a framework directly.

- [ ] **Step 1: Write the failing test for the CPU sustained-window logic**

`Tests/ConditionObserverTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class CPUBusyWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A momentary lull mid-job must not end the session — only a
    /// SUSTAINED drop below threshold for the full window should.
    func testBriefDipBelowThresholdDoesNotEndBusyWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.8, at: t0)
        window.record(busy: 0.3, at: t0.addingTimeInterval(10))
        window.record(busy: 0.8, at: t0.addingTimeInterval(20))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(20)))
    }

    func testSustainedQuietForTheFullWindowEndsIt() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.3, at: t0)
        window.record(busy: 0.2, at: t0.addingTimeInterval(60))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(60)), "not yet 120s")
        window.record(busy: 0.1, at: t0.addingTimeInterval(121))
        XCTAssertTrue(window.isSustainedQuiet(at: t0.addingTimeInterval(121)))
    }

    func testGoingBusyAgainResetsTheWindow() {
        var window = CPUBusyWindow(threshold: 0.5, sustainedFor: 120)
        window.record(busy: 0.2, at: t0)
        window.record(busy: 0.9, at: t0.addingTimeInterval(100))
        window.record(busy: 0.2, at: t0.addingTimeInterval(200))
        XCTAssertFalse(window.isSustainedQuiet(at: t0.addingTimeInterval(200)), "quiet period restarted at t=100")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: compile failure — `CPUBusyWindow` does not exist.

- [ ] **Step 3: Implement**

`Agent/ConditionObservers.swift`:

```swift
import Foundation
import AppKit
import CoreGraphics

// MARK: - Pure logic

/// Tracks whether CPU load has been below `threshold` continuously for at
/// least `sustainedFor` seconds. A single busy reading resets the clock —
/// this is what stops a momentary lull from ending a `whileCPUBusy`
/// session mid-job (spec §5).
struct CPUBusyWindow {
    let threshold: Double
    let sustainedFor: TimeInterval
    private var quietSince: Date?

    init(threshold: Double, sustainedFor: TimeInterval) {
        self.threshold = threshold
        self.sustainedFor = sustainedFor
    }

    mutating func record(busy: Double, at now: Date) {
        if busy < threshold {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
    }

    func isSustainedQuiet(at now: Date) -> Bool {
        guard let since = quietSince else { return false }
        return now.timeIntervalSince(since) >= sustainedFor
    }
}

// MARK: - Observing protocols (so the evidence loop in Task 4 never touches a framework)

protocol AppRunningObserving {
    func isRunning(bundleID: String) -> Bool
}

protocol DisplayObserving {
    func hasExternalDisplay() -> Bool
}

protocol CPUBusyObserving {
    /// Fraction 0...1, or nil if the sample could not be taken.
    func currentBusyFraction() -> Double?
}

// MARK: - Live implementations

struct SystemAppRunningObserver: AppRunningObserving {
    func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

struct SystemDisplayObserver: DisplayObserving {
    func hasExternalDisplay() -> Bool {
        // Built-in display, if present, is always id 0 on a MacBook; any
        // additional active display id means something external is
        // connected. The evidence loop already polls every 5s for the CPU
        // and app-running checks, so a plain count here on the same tick is
        // simpler than standing up a reconfiguration callback and gets the
        // same answer.
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return count > 1
    }
}

struct SystemCPUBusyObserver: CPUBusyObserving {
    func currentBusyFraction() -> Double? {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = cpuLoad.cpu_ticks
        let user = Double(ticks.0), system = Double(ticks.1), idle = Double(ticks.2), nice = Double(ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return 1.0 - (idle / total)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** TEST SUCCEEDED **`, existing count + 3.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Agent/ConditionObservers.swift Tests/ConditionObserverTests.swift
git commit -m "Add condition observers with pure sustained-CPU-quiet logic"
```

---

### Task 4: Evidence loop — reporting when conditions end

**Files:**
- Create: `Agent/EvidenceLoop.swift`
- Test: `Tests/EvidenceLoopTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionKind` (plan 1), the three `*Observing` protocols (Task 3), `DaemonConnection` (Task 2).
- Produces: pure `func sessionsToEnd(_ sessions: [Session], appRunning: AppRunningObserving, display: DisplayObserving, cpu: inout [UUID: CPUBusyWindow], busyNow: Double?, now: Date) -> [UUID]`, plus `EvidenceLoop` wiring it to the connection on a timer.

This is the agent's half of "no session outlives its evidence" (spec §5) — it is what makes `.whileAppRunning`/`.whileExternalDisplay`/`.whileCPUBusy` sessions actually end when their condition does.

- [ ] **Step 1: Write the failing tests**

`Tests/EvidenceLoopTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class EvidenceLoopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    struct FakeAppRunning: AppRunningObserving {
        let running: Set<String>
        func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    }
    struct FakeDisplay: DisplayObserving {
        let external: Bool
        func hasExternalDisplay() -> Bool { external }
    }

    private func session(_ kind: SessionKind) -> Session {
        Session(id: UUID(), kind: kind, owner: ClientID(rawValue: "x"),
               persistence: .detached, origin: .manual, startedAt: t0)
    }

    func testAppStillRunningIsNotEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertTrue(ended.isEmpty)
    }

    func testAppNoLongerRunningIsEnded() {
        let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"))
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertEqual(ended, [s.id])
    }

    func testExternalDisplayDisconnectedEndsTheSession() {
        let s = session(.whileExternalDisplay)
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertEqual(ended, [s.id])
    }

    func testDaemonEvaluableSessionsAreNeverReturned() {
        let s = session(.indefinite)
        var cpu: [UUID: CPUBusyWindow] = [:]
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []),
                                  display: FakeDisplay(external: false), cpu: &cpu, busyNow: nil, now: t0)
        XCTAssertTrue(ended.isEmpty, "the agent must never report on sessions it doesn't own evaluation of")
    }

    func testCPUBusySessionUsesItsOwnPerSessionWindow() {
        let s = session(.whileCPUBusy(threshold: 0.5))
        var cpu: [UUID: CPUBusyWindow] = [:]
        _ = sessionsToEnd([s], appRunning: FakeAppRunning(running: []), display: FakeDisplay(external: false),
                          cpu: &cpu, busyNow: 0.1, now: t0)
        let ended = sessionsToEnd([s], appRunning: FakeAppRunning(running: []), display: FakeDisplay(external: false),
                                  cpu: &cpu, busyNow: 0.1, now: t0.addingTimeInterval(121))
        XCTAssertEqual(ended, [s.id])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — `sessionsToEnd` does not exist.

- [ ] **Step 3: Implement**

`Agent/EvidenceLoop.swift`:

```swift
import Foundation

/// Pure: given the daemon's current session list and fresh observer
/// readings, which sessions' conditions have ended? `cpu` is `inout`
/// because each `.whileCPUBusy` session needs its own sustained-quiet
/// window, keyed by session id, surviving across calls.
func sessionsToEnd(
    _ sessions: [Session],
    appRunning: AppRunningObserving,
    display: DisplayObserving,
    cpu: inout [UUID: CPUBusyWindow],
    busyNow: Double?,
    now: Date
) -> [UUID] {
    var ended: [UUID] = []
    for session in sessions {
        switch session.kind {
        case .whileAppRunning(let bundleID):
            if !appRunning.isRunning(bundleID: bundleID) { ended.append(session.id) }
        case .whileExternalDisplay:
            if !display.hasExternalDisplay() { ended.append(session.id) }
        case .whileCPUBusy(let threshold):
            guard let busyNow else { continue }
            var window = cpu[session.id] ?? CPUBusyWindow(threshold: threshold, sustainedFor: 120)
            window.record(busy: busyNow, at: now)
            if window.isSustainedQuiet(at: now) {
                ended.append(session.id)
                cpu.removeValue(forKey: session.id)
            } else {
                cpu[session.id] = window
            }
        case .indefinite, .duration, .untilTime, .lease, .whileOnACPower:
            continue // not ours to evaluate
        }
    }
    return ended
}

@MainActor
final class EvidenceLoop {
    private let connection: DaemonConnection
    private let appRunning: AppRunningObserving
    private let display: DisplayObserving
    private let cpuObserver: CPUBusyObserving
    private var cpuWindows: [UUID: CPUBusyWindow] = [:]
    private var timer: Timer?

    init(connection: DaemonConnection,
         appRunning: AppRunningObserving = SystemAppRunningObserver(),
         display: DisplayObserving = SystemDisplayObserver(),
         cpuObserver: CPUBusyObserving = SystemCPUBusyObserver()) {
        self.connection = connection
        self.appRunning = appRunning
        self.display = display
        self.cpuObserver = cpuObserver
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard let sessions = await connection.listSessions() else { return }
        let ended = sessionsToEnd(sessions, appRunning: appRunning, display: display,
                                  cpu: &cpuWindows, busyNow: cpuObserver.currentBusyFraction(), now: Date())
        for id in ended {
            _ = await connection.reportConditionEnded(id.uuidString)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 5.

- [ ] **Step 5: Commit**

```bash
git add "Keepy Uppy.xcodeproj" Agent/EvidenceLoop.swift Tests/EvidenceLoopTests.swift
git commit -m "Add pure evidence loop reporting agent-evaluated sessions that ended"
```

---

### Task 5: Trigger rules — model, storage, pure evaluator

**Files:**
- Create: `Shared/TriggerRule.swift`
- Test: `Tests/TriggerRuleTests.swift`

**Interfaces:**
- Produces: `TriggerCondition`, `TriggerRule`, `TriggerStore` (reads/writes the shared `UserDefaults` suite), and a pure `func triggersToFire(_ rules: [TriggerRule], activeSessions: [Session], appRunning: AppRunningObserving, display: DisplayObserving, onACPower: Bool) -> [TriggerRule]`.

In `Shared/`, not `Agent/`, because plan 3's UI needs the same `TriggerRule`/`TriggerStore` types to build its editing screen — this is exactly the kind of shared model that must not be defined twice.

- [ ] **Step 1: Write the failing tests**

`Tests/TriggerRuleTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class TriggerRuleTests: XCTestCase {
    struct FakeAppRunning: AppRunningObserving {
        let running: Set<String>
        func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    }
    struct FakeDisplay: DisplayObserving {
        let external: Bool
        func hasExternalDisplay() -> Bool { external }
    }

    private func rule(_ condition: TriggerCondition, kind: SessionKind = .indefinite, enabled: Bool = true) -> TriggerRule {
        TriggerRule(id: UUID(), condition: condition, sessionKind: kind, enabled: enabled)
    }

    func testDisabledRuleNeverFires() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"), enabled: false)
        let fired = triggersToFire([r], activeSessions: [],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }

    func testAppLaunchedFiresWhenRunning() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let fired = triggersToFire([r], activeSessions: [],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    func testExternalDisplayConnectedFires() {
        let r = rule(.externalDisplayConnected)
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: true), onACPower: false)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    func testACPowerConnectedFires() {
        let r = rule(.acPowerConnected)
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: false), onACPower: true)
        XCTAssertEqual(fired.map(\.id), [r.id])
    }

    /// The most important test in this file: a trigger already represented
    /// by a live session must not fire again every tick.
    func testAlreadyActiveTriggerDoesNotFireAgain() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let already = Session(id: UUID(), kind: r.sessionKind, owner: ClientID(rawValue: "agent"),
                              persistence: .detached, origin: .trigger, startedAt: Date(),
                              triggerID: r.id)
        let fired = triggersToFire([r], activeSessions: [already],
                                   appRunning: FakeAppRunning(running: ["com.apple.dt.Xcode"]),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }

    func testConditionFalseDoesNotFire() {
        let r = rule(.appLaunched(bundleID: "com.apple.dt.Xcode"))
        let fired = triggersToFire([r], activeSessions: [], appRunning: FakeAppRunning(running: []),
                                   display: FakeDisplay(external: false), onACPower: false)
        XCTAssertTrue(fired.isEmpty)
    }
}
```

Note this task introduces one required change to `Shared/Session.swift`. Read that file first — the current initializer is `init(id:kind:owner:ownerUID: UInt32 = 0, persistence:origin:startedAt:)` (`ownerUID` already carries a default). Add `triggerID: UUID? = nil` as a new final parameter with a default, the same way `ownerUID` is handled, so most existing call sites (which construct sessions positionally/by-name without it) keep compiling unchanged. The one place that does need an explicit change: `Shared/SessionEngine.swift`'s `apply(_:now:)`, in the `.renewLease` case, reconstructs the renewed session by hand —

```swift
table.insert(Session(id: existing.id, kind: .lease(expires: until),
                     owner: existing.owner, persistence: existing.persistence,
                     origin: existing.origin, startedAt: existing.startedAt))
```

This must become `owner: existing.owner, ownerUID: existing.ownerUID, persistence: existing.persistence, origin: existing.origin, startedAt: existing.startedAt, triggerID: existing.triggerID` — carrying `triggerID` through explicitly. Without this, renewing a trigger-started lease would silently erase which rule it belongs to, and `triggersToFire`'s "don't refire an already-active trigger" check (Step 3 below) would then fire that rule again on the very next tick even though its session is still running. Add a regression test for this in `Tests/SessionEngineTests.swift` alongside the existing `testRenewLeasePreservesIdentityAndOnlyMovesDeadline`:

```swift
    func testRenewLeasePreservesTriggerID() {
        var engine = SessionEngine()
        let triggerID = UUID()
        let session = Session(id: UUID(), kind: .lease(expires: t0.addingTimeInterval(60)),
                              owner: ClientID(rawValue: "agent"), persistence: .detached,
                              origin: .trigger, startedAt: t0, triggerID: triggerID)
        engine.startSession(session, now: t0, liveAgentConnections: 1)
        _ = engine.renewLease(id: session.id, until: t0.addingTimeInterval(120), now: t0)
        XCTAssertEqual(engine.sessions.first?.triggerID, triggerID)
    }
```

(Adjust `t0`/helpers to match whatever fixtures `SessionEngineTests.swift` already uses.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — `TriggerCondition`/`TriggerRule`/`triggersToFire` do not exist, and `Session`'s memberwise initializer doesn't yet take `triggerID`.

- [ ] **Step 3: Implement**

`Shared/TriggerRule.swift`:

```swift
import Foundation

enum TriggerCondition: Codable, Equatable {
    case appLaunched(bundleID: String)
    case externalDisplayConnected
    case acPowerConnected
}

struct TriggerRule: Codable, Equatable, Identifiable {
    let id: UUID
    var condition: TriggerCondition
    var sessionKind: SessionKind
    var enabled: Bool
}

/// Off by default (spec §8): an app that starts keeping the Mac awake
/// unasked is a bug, not a feature. Shared with the future UI (plan 3),
/// which is the only thing that will ever populate this beyond the
/// empty default.
enum TriggerStore {
    private static let suiteName = "au.com.workwireless.keepy-uppy"
    private static let key = "triggerRules"

    static func load() -> [TriggerRule] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([TriggerRule].self, from: data)
        else { return [] }
        return rules
    }

    static func save(_ rules: [TriggerRule]) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(rules)
        else { return }
        defaults.set(data, forKey: key)
    }
}

/// Pure: which enabled rules have a true condition right now, excluding
/// any rule already represented by a live session (so a still-true
/// condition doesn't refire every tick — the daemon's admission path
/// would reject duplicates anyway via suppression/caps, but there is no
/// reason to hammer it).
func triggersToFire(
    _ rules: [TriggerRule],
    activeSessions: [Session],
    appRunning: AppRunningObserving,
    display: DisplayObserving,
    onACPower: Bool
) -> [TriggerRule] {
    let activeTriggerIDs = Set(activeSessions.compactMap(\.triggerID))
    return rules.filter { rule in
        guard rule.enabled, !activeTriggerIDs.contains(rule.id) else { return false }
        switch rule.condition {
        case .appLaunched(let bundleID):
            return appRunning.isRunning(bundleID: bundleID)
        case .externalDisplayConnected:
            return display.hasExternalDisplay()
        case .acPowerConnected:
            return onACPower
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 6.

- [ ] **Step 5: Commit**

```bash
git add -A Shared Tests "Keepy Uppy.xcodeproj"
git commit -m "Add trigger rule model, shared storage, and pure evaluator"
```

---

### Task 6: Agent-side trigger loop

**Files:**
- Modify: `Agent/EvidenceLoop.swift` (or a new `Agent/TriggerLoop.swift` — implementer's call, keep it small)

**Interfaces:**
- Consumes: `TriggerStore`/`triggersToFire` (Task 5), `PowerControl.batteryState()` (`Shared/`, plan 1) for the AC-power condition.
- Produces: the agent actually starting trigger sessions.

**The daemon side of this is already built and already tested — do not re-implement it.** `Shared/SessionEngine.swift`'s `SessionAdmission.evaluate` already has `if origin == .trigger && triggersSuppressed { return .triggerSuppressed }`, wired through `SessionEngine.startSession` → `DaemonRuntime.startSession` → `HelperService.startSession` (which already replies `"trigger starts are temporarily suppressed by a safety cooldown"`), and it is already covered by `testSafetySuppressionRejectsTriggersButAllowsManualStarts` in `Tests/SessionEngineTests.swift`. Confirm that for yourself by reading those two files and that test before writing anything — this task is agent-side wiring only, closing the loop spec §7 describes ("safety suppresses triggers") by finally giving that existing gate a real caller.

- [ ] **Step 1: Wire the agent's trigger loop**

Extend `EvidenceLoop.tick()` (Task 4) to, after reporting ended conditions, also: read `TriggerStore.load()`, call `triggersToFire` with the current session list and fresh observer readings (AC power via `PowerControl.batteryState().source == .acPower`), and for each fired rule call `connection.startSession` with a `Session` built from `rule.sessionKind`, `origin: .trigger`, `persistence: .detached`, `triggerID: rule.id`. Log (don't crash or retry-loop) on rejection — a `.triggerSuppressed`/`"cooldown"` rejection is expected, ordinary behaviour during a safety episode, not an error condition worth alarming on.

- [ ] **Step 2: Build and test**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, unchanged count — this task is wiring with no new pure logic of its own; `triggersToFire`'s "don't refire an active trigger" behavior is already covered by Task 5's `testAlreadyActiveTriggerDoesNotFireAgain`, and the daemon's suppression rejection is already covered as described above.

- [ ] **Step 3: Commit**

```bash
git add -A Agent "Keepy Uppy.xcodeproj"
git commit -m "Wire the agent's trigger loop to the daemon's existing suppression gate"
```

---

### Task 7: Daemon fairness fix — reserve cap headroom from orphaned detached sessions

**Files:**
- Modify: `Shared/SessionTable.swift`, `Shared/SessionEngine.swift`
- Test: `Tests/SessionEngineTests.swift`

**Interfaces:**
- Produces: `SessionTable.count(persistence:)`, a new `SessionAdmission.maxDetachedSessionsGlobal` cap, and its use in `SessionAdmission.evaluate`/`SessionEngine.startSession`.

Closes the spec §5 "known limitation" section (read it — `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md`, the section literally titled "Known limitation: the global session cap is a shared, exhaustible resource") — for real, matching what it actually asks for: a client can open many connections, start `detached` sessions on each (these are legitimate — that persistence is what lets `keepy-uppy on --for 2h` survive the shell that started it), and disconnect. Those sessions are **not** swept as garbage (`SessionTable.removeAll(ownedBy:)` deliberately only removes `.clientBound` sessions on disconnect), so enough of them can consume the entire 200-session global cap, denying every other client — including the menu-bar app — for as long as they remain. A per-connection rate limiter would not fix this: an attacker can simply open connections slowly, one at a time, and still eventually fill the table. The spec's own suggested fix is to reserve global-cap headroom; the simplest correct version of that, given only `.detached` sessions can ever become orphaned in the first place (`.clientBound` ones die with their owner by construction), is to sub-cap detached sessions specifically — guaranteeing at least `maxSessionsGlobal - maxDetachedSessionsGlobal` slots are always available for `.clientBound` sessions no matter how much detached garbage accumulates.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SessionEngineTests.swift` (matching whatever session-construction helpers that file already uses — read it first rather than assuming the shape below is exact):

```swift
    func testDetachedSessionCapRejectsBeyondLimitEvenAcrossManyOwners() {
        var engine = SessionEngine()
        // Fill the detached sub-cap using many distinct owners, so this
        // proves the cap is global-to-detached-kind, not per-owner.
        for i in 0..<SessionAdmission.maxDetachedSessionsGlobal {
            let session = Session(id: UUID(), kind: .indefinite,
                                  owner: ClientID(rawValue: "owner-\(i)"),
                                  persistence: .detached, origin: .manual, startedAt: t0)
            XCTAssertEqual(engine.startSession(session, now: t0, liveAgentConnections: 0), .admitted)
        }
        let oneMore = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "owner-extra"),
                              persistence: .detached, origin: .manual, startedAt: t0)
        XCTAssertEqual(engine.startSession(oneMore, now: t0, liveAgentConnections: 0), .globalLimitReached)
    }

    func testDetachedCapDoesNotRestrictClientBoundSessions() {
        var engine = SessionEngine()
        for i in 0..<SessionAdmission.maxDetachedSessionsGlobal {
            let session = Session(id: UUID(), kind: .indefinite,
                                  owner: ClientID(rawValue: "owner-\(i)"),
                                  persistence: .detached, origin: .manual, startedAt: t0)
            _ = engine.startSession(session, now: t0, liveAgentConnections: 0)
        }
        // The detached sub-cap must not touch clientBound admission at all —
        // this is the actual guarantee: headroom stays reserved for sessions
        // whose owner is (by construction) still connected.
        let clientBound = Session(id: UUID(), kind: .indefinite, owner: ClientID(rawValue: "owner-cb"),
                                  persistence: .clientBound, origin: .manual, startedAt: t0)
        XCTAssertEqual(engine.startSession(clientBound, now: t0, liveAgentConnections: 0), .admitted)
    }
```

(Use whichever fixture for "an arbitrary fixed `Date`" the file already defines as `t0`/similar — check the top of `SessionEngineTests.swift` rather than inventing a new one.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure or assertion failure — `SessionAdmission.maxDetachedSessionsGlobal` does not exist yet.

- [ ] **Step 3: Implement**

In `Shared/SessionTable.swift`, add a helper next to `count(ownedBy:)`:

```swift
    /// The live count of sessions with a given persistence — used to
    /// enforce the detached-session sub-cap (`SessionAdmission`), which
    /// reserves global-cap headroom for `.clientBound` sessions regardless
    /// of how much orphaned `.detached` garbage accumulates from
    /// disconnected owners.
    func count(persistence: SessionPersistence) -> Int {
        storage.values.reduce(0) { $1.persistence == persistence ? $0 + 1 : $0 }
    }
```

In `Shared/SessionEngine.swift`, extend `SessionAdmission`:

```swift
    /// Only `.detached` sessions can ever become orphaned garbage —
    /// `.clientBound` ones are removed the moment their owner disconnects
    /// (`SessionTable.removeAll(ownedBy:)`). Capping detached sessions at
    /// half the global cap guarantees at least `maxSessionsGlobal -
    /// maxDetachedSessionsGlobal` = 100 slots stay available for
    /// `.clientBound` sessions no matter how many connections flood
    /// `detached` starts and disappear (spec §5's documented known
    /// limitation — this closes it once the CLI, the actual origin of
    /// legitimate `detached` sessions, exists to design the fix against).
    static let maxDetachedSessionsGlobal = 100
```

and its `evaluate` function's admission check:

```swift
    static func evaluate(kind: SessionKind, origin: SessionOrigin,
                         ownerCount: Int, globalCount: Int, detachedGlobalCount: Int,
                         liveAgentConnections: Int, onACPower: Bool,
                         triggersSuppressed: Bool, persistence: SessionPersistence) -> SessionAdmission {
        if globalCount >= maxSessionsGlobal { return .globalLimitReached }
        if persistence == .detached && detachedGlobalCount >= maxDetachedSessionsGlobal { return .globalLimitReached }
        if ownerCount >= maxSessionsPerOwner { return .ownerLimitReached }
        if origin == .trigger && triggersSuppressed { return .triggerSuppressed }
        if kind == .whileOnACPower && !onACPower { return .conditionNotMet }
        if !kind.isDaemonEvaluable && liveAgentConnections <= 0 { return .noAgentConnected }
        return .admitted
    }
```

(`.globalLimitReached` is reused rather than adding a new case: from a caller's perspective — CLI, UI, agent — both are "the daemon can't take any more sessions of this shape right now, try again later," and `HelperService`'s existing reply text for that case already reads correctly either way. Reusing it also means `HelperService`/`CLI/main.swift` need no changes for this task.)

Update `SessionEngine.startSession` to compute and pass the new argument, matching how `ownerCount`/`globalCount` are already computed from `table`:

```swift
        let decision = SessionAdmission.evaluate(
            kind: session.kind,
            origin: session.origin,
            ownerCount: table.count(ownedBy: session.owner),
            globalCount: table.count,
            detachedGlobalCount: table.count(persistence: .detached),
            liveAgentConnections: liveAgentConnections,
            onACPower: onACPower,
            triggersSuppressed: triggersSuppressed,
            persistence: session.persistence)
```

- [ ] **Step 4: Build and test**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 2. Also re-run the full suite (not just the new tests) since `SessionAdmission.evaluate`'s signature changed — any other direct caller of it (grep for `SessionAdmission.evaluate(` across `Tests/` first) needs the new `detachedGlobalCount:`/`persistence:` arguments added too, or it will simply fail to compile, which is the correct signal to fix it rather than a flake.

- [ ] **Step 5: Commit**

```bash
git add -A Shared Tests "Keepy Uppy.xcodeproj"
git commit -m "Reserve global session-cap headroom from orphaned detached sessions"
```

---

### Task 8: CLI argument and duration parsing

**Files:**
- Create: `Shared/CLICommand.swift`
- Test: `Tests/CLICommandTests.swift`

**Interfaces:**
- Produces: `enum CLICommand` (`.on(kind: SessionKind, persistence: SessionPersistence)`, `.off(target: StopTarget)`, `.status(json: Bool)`, `.sessions`) and `func parseCLIArguments(_ args: [String]) -> Result<CLICommand, String>`, fully pure.

Matches spec §9's documented surface exactly:
```
keepy-uppy on [--for DURATION | --until TIME | --while-app NAME]
keepy-uppy off [--all | --session ID]
keepy-uppy status [--json]
keepy-uppy sessions
```

- [ ] **Step 1: Write the failing tests**

`Tests/CLICommandTests.swift`:

```swift
import XCTest
@testable import KeepyUppy

final class CLICommandParsingTests: XCTestCase {
    func testBareOnIsIndefinite() {
        guard case .success(.on(let kind, let persistence)) = parseCLIArguments(["on"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .indefinite)
        XCTAssertEqual(persistence, .detached, "CLI sessions default to detached, spec §5")
    }

    func testOnForHours() {
        guard case .success(.on(let kind, _)) = parseCLIArguments(["on", "--for", "2h"]) else {
            return XCTFail("expected .on")
        }
        guard case .duration(let until) = kind else { return XCTFail("expected .duration") }
        // Can't assert an exact Date without injecting time into the
        // parser; assert the offset is right instead.
        XCTAssertEqual(until.timeIntervalSinceNow, 2 * 3600, accuracy: 2)
    }

    func testOnForMinutes() {
        guard case .success(.on(let kind, _)) = parseCLIArguments(["on", "--for", "30m"]) else {
            return XCTFail("expected .on")
        }
        guard case .duration(let until) = kind else { return XCTFail("expected .duration") }
        XCTAssertEqual(until.timeIntervalSinceNow, 30 * 60, accuracy: 2)
    }

    func testOnWhileApp() {
        guard case .success(.on(let kind, _)) = parseCLIArguments(["on", "--while-app", "com.apple.dt.Xcode"]) else {
            return XCTFail("expected .on")
        }
        XCTAssertEqual(kind, .whileAppRunning(bundleID: "com.apple.dt.Xcode"))
    }

    func testOnRejectsMultipleEndConditions() {
        guard case .failure = parseCLIArguments(["on", "--for", "2h", "--while-app", "x"]) else {
            return XCTFail("expected failure — only one end condition allowed")
        }
    }

    func testOnRejectsMalformedDuration() {
        guard case .failure = parseCLIArguments(["on", "--for", "banana"]) else {
            return XCTFail("expected failure")
        }
    }

    func testOffAll() {
        guard case .success(.off(.all)) = parseCLIArguments(["off", "--all"]) else {
            return XCTFail("expected .off(.all)")
        }
    }

    func testOffSpecificSession() {
        guard case .success(.off(.session(let id))) = parseCLIArguments(["off", "--session", "abc-123"]) else {
            return XCTFail("expected .off(.session)")
        }
        XCTAssertEqual(id, "abc-123")
    }

    func testBareOffTargetsOwnSessions() {
        guard case .success(.off(.own)) = parseCLIArguments(["off"]) else {
            return XCTFail("expected .off(.own)")
        }
    }

    func testStatusJSON() {
        guard case .success(.status(let json)) = parseCLIArguments(["status", "--json"]) else {
            return XCTFail("expected .status(json: true)")
        }
        XCTAssertTrue(json)
    }

    func testSessions() {
        guard case .success(.sessions) = parseCLIArguments(["sessions"]) else {
            return XCTFail("expected .sessions")
        }
    }

    func testUnknownCommandFails() {
        guard case .failure = parseCLIArguments(["frobnicate"]) else {
            return XCTFail("expected failure")
        }
    }

    func testEmptyArgumentsFails() {
        guard case .failure = parseCLIArguments([]) else {
            return XCTFail("expected failure")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test …` (same flags)
Expected: compile failure — none of these types exist.

- [ ] **Step 3: Implement**

`Shared/CLICommand.swift`:

```swift
import Foundation

enum StopTarget: Equatable {
    case own
    case all
    case session(String)
}

enum CLICommand: Equatable {
    case on(kind: SessionKind, persistence: SessionPersistence)
    case off(StopTarget)
    case status(json: Bool)
    case sessions
}

/// Pure: no I/O, no XPC, no process exit — fully testable. `now` is
/// injected so duration parsing can be tested without depending on the
/// wall clock.
func parseCLIArguments(_ args: [String], now: Date = Date()) -> Result<CLICommand, String> {
    guard let command = args.first else { return .failure("usage: keepy-uppy on|off|status|sessions") }
    let rest = Array(args.dropFirst())

    switch command {
    case "on":
        return parseOn(rest, now: now)
    case "off":
        return parseOff(rest)
    case "status":
        return .success(.status(json: rest.contains("--json")))
    case "sessions":
        return .success(.sessions)
    default:
        return .failure("unknown command '\(command)'; usage: keepy-uppy on|off|status|sessions")
    }
}

private func parseOn(_ args: [String], now: Date) -> Result<CLICommand, String> {
    var endConditions: [SessionKind] = []

    if let forIndex = args.firstIndex(of: "--for"), args.indices.contains(forIndex + 1) {
        switch parseDuration(args[forIndex + 1]) {
        case .success(let interval): endConditions.append(.duration(until: now.addingTimeInterval(interval)))
        case .failure(let message): return .failure(message)
        }
    }
    if let untilIndex = args.firstIndex(of: "--until"), args.indices.contains(untilIndex + 1) {
        guard let date = parseTimeOfDay(args[untilIndex + 1], relativeTo: now) else {
            return .failure("could not parse --until time '\(args[untilIndex + 1])'")
        }
        endConditions.append(.untilTime(date))
    }
    if let appIndex = args.firstIndex(of: "--while-app"), args.indices.contains(appIndex + 1) {
        endConditions.append(.whileAppRunning(bundleID: args[appIndex + 1]))
    }

    guard endConditions.count <= 1 else {
        return .failure("only one of --for, --until, --while-app may be given")
    }
    return .success(.on(kind: endConditions.first ?? .indefinite, persistence: .detached))
}

private func parseOff(_ args: [String]) -> Result<CLICommand, String> {
    if args.contains("--all") { return .success(.off(.all)) }
    if let idx = args.firstIndex(of: "--session"), args.indices.contains(idx + 1) {
        return .success(.off(.session(args[idx + 1])))
    }
    return .success(.off(.own))
}

/// Accepts "30s", "10m", "2h" — the smallest set that covers every
/// realistic keep-awake duration without inventing a parsing DSL.
func parseDuration(_ string: String) -> Result<TimeInterval, String> {
    guard let unit = string.last, let value = Double(string.dropLast()) else {
        return .failure("invalid duration '\(string)' — use e.g. 30s, 10m, 2h")
    }
    switch unit {
    case "s": return .success(value)
    case "m": return .success(value * 60)
    case "h": return .success(value * 3600)
    default: return .failure("invalid duration unit in '\(string)' — use s, m, or h")
    }
}

/// Accepts "HH:MM" in the local timezone, rolling to tomorrow if that
/// time has already passed today.
func parseTimeOfDay(_ string: String, relativeTo now: Date) -> Date? {
    let parts = string.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
    var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    guard let candidate = Calendar.current.date(from: components) else { return nil }
    return candidate > now ? candidate : Calendar.current.date(byAdding: .day, value: 1, to: candidate)
}
```

- [ ] **Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 13.

- [ ] **Step 5: Commit**

```bash
git add -A Shared Tests "Keepy Uppy.xcodeproj"
git commit -m "Add pure CLI argument and duration parsing"
```

---

### Task 9: CLI execution, XPC wiring, and output

**Files:**
- Modify: `CLI/main.swift`

**Interfaces:**
- Consumes: `parseCLIArguments`, `CLICommand` (Task 8); `HelperProtocol`, `SigningRequirement.requirement` (plan 1).
- Produces: the working `keepy-uppy` binary.

- [ ] **Step 1: Implement**

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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("keepy-uppy: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let ownerID = ClientID(rawValue: "cli-\(ProcessInfo.processInfo.processIdentifier)")

guard case .success(let command) = parseCLIArguments(Array(CommandLine.arguments.dropFirst())) else {
    if case .failure(let message) = parseCLIArguments(Array(CommandLine.arguments.dropFirst())) {
        fail(message)
    }
    fail("usage: keepy-uppy on|off|status|sessions")
}

guard let proxy = connect() else { fail("could not connect to the Keepy Uppy daemon") }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

switch command {
case .on(let kind, let persistence):
    let session = Session(id: UUID(), kind: kind, owner: ownerID, persistence: persistence,
                          origin: .manual, startedAt: Date(), triggerID: nil)
    guard let data = try? JSONEncoder().encode(session) else { fail("internal error encoding session") }
    proxy.startSession(data) { sessionID, error in
        if let sessionID {
            print("Started session \(sessionID)")
        } else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!)
            exitCode = 1
        }
        semaphore.signal()
    }

case .off(.all):
    proxy.stopAllSessions(all: true) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .off(.own):
    proxy.stopAllSessions(all: false) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .off(.session(let id)):
    proxy.stopSession(id) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .status(let json):
    proxy.currentState { disabled in
        if json {
            print("{\"keepingAwake\": \(disabled)}")
        } else {
            print(disabled ? "keeping awake" : "normal sleep")
        }
        semaphore.signal()
    }

case .sessions:
    proxy.listSessions { data, error in
        guard let data, let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed to list sessions")\n".data(using: .utf8)!)
            exitCode = 1
            return semaphore.signal()
        }
        if sessions.isEmpty {
            print("No active sessions.")
        } else {
            for session in sessions {
                print("\(session.id)  \(session.kind)  origin=\(session.origin.rawValue)")
            }
        }
        semaphore.signal()
    }
}

_ = semaphore.wait(timeout: .now() + 10)
exit(exitCode)
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild build -project "Keepy Uppy.xcodeproj" -scheme "Keepy Uppy" -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=-`
Expected: `** BUILD SUCCEEDED **`

Run: `"build/Build/Products/Debug/Keepy Uppy.app/Contents/MacOS/keepy-uppy" status`
Expected: attempts to connect and either prints a state or a connection error — either is fine as a smoke test (the daemon may not be registered on this machine yet); a crash is not fine.

- [ ] **Step 3: Commit**

```bash
git add "Keepy Uppy.xcodeproj" CLI/main.swift
git commit -m "Wire the CLI to the daemon over XPC with human and JSON output"
```

---

### Task 10: Headless bootstrap — `keepy-uppy setup`

**Files:**
- Modify: `CLI/main.swift`

**Interfaces:**
- Produces: a `setup` command that registers both the daemon and the agent via `SMAppService`, so a fully headless install (no UI ever run) has a way to get both background services registered and approved.

Without this, the headless-first architecture (spec §1) has no bootstrap path for a user who never runs the menu-bar app — plan 3's UI can also trigger registration, but the CLI must be able to do it alone, since a headless user by definition may never install the UI at all.

- [ ] **Step 1: Add the command to parsing and execution**

Extend `Shared/CLICommand.swift`'s `CLICommand` enum with `case setup`, and `parseCLIArguments` to recognise `"setup"`. Add a test:

```swift
    func testSetup() {
        guard case .success(.setup) = parseCLIArguments(["setup"]) else {
            return XCTFail("expected .setup")
        }
    }
```

- [ ] **Step 2: Implement the registration flow**

In `CLI/main.swift`, add a `case .setup` branch that:
1. Calls `SMAppService.daemon(plistName: "au.com.workwireless.keepy-uppy.helper.plist").register()` and `SMAppService.agent(plistName: "au.com.workwireless.keepy-uppy.agent.plist").register()`.
2. Prints each result plainly (`"Daemon: registered"` / `"Daemon: requires approval — run 'keepy-uppy setup' again after approving in System Settings"` / an error).
3. If either status is `.requiresApproval`, calls `SMAppService.openSystemSettingsLoginItems()` so the user lands directly on the right pane rather than having to find it themselves.

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild test …` (same flags)
Expected: `** TEST SUCCEEDED **`, existing + 1.

Do not run `keepy-uppy setup` for real — it registers a real LaunchDaemon/LaunchAgent, which needs a signed build and human approval. Deferred to human verification.

- [ ] **Step 4: Commit**

```bash
git add -A Shared CLI Tests "Keepy Uppy.xcodeproj"
git commit -m "Add keepy-uppy setup for headless daemon/agent registration"
```

---

### Task 11: Documentation and manual verification checklist

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: accurate documentation of the real CLI surface (replacing plan 1's placeholder `on|off|status` sketch) and the accumulated manual checklist for everything this plan added.

- [ ] **Step 1: Update the CLI section**

Replace the README's existing CLI usage block with the real, final syntax:

```markdown
## Command line

    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" setup
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" on
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" on --for 2h
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" on --until 17:00
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" on --while-app com.apple.dt.Xcode
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" off
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" off --all
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" status --json
    "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" sessions

Run `setup` once on a machine that will never run the menu-bar app — it
registers the daemon and per-user agent and opens System Settings if
approval is needed. `on` with no flags starts an indefinite session that
persists after this command exits; `off` with no flags stops only the
sessions you started.
```

- [ ] **Step 2: Extend the manual checklist**

Add:

```markdown
- [ ] `keepy-uppy setup` registers both background items; approving once is enough
- [ ] `keepy-uppy on --for 30s` starts a session that ends on its own after 30 seconds
- [ ] `keepy-uppy on --while-app <bundle id>` ends within ~5s of quitting that app
- [ ] Killing the agent process (Activity Monitor) does not end `--for`/indefinite sessions, but does end `--while-app` ones
- [ ] Two terminals opening 25 sessions each are individually capped at 20 and rate-limited within each connection
- [ ] A trigger rule (once one exists via direct `UserDefaults` write, since there is no UI yet) fires once and does not refire while its session is active
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the real CLI surface and extend the manual checklist"
```
