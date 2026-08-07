# Keepy Uppy

![Two laptops playing keepy-uppy with a red balloon](assets/keepy-uppy.png)

Keeps a MacBook awake with the lid closed by toggling `pmset -a disablesleep`
through a menu-bar balloon icon. See
`docs/superpowers/specs/2026-08-06-keepy-uppy-swift-design.md` for the full
design rationale (and `2026-08-06-keepy-uppy-design.md` for the original
Rust/objc2 design this superseded).

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
- [ ] Daemon and agent both register and appear as "Keepy Uppy" in Login Items
- [ ] Approving once is enough; no later prompts
- [ ] Deleting the app while a session is active restores sleep
- [ ] Killing the agent ends condition-based sessions but not timed ones
- [ ] A Release build refuses XPC connections from an unsigned binary
- [ ] A non-agent client's condition report is rejected and logged

## Known limitation

Low-battery auto-off needs a password/Touch ID prompt to re-enable sleep,
same as every other state change (see spec §5's privilege model). If the
lid is closed and the Mac is unattended, that prompt has nobody to answer
it, so auto-off can't complete in exactly the scenario it exists for. It
works whenever the machine is attended. A future privileged-helper-daemon
version (SMAppService + XPC) would remove this gap — see spec §4 and §9.
