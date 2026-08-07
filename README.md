# Keepy Uppy

![Two laptops playing keepy-uppy with a red balloon](assets/keepy-uppy.png)

Keeps a MacBook awake with the lid closed. Keepy Uppy is headless-first and
fully usable without a GUI: four executables work together—`KeepyUppyHelper`
(root daemon), `KeepyUppyAgent` (per-user agent), `keepy-uppy` (CLI client),
and `Keepy Uppy.app` (optional menu-bar UI). The daemon and agent can be
registered via CLI (`keepy-uppy setup`), or the app self-onboards via Settings
→ General → "Enable Keepy Uppy". Control via CLI (`on`/`off`/`status`/`sessions`,
including over SSH), or via the menu-bar app which shows the session list and
Settings tabs for General, Safety, and Triggers. See "How it works" below for
the architecture, `docs/superpowers/specs/2026-08-06-keepy-uppy-swift-design.md`
for the v2 design rationale, and `docs/superpowers/specs/2026-08-06-keepy-uppy-design.md`
for the original Rust/objc2 design this superseded.

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

See `docs/superpowers/specs/2026-08-06-keepy-uppy-v2-headless-design.md` for
the full architecture this section summarises.

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

## Prerequisites

- Xcode + Xcode Command Line Tools
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [`just`](https://github.com/casey/just): `brew install just`
- A Developer ID Application certificate in your login keychain (for `just archive`)
- A notarytool keychain profile: `xcrun notarytool store-credentials` (for `just notarize`)

## Build and run (development)

    just run       # build Debug and launch
    just test      # run the unit tests
    just generate  # regenerate the Xcode project after adding/removing files

## Build the distributable app

    export KEEPY_UPPY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    export KEEPY_UPPY_TEAM_ID="TEAMID"
    export KEEPY_UPPY_NOTARY_PROFILE="your-notarytool-profile-name"
    just notarize   # signed, notarized, stapled .dmg in build/

## Manual test checklist

Run through this after any change to `PowerMonitor.swift`, `PowerService.swift`,
`LoginItemService.swift`, `MenuContent.swift`, `SettingsView.swift`,
`AppDelegate.swift`, or any daemon/agent code:

**Menu-bar app basics:**
- [ ] Clicking the icon (left or right click, both open the same menu) shows correct status text, toggle wording, and login-item checkbox state
- [ ] The app has no Dock icon and shows the balloon in the menu bar
- [ ] The app's Finder/Get Info icon shows the balloon
- [ ] The exported, notarized `.app` opens without Gatekeeper warnings
- [ ] "Launch at Login" registers/unregisters and is reflected in System Settings → General → Login Items

**Settings → General (onboarding & enablement):**
- [ ] Fresh install: open the app, Settings → General shows "Not enabled"; clicking "Enable Keepy Uppy" registers both background items and, if approval is needed, opens System Settings to the right pane
- [ ] After approval, Settings → General shows "Running" without needing to reopen the app
- [ ] Daemon and agent both register and appear as "Keepy Uppy" in Login Items
- [ ] Approving once is enough; no later prompts

**Settings → Safety:**
- [ ] Settings → Safety: lowering the battery cutoff and confirming (via `keepy-uppy status`) the daemon picks it up within ~5s without restarting anything

**Settings → Triggers:**
- [ ] Settings → Triggers: adding an "App Launched" rule for a real installed app, launching it, confirming a session starts automatically and is tagged "Started automatically" in the menu; quitting that app ends the session within ~5s
- [ ] A trigger does not fire again while its session is still active (leave the triggering app running, confirm no duplicate session appears)
- [ ] Triggering a real safety stop (or lowering the thermal sensitivity to `cautious` under load) suppresses a trigger from firing again until the configured cooldown elapses, while a manual "Start…" click still works immediately

**Menu-bar app session control:**
- [ ] Menu "Start… → Indefinitely" keeps the Mac awake with the lid closed; quitting the app ends that session (clientBound) and sleep resumes
- [ ] A session started via `keepy-uppy on --for 2h` (detached) is NOT ended by quitting the menu-bar app, and appears in the menu's session list with the right remaining time
- [ ] Quitting the app while it owns an active session ends that session (no prompt); sessions owned by other clients (CLI, other logins) are left running

**CLI and daemon/agent behavior:**
- [ ] `keepy-uppy setup` registers both background items; approving once is enough
- [ ] `keepy-uppy on --for 30s` starts a session that ends on its own after 30 seconds
- [ ] `keepy-uppy on --while-app <bundle id>` ends within ~5s of quitting that app
- [ ] External `sudo pmset -a disablesleep 1/0` is reflected in the icon within 30 seconds
- [ ] Killing the agent process (Activity Monitor) does not end `--for`/indefinite sessions, but does end `--while-app` ones
- [ ] Deleting the app while a session is active restores sleep
- [ ] Two terminals opening 25 sessions each are individually capped at 20 and rate-limited within each connection

**Safety guards:**
- [x] A Release build refuses XPC connections from an unsigned binary
- [x] A non-agent client's condition report is rejected and logged
- [ ] The thermal guard stops a session at the configured sensitivity (default Balanced), and the same trigger does not immediately restart it (cooldown/hysteresis, spec §7)
- [ ] The maximum-duration backstop ends even an indefinite session
- [ ] Thermal and battery thresholds tighten when the lid is closed and the warn-then-act grace period is skipped, since there's nobody to see the warning
- [ ] Low-battery auto-off re-enables sleep and posts a notification when tested with a lowered threshold — completes unattended, with no prompt, including with the lid closed

## Verification status

**Plan 1 (Daemon core, Unit tests):**
The daemon's session and safety engines are covered by the unit suite (91/91).
On 7 August 2026, a hardened Release archive signed with the WorkWireless
Apple Development identity was also exercised as a running system:

- `SMAppService` registered the daemon, which launched as root with both Mach
  services active.
- A correctly signed CLI-role probe completed the version, state, session
  start/list/stop, and sleep-restoration flow over XPC. Server-owned session
  fields were replaced as designed.
- An ad-hoc client was rejected by the Release signing requirement, and the
  CLI-role probe was rejected from the agent-only condition-report method.
- Moving the app bundle away caused the daemon to restore normal sleep and
  exit successfully on its next self-check; restoring the bundle allowed an
  XPC request to launch it again.

**Plan 2 (Headless daemon/agent, CLI):**
The CLI is fully implemented and verified. The per-user agent watches for
app launches and closed displays to trigger condition-based sessions. Both
the daemon and agent register as background items via `keepy-uppy setup` or
via the menu-bar app's Settings → General → "Enable Keepy Uppy". The CLI
implements `setup`, `on`, `off`, `status`, and `sessions` and works over SSH
with no UI needed.

**Plan 3 (Menu-bar UI):**
The menu-bar app (`Keepy Uppy.app`) displays the active session list and
provides three Settings tabs:
- **General:** shows enablement status, button to register daemon/agent,
  "Launch at Login" checkbox
- **Safety:** configure battery cutoff and thermal sensitivity thresholds
- **Triggers:** add/edit/remove rules to start sessions automatically when
  specified apps launch

Outstanding verification:
- Distribution signing and notarization: this machine does not currently have
  a Developer ID Application certificate or a stored `notarytool` profile.
- Hardware checks for actual closed-lid wake behaviour and the thermal/battery
  guards remain unverified on real hardware.
