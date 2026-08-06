# Keepy Uppy (Swift) — Design

**Date:** 2026-08-06
**Status:** Approved
**Supersedes for implementation purposes:** `2026-08-06-keepy-uppy-design.md` (the Rust/objc2 version). That
document's product rationale (why `caffeinate`/clamshell mode don't solve
this, why a prompt-per-action privilege model was chosen) still applies and
isn't repeated in full here — this spec only documents what's the same,
what's different, and why.

## 1. Summary

Keepy Uppy is a native Swift, signed and notarized, menu-bar-only macOS app
that keeps a MacBook running with the lid closed by toggling
`pmset -a disablesleep`. It is a from-scratch Swift/AppKit-via-SwiftUI
reimplementation of the same product originally designed in Rust with
`objc2`. The rewrite was chosen because the app is almost entirely AppKit
plumbing (status item, menu, timer, notifications) with very little of the
kind of logic Rust's specific strengths would matter for, and because
`objc2` is a third-party approximation of an API surface Swift has natively
— the Rust plan required an explicit research pass to verify current
`objc2` API shapes and still carried three unverified-risk call sites,
none of which apply here.

Target: macOS 13+ (Ventura) — the floor for both `SMAppService`
(launch-at-login) and SwiftUI's `MenuBarExtra` scene type.

## 2. Architecture

A single Xcode project, `Keepy Uppy.xcodeproj`, one macOS App target,
organized into four Swift files with the same logic/UI boundary the Rust
design used:

- **`KeepyUppyApp.swift`** — the `App` entry point:
  ```swift
  @main
  struct KeepyUppyApp: App {
      @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
      @StateObject private var monitor = PowerMonitor()

      var body: some Scene {
          MenuBarExtra {
              MenuContent(monitor: monitor)
          } label: {
              Image(systemName: monitor.sleepState == .disabled ? "balloon.fill" : "balloon")
          }
          .menuBarExtraStyle(.menu)
      }
  }
  ```
  `NSApplicationDelegateAdaptor` exists specifically because SwiftUI's `App`
  protocol has no termination hook of its own — `AppDelegate` is a minimal
  `NSObject, NSApplicationDelegate` whose only job is `applicationWillTerminate`.
- **`PowerMonitor.swift`** — `class PowerMonitor: ObservableObject` with
  `@Published var sleepState: SleepState`, `@Published var batteryState: BatteryState`,
  `@Published var loginItemEnabled: Bool`. Owns a background `Task` started
  at init that loops `try? await Task.sleep(for: .seconds(30))` → re-reads
  real state via `PowerService`/`LoginItemService` → publishes updates on
  the main actor. SwiftUI re-renders the icon and menu automatically from
  these published properties; there is no manual "refresh the UI" call
  anywhere, unlike the Rust design's explicit `refresh_menu_state()`.
- **`PowerService.swift`** — pure logic + system calls, no SwiftUI/AppKit
  dependency:
  - `enum SleepState { case disabled, enabled, unknown }`
  - `enum PowerSource { case battery, acPower, unknown }`
  - `struct BatteryState { let percentage: Int?; let source: PowerSource }`
  - `static func parseSleepDisabled(_ output: String) -> SleepState` (pure)
  - `static func parseBattery(_ output: String) -> BatteryState` (pure)
  - `static func readSleepState() throws -> SleepState`
  - `static func readBatteryState() throws -> BatteryState`
  - `static func setSleepDisabled(_ disabled: Bool) throws`
  - Reads/writes shell out via `Process` (`pmset` for reads, `osascript`
    running `do shell script "pmset -a disablesleep N" with administrator
    privileges` for writes, producing the native macOS auth dialog) — same
    mechanism as the Rust design, just through `Process` instead of
    `std::process::Command`.
- **`LoginItemService.swift`** — thin wrapper over `SMAppService.mainApp`:
  `static func status() -> LoginItemStatus`, `static func register() throws`,
  `static func unregister() throws`.
- **`MenuContent.swift`** — the `View` shown by `MenuBarExtra`: a
  non-interactive status line, a toggle button, a "Launch at Login" toggle,
  and Quit, all bound to `PowerMonitor`'s published state.

**Source of truth:** `pmset` itself, exactly as in the Rust design — the
30-second poll loop and every action handler re-read actual system state
rather than assuming a command succeeded.

## 3. UX and Behavior

One deliberate change from the Rust design: `MenuBarExtra` has no built-in
way to distinguish a left-click from a right-click the way a raw
`NSStatusItem` does, so **every click (left or right) opens the same
menu** — there is no more "left-click toggles instantly." Getting that
distinction back would require dropping to `NSStatusItem` directly and
would defeat the point of using `MenuBarExtra`. This was an explicit,
approved trade: simpler, more idiomatic code in exchange for one extra
click to toggle.

Menu contents (top to bottom): a disabled/non-interactive status line
("Keeping Awake" / "Normal Sleep" / "Unknown"), a "Turn On/Off Keepy Uppy"
button, a "Launch at Login" toggle, a separator, and "Quit Keepy Uppy".

