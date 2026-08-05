# Keepy Uppy — Design

**Date:** 2026-08-06
**Status:** Approved

## 1. Summary

Keepy Uppy is a signed, notarized, menu-bar-only macOS app (no Dock icon, no
windows) that keeps a MacBook running with the lid closed by toggling
`pmset -a disablesleep`. It exists because the common alternatives don't
actually solve this: `caffeinate` only blocks idle sleep and is overridden by
the explicit sleep event that lid-closure triggers, and clamshell mode
requires an external display, keyboard, and mouse — unavailable in the
"laptop running in a bag/drawer" case (e.g. a long remote build or Claude
Code session).

The menu bar icon is a balloon (SF Symbol): filled = keeping uppy, outline =
normal sleep behavior.

Target: macOS 13+ (Ventura), the floor for both `SMAppService`
launch-at-login and the balloon SF Symbol used for the icon.

## 2. Architecture

Single Rust binary crate (`keepy-uppy`), bundled into `Keepy Uppy.app`, built
on `objc2` + `objc2-app-kit` + `objc2-foundation` + `objc2-service-management`.

Three modules with a hard boundary between system logic and UI:

- **`power.rs`** — all system interaction; no AppKit dependency.
  - Reads sleep-disabled state by running `pmset -g` and parsing the
    `SleepDisabled` line.
  - Reads battery level/power-source by running `pmset -g batt` and parsing
    its output.
  - Changes state by spawning:
    `osascript -e 'do shell script "pmset -a disablesleep N" with administrator privileges'`
    which produces the native macOS admin password / Touch ID dialog.
  - All parsing is implemented as pure functions taking a string and
    returning a typed result, so this module is unit-testable against
    captured fixture output without touching the real system.
- **`login_item.rs`** — thin wrapper around `SMAppService` for
  register/unregister/status of the login item.
- **`main.rs` / `app.rs`** — the AppKit shell: `NSApplication` setup, status
  bar item, menu construction, app delegate, and a 30-second `NSTimer` that
  drives periodic re-sync.

**Source of truth:** `pmset` itself. After every toggle attempt, the app
re-reads actual state from `pmset -g` and draws the icon from that — it never
assumes success from the exit code of the toggle command alone.

## 3. UX and Behavior

- **Left-click** the balloon icon: toggle immediately. Triggers the OS admin
  prompt. If the user cancels the dialog, `osascript` exits non-zero with a
  "User canceled" error — this is treated as a silent no-op, not an error
  dialog.
- **Right-click**: opens a menu showing current state (on/off), a Toggle
  item, a "Launch at Login" checkbox (backed by `login_item.rs`), and Quit.
  State is re-read from `pmset -g` at menu-open time so it's never stale.
- **External sync**: the 30-second timer re-reads `pmset -g` and updates the
  icon, so if `disablesleep` is changed from a terminal or another tool, the
  menu bar reflects it within 30 seconds.
- **Re-enable on quit**: if sleep is disabled at the moment the app is
  quitting (via the Quit menu item or normal termination), the app
  delegate's termination hook runs the re-enable command before exiting —
  one final admin prompt. The user is present at quit time, so this prompt
  is acceptable.

## 4. Low-Battery Auto-Off

The same 30-second timer checks battery level and power source. When on
battery power and charge drops below **10%** while sleep is disabled, the
app triggers the re-enable flow and posts a user notification.

**Known limitation:** re-enabling sleep requires root, and the app's
privilege model is prompt-per-action (see §5), so auto-off pops a password
dialog. If the lid is closed inside a bag, nobody is present to approve that
dialog, so in exactly the scenario the low-battery guard exists for (an
unattended, closed, draining Mac) it cannot complete unattended. This is an
inherent consequence of the prompt-based privilege model, not a bug to fix
in v1.

v1 ships this as best-effort: it works whenever the machine is attended
(e.g. lid open, running on battery). The README states this limitation
plainly. A documented v2 path — a privileged helper daemon via
`SMAppService` + XPC — removes the need for a prompt at auto-off time and is
left open since the app is already being signed.

## 5. Privilege Model

Every privileged action (`pmset -a disablesleep 1` and `... 0`) goes through
`osascript ... with administrator privileges`, producing the standard macOS
admin authentication dialog per action. No sudoers modification, no
privileged helper daemon, nothing installed outside the `.app` bundle
itself. This is the same approach AwakeToggle uses and keeps the app's
footprint minimal and fully removable by deleting the `.app`.

## 6. Packaging & Distribution

- Build tooling: a `justfile` with targets to build a universal binary
  (`aarch64-apple-darwin` + `x86_64-apple-darwin`, combined with `lipo`),
  assemble the `.app` bundle (`Info.plist` with `LSUIElement=true` so no
  Dock icon/menu bar app switcher entry appears, bundle id
  `au.com.workwireless.keepy-uppy`), `codesign` with a Developer ID
  certificate and hardened runtime, then `notarytool submit` + `stapler
  staple`, and finally wrap the result in a DMG.
- App icon: a balloon `.icns`, generated for v1, replaceable with proper art
  later.
- No auto-updater in v1. Releases are distributed via GitHub Releases.

## 7. Error Handling

- Admin dialog canceled by the user → silent no-op, no error UI.
- `pmset` output that fails to parse (e.g. a future macOS output format
  change) → icon shows a distinct "unknown state" badge; toggle action
  remains available (we just can't confirm current state); parse failures
  are logged via `os_log`.
- Every state-changing action is followed by a re-read and re-render from
  actual system state — the icon is never derived from an assumption about
  what a command did.

## 8. Testing

- **Unit tests** in `power.rs`: parsing of `pmset -g` and `pmset -g batt`
  output, using real captured fixture strings plus deliberately malformed
  input to exercise the "unknown state" path.
- **Manual test checklist** (maintained in the repo) covering UI paths that
  aren't practical to automate: toggle on/off, canceling the admin dialog,
  external `pmset` change syncing the icon within 30s, launch-at-login
  round-trip (register/unregister via `SMAppService`), quit-restores-sleep,
  and low-battery auto-off (verified in a debug build with a lowered
  threshold for practicality).
- AppKit UI itself is not unit-tested; the logic/UI module boundary in §2
  exists specifically so everything that reasonably can be tested, is.

## 9. Out of Scope for v1

- Privileged helper daemon / XPC (documented v2 path for bulletproof
  unattended auto-off).
- Auto-updater.
- Custom automation triggers (external display, specific app running, etc.
  — the kind of thing Amphetamine offers). Keepy Uppy is deliberately a
  single-purpose toggle, not a general "keep awake" utility.
- Windows/Linux support — macOS-only by design (`pmset`, AppKit, and
  `SMAppService` are all macOS-specific).