- **Toggle button**: calls `PowerService.setSleepDisabled(!currentlyDisabled)`.
  Triggers the OS admin prompt. A canceled dialog is a silent no-op (no
  error UI) — detected the same way as the Rust design, via the "User
  canceled" text `osascript` writes to stderr on cancellation.
- **External sync**: the 30-second `PowerMonitor` loop re-reads `pmset -g`,
  so a `pmset` change made outside the app (e.g. from a terminal) is
  reflected within 30 seconds.
- **Re-enable on quit**: `AppDelegate.applicationWillTerminate` calls
  `PowerService.setSleepDisabled(false)` if sleep is currently disabled —
  one final admin prompt, acceptable because the user is present at quit
  time.

## 4. Low-Battery Auto-Off

Unchanged from the Rust design: the same `PowerMonitor` loop checks battery
level and power source, and below **10%** on battery power with sleep
disabled, triggers the re-enable flow and posts a notification.

**Known limitation (unchanged, and not a Swift-vs-Rust issue):**
re-enabling requires an admin prompt, so if the lid is closed inside a bag,
nobody is present to approve it — auto-off can't complete unattended in
exactly the scenario it exists for. This is inherent to the prompt-per-action
privilege model (§5), independent of implementation language. v1 ships this
as best-effort, attended-use-only, documented plainly in the README. A v2
privileged-helper-daemon path (`SMAppService` + XPC) remains the way to make
this bulletproof, same as before.

One genuine improvement from the rewrite: the low-battery notification uses
the modern `UNUserNotificationCenter` (with an authorization request at
launch) instead of the deprecated `NSUserNotification` API the Rust design
had to fall back to, because the Rust/objc2 research pass found the modern
API needs bundle/entitlement plumbing that's straightforward from Xcode but
awkward to set up outside it.

## 5. Privilege Model

Unchanged: every privileged action goes through
`osascript -e 'do shell script "pmset -a disablesleep N" with administrator
privileges'`, run via `Process`, producing the standard macOS admin
authentication dialog per action. No sudoers modification, no privileged
helper daemon, nothing installed outside the `.app` bundle.

## 6. Packaging & Distribution

- `Keepy Uppy.xcodeproj`, one macOS App target named "Keepy Uppy", bundle id
  `au.com.workwireless.keepy-uppy`, `LSMinimumSystemVersion` `13.0`.
- `Info.plist`: `LSUIElement = true` — still required to suppress the Dock
  icon even though `MenuBarExtra` is used; `MenuBarExtra` alone does not
  imply agent-app status.
- App icon: `Assets.xcassets/AppIcon.appiconset`, populated with PNGs
  rendered from the `balloon.fill` SF Symbol by a small one-off Swift
  script (same rendering approach the Rust design used for its `.icns`,
  just targeting an asset catalog instead of `iconutil` directly, since
  Xcode compiles the catalog itself during the build).
- `just` remains the orchestration layer (kept from the Rust design's
  tooling, now wrapping `xcodebuild` instead of `cargo`):
  - `just build` → `xcodebuild build` (Debug, for local iteration)
  - `just archive` → `xcodebuild archive` then `xcodebuild -exportArchive`
    against a checked-in `ExportOptions.plist` (Developer ID Application
    method)
  - `just notarize` → `xcrun notarytool submit` + `xcrun stapler staple`
  - `just dmg` → `hdiutil create`
- No auto-updater in v1. Releases distributed via GitHub Releases.

## 7. Error Handling

Unchanged in shape from the Rust design:
- Admin dialog canceled → silent no-op, no error UI.
- `pmset` output that fails to parse → `SleepState.unknown` /
  `PowerSource.unknown`, surfaced as an "Unknown" status line in the menu
  rather than a crash.
- Every state-changing action is followed automatically by the next
  `PowerMonitor` publish (either the immediate one triggered by the action,
  or the next 30s poll) — the icon is never derived from an assumption
  about what a command did.

## 8. Testing

- **XCTest unit tests** for `PowerService.parseSleepDisabled` and
  `PowerService.parseBattery`, using the same fixture strings as the Rust
  design's `power.rs` tests (captured/representative `pmset -g` and
  `pmset -g batt` output, including malformed input for the `.unknown`
  path). Run via `xcodebuild test -scheme "Keepy Uppy"` or Cmd-U in Xcode.
- **Manual test checklist** (maintained in the README) covering what can't
  be automated: toggle on/off via the menu, canceling the admin dialog,
  external `pmset` change syncing within 30s, "Launch at Login"
  round-trip, quit-restores-sleep, and low-battery auto-off (verified with
  a temporarily lowered threshold). This list drops the Rust checklist's
  separate "left-click toggles directly" case, since that behavior no
  longer exists (§3).
- SwiftUI view code itself is not unit-tested; the `PowerService`/
  `LoginItemService` vs. `MenuContent`/`PowerMonitor` boundary exists so
  everything that reasonably can be tested, is.

## 9. Out of Scope for v1

Unchanged from the Rust design:
- Privileged helper daemon / XPC (documented v2 path for bulletproof
  unattended auto-off).
- Auto-updater.
- Custom automation triggers beyond the battery/external-sync checks
  already specified.
- Windows/Linux support — macOS-only by design.
