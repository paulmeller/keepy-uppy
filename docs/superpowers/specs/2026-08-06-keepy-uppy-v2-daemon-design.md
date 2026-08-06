# Keepy Uppy v2 — Daemon, Sessions, Triggers, Safety — Design

**Date:** 2026-08-06
**Status:** Approved
**Builds on:** `2026-08-06-keepy-uppy-swift-design.md` (v1, shipped). This
document describes only what v2 changes; anything not mentioned here carries
over from v1 unchanged.

v2 has three parts, deliberately shipped as one release but sequenced in the
implementation plan so the privileged daemon lands and passes its security
review on a clean diff before the UI-heavy work builds on top:

1. **The helper daemon** (§1–§9) — replaces v1's per-action admin prompt.
2. **Sessions and triggers** (§10–§12) — the feature gap against every
   competitor.
3. **Automated safety** (§13) — the differentiator none of them have.

## 1. Why

v1's privilege model — `osascript … with administrator privileges` per
action — produced three defects that share one root cause:

1. The authentication dialog is attributed to `osascript`, not Keepy Uppy,
   because `osascript` is the process requesting authorization. For a
   distributed app this reads as a phishing prompt.
2. Every single toggle prompts. The app's primary action carries a password
   tax.
3. **Low-battery auto-off does not work when it matters.** It needs a prompt
   answered, and its entire reason for existing is the unattended
   lid-closed-in-a-bag scenario. v1 documented this as a known limitation
   (v1 spec §4); v2 exists largely to remove it.

There is a fourth, worse problem v1 did not identify: `disablesleep`
persists across reboots and outlives the app. If a user enables Keepy Uppy
and later deletes the app, their Mac never sleeps again with no visible
cause, and they will blame macOS rather than a utility they removed.

v2 replaces the privilege model with a root helper daemon, which fixes all
four. Both required APIs — `SMAppService.daemon(plistName:)` and
`NSXPCConnection.setCodeSigningRequirement` — are available at macOS 13.0,
verified in the SDK, so the deployment floor does not move.

## 2. Prerequisite: signing is now required for development

v1 could be built and exercised end-to-end with ad-hoc signing
(`CODE_SIGN_IDENTITY=-`) and no Apple account. v2 cannot: `SMAppService`
daemon registration requires a properly signed app. Unit tests and builds
still run unsigned, but any verification past the XPC handshake requires at
minimum a development certificate, and distribution requires the Developer
ID already planned in v1 §6.

## 3. Bundle layout and targets

Three build targets replace v1's two:

- **`Keepy Uppy`** — the menu-bar app (unprivileged, as before).
- **`KeepyUppyHelper`** — new. A root LaunchDaemon executable embedded at
  `Contents/MacOS/KeepyUppyHelper`.
- **`keepy-uppy`** — new. A small signed CLI at `Contents/MacOS/keepy-uppy`,
  which drives the daemon over the same XPC connection the app uses. It
  exists so remote control (§9) works without any further Mac-side work.
- **`Keepy UppyTests`** — unchanged in role.

The daemon's launchd plist ships at
`Contents/Library/LaunchDaemons/au.com.workwireless.keepy-uppy.helper.plist`,
declaring its `MachServices` entry and `AssociatedBundleIdentifiers`
(`au.com.workwireless.keepy-uppy`) so it appears as "Keepy Uppy" in Login
Items rather than as an anonymous background item.

The XPC protocol declaration is compiled into the app, helper, and CLI
targets as shared source. This is deliberately not an embedded framework —
a framework would add a second signed artifact and its own versioning
problem for the sake of one small file.

## 4. The XPC contract

```swift
@objc protocol HelperProtocol {
    func requestKeepAwake(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)
}
```

`requestKeepAwake` registers *this client's* desire, not a global set — see
the state machine in §6. The reply carries success plus an optional error
message.

## 5. Security: the signing requirement

This is the most important decision in v2. A root daemon that changes system
power settings on request is a local privilege-escalation vector unless it
verifies who is calling.

Both ends pin the connection with `setCodeSigningRequirement` before
`resume` (it is an XPC error to set it twice):

- The **helper** accepts connections only from binaries signed by our Team
  ID whose identifier begins with `au.com.workwireless.keepy-uppy`.
- The **app and CLI** likewise require the helper to match, so a planted
  binary cannot impersonate the daemon.

The requirement is deliberately scoped to a **Team ID plus bundle-identifier
prefix**, not a single exact identifier. This admits the app, the CLI, and
any future companion — all of which must still be signed with our key, so
the property that actually matters (an attacker needs our signing identity)
is unchanged. Pinning to one exact identifier would have to be loosened
later, and loosening a security boundary after the fact is exactly when
mistakes get made.

**Development asymmetry, and its risk:** ad-hoc builds have no Team ID, so
the requirement cannot be satisfied locally. Enforcement is therefore
compiled out under `#if DEBUG` with a prominent log line on every
connection, and enforced unconditionally in Release. A build that silently
skipped verification would be far worse than one that refuses to run, so the
DEBUG path must be loud, and this asymmetry gets a dedicated security review
pass before merge (§11).

## 6. The dead man's switch

The helper holds a table mapping each connected client to whether that
client currently wants the Mac kept awake. The desired system state is
simply: **any client wants it**.

Sleep is re-enabled whenever the last request drops. That covers the
explicit toggle-off, the app quitting, the app crashing, the app being
force-killed, the user logging out, and the app being deleted — because all
of them invalidate the XPC connection, and connection invalidation removes
that client from the table.

The helper additionally forces sleep **on** at its own startup, before
accepting any connection. A helper crash therefore converges to the safe
state rather than leaving the setting stranded, and the same behavior
rescues anyone upgrading from v1 with `disablesleep` left set.

Consequences, both intended:

- Keeping a lid-closed session alive requires the app to keep running. This
  was already true in practice in v1.
- Quitting restores sleep, exactly as v1 — but now with no password prompt,
  because the daemon needs none.

## 7. Reads and writes go native

The helper performs the privileged write with `IOPMSetSystemPowerSetting`,
the same IOKit call `pmset` itself makes, rather than spawning `pmset` as
root. Rationale: a root daemon that never spawns a subprocess is materially
easier to reason about, and it removes an argument-and-environment surface
from the most sensitive process in the system.

The trade-off is explicit: `IOPMSetSystemPowerSetting` and
`IOPMCopySystemPowerSettings` are exported from IOKit but declared in no
public header — they are SPI. We accept that, isolated behind a single small
Swift file with hand-declared prototypes, so that if Apple ever changes it
there is exactly one place to fix. (App Store review would reject this;
Developer ID distribution, which is our channel, does not.)

Battery state moves to `IOPSCopyPowerSourcesInfo` /
`IOPSGetPowerSourceDescription`, which are fully public API.

Both `pmset` text parsers are deleted. Notably, v1's `pmset -g` output on a
real test machine used **tab** separators, which the original pre-review
parser would have misread as "sleep enabled" while sleep was actually
disabled; removing text parsing removes that whole class of fragility.

The app no longer reads sleep state itself at all — the helper is the single
source of truth, queried over XPC.

## 8. Settings

All monitoring stays in the app: the dead man's switch means the app is
necessarily running whenever sleep is disabled, so it is always present to
observe conditions, and dropping a keep-awake request needs no prompt.

A SwiftUI `Settings` scene (⌘,) holds preferences across three tabs:

- **General** — Launch at Login, default session type for the quick toggle.
- **Safety** — every guard in §13, each independently configurable.
- **Triggers** — the rule list from §12.

Implementation note: an `LSUIElement` app must call `NSApp.activate` when
opening Settings, or the window opens behind every other window.

## 9. Approval and registration UX

On the first toggle with the helper unregistered, the app calls
`SMAppService.daemon(plistName:).register()`. If status returns
`.requiresApproval`, the menu shows an explanatory item and offers
`SMAppService.openSystemSettingsLoginItems()` (verified available at macOS
13), which deep-links to the approval pane rather than leaving the user to
find it.

**Version skew:** on every connect the app calls `version()` and re-registers
the helper if it does not match the app's own version. Without this, an app
updated by any mechanism keeps talking to the previously installed daemon.

## 10. Sessions — the core model

Every keep-awake in v2 is a **session**: a request plus an end condition.
The app holds a set of active sessions and asserts the XPC keep-awake
request while at least one is alive. Multiple concurrent sessions are
supported and union naturally — "while Xcode runs" *and* "until 5pm" keeps
the Mac awake until both have ended.

This is the whole architecture of the feature. It composes with the dead
man's switch for free: sessions live in memory, so quitting or crashing the
app ends every session and restores sleep, with no separate teardown path.

Session kinds:

| Kind | Ends when |
|---|---|
| Indefinite | user stops it, or a safety guard fires |
| Duration | a wall-clock deadline passes (15m / 30m / 1h / 2h / 4h / custom) |
| Until time | a specified time of day arrives |
| While app running | the named app terminates |
| While external display connected | the display is disconnected |
| While on AC power | the power adapter is unplugged |
| While CPU busy | load stays below a threshold for a sustained period |

**Deadlines are absolute `Date`s, never countdowns**, so clock changes and
scheduler drift cannot extend a session past its intended end.

Implementation of the conditions uses public API throughout, all verified
present: `NSWorkspaceDidTerminateApplicationNotification` and
`NSWorkspace.runningApplications` for app tracking;
`NSApplicationDidChangeScreenParametersNotification` for displays;
`IOPSCopyPowerSourcesInfo` (already in use for the battery guard) for AC
power; and `host_statistics64` CPU load sampling for the CPU condition.

**CPU-busy needs hysteresis and is the least reliable kind.** A momentary
lull mid-job would otherwise end the session. It ends only after load has
stayed below the threshold for a sustained window (default 2 minutes), and
the UI says so, because a session type that ends unpredictably is worse than
no session type at all.

## 11. Session UI

The menu becomes: current status with **time or condition remaining** for
each active session, a "Start session" submenu covering the kinds above, a
stop control per session, "Settings…", and "Quit Keepy Uppy". Remaining time
refreshes on a one-minute tick and on menu open — not per second, which
would republish the menu pointlessly.

Starting a "while app running" session offers the currently running
applications; starting "until time" offers a time picker.

## 12. Triggers — automatic session start

A **trigger** is a rule: when a condition becomes true, start a session of a
given kind automatically. Triggers are what the app watches while otherwise
idle, and they are the inverse of §10's end conditions rather than the same
mechanism.

Available trigger conditions mirror the observable ones: a named app
launches, an external display is connected, AC power is connected, or CPU
load rises above a threshold. Each rule specifies which session kind to
start, and sessions started by a trigger are tagged as such in the UI so it
is always visible *why* the Mac is being kept awake.

Rules are managed in the Settings → Triggers tab and stored in
`UserDefaults`. Triggers are off by default; an app that starts keeping your
Mac awake without being asked is a bug, not a feature, unless the user
configured it.

**Triggers must not fight the user, and must not fight safety** — see §13.

## 13. Automated safety

The safety guards are the reason to prefer this app over its competitors,
and they exist because the honest failure mode of every tool in this
category is a hot laptop flattening its battery in a closed bag. All guards
are independently configurable in Settings → Safety, and all are on by
default.

**Thermal guard.** `ProcessInfo.processInfo.thermalState` is public API
(macOS 10.10.3+, verified) with
`NSProcessInfoThermalStateDidChangeNotification`. At `.serious` or
`.critical`, all sessions end and the Mac is allowed to sleep. This directly
answers the warning both reference articles raise, and no competitor appears
to implement it.

**Low-battery cutoff.** As in v1 but now genuinely working unattended, and
user-configurable: Off / 5% / 10% / 15% / 20%, default 10%.

**Maximum session duration backstop.** A global ceiling (default 8 hours,
configurable) that ends even indefinite sessions, so "I forgot it was on"
cannot become an overnight drain.

**Lid-closed awareness.** `AppleClamshellState` is readable from
`IOPMrootDomain` via `IORegistryEntryCreateCFProperty` (verified working on
a real machine). When the lid is actually shut — the genuinely dangerous
configuration, with no way to dump heat — the thermal and battery thresholds
tighten. With the lid open and the machine breathing, they stay permissive.

**Warn-then-act grace period.** A notification fires roughly 60 seconds
before a guard ends a session, so an attended user can intervene and keep it
alive. **Skipped entirely when the lid is closed**, because nobody would see
it and delaying a thermal stop to show an invisible warning is precisely
backwards.

### Safety must suppress triggers

This is the subtle interaction, and getting it wrong produces an app that
fights its user: a thermal stop ends a session, the "external display
connected" trigger observes a still-true condition, and immediately restarts
it — forever.

After any safety-initiated stop, trigger-driven starts are suppressed until
the triggering safety condition has cleared **with hysteresis** — thermal
back to `.nominal`, or battery recovered several points above the cutoff —
and never sooner than a minimum cooldown. Manual starts are always honoured;
the user overriding a guard deliberately is their prerogative, and is
logged. Safety never suppresses a manual start, and triggers never override
safety.

## 14. Remote control — explicitly out of scope, deliberately enabled

v2 does not implement phone control. It does two cheap things that make it
possible later without redesign: the widened signing requirement (§5) and
the signed `keepy-uppy` CLI (§3).

Together those mean an iOS Shortcut can drive the Mac over SSH on day one
with no further Mac-side code — a Home Screen icon, Control Center button,
Action Button binding, or NFC-tag automation, all with no iOS app and no App
Store involvement.

Two documented future paths, in preference order:

- **v3 (recommended): iCloud Drive state sync.** A Shortcut writes desired
  state as JSON to iCloud Drive; the app watches the file and converges.
  Designed as *desired state with a timestamp*, never as commands, so that
  delayed, duplicated, or reordered syncs are all harmless and stale
  requests cannot resurrect an old session. The app writes its actual state
  back to the same file so a Shortcut can report status. Adds no listener,
  no token, no TLS, and no attack surface.
- **v4 (only if a dashboard is wanted): a local web app.** Served from the
  app — never the daemon, so it holds no privileges and merely makes the
  same XPC request the menu does — bound to a Tailscale interface behind a
  bearer token.

A native iOS widget or Control Center control is possible but requires a
containing app and App Store distribution, and is worth building only if a
glance without opening anything proves to be the point. App Clips are
unsuitable: they require a published parent app, cannot contain widgets, and
are evicted after disuse.

## 15. Testing

Almost all of v2's new complexity is pure logic over inputs, and is designed
that way specifically so it can be tested without hardware, without root,
and without waiting for real time to pass.

- **The session engine** is a pure reducer: `(current sessions, event, now)
  → (new sessions, desired keep-awake)`. Every session kind's lifecycle,
  multi-session union, and expiry are tested by feeding synthetic events and
  an injected clock. **Time is always injected, never read from
  `Date()` inside the engine**, so a four-hour session is tested instantly.
- **The safety engine** is likewise pure: `(thermal, battery, lid, session
  ages, config) → (stops, warnings, trigger suppression)`. The
  suppression-and-hysteresis rules from §13 get explicit tests for the
  fight-the-user loop — safety stop followed by a still-true trigger
  condition must not restart the session.
- **The helper's client table** reducer, as before, including
  last-client-disconnects and helper-restart transitions.
- **Condition observers** (`NSWorkspace`, screen parameters, IOKit power,
  CPU sampling, thermal, clamshell) sit behind protocols so the engines see
  values, not frameworks. The thin observer implementations are verified
  manually rather than unit tested.
- **The XPC handshake, daemon registration, and approval flow** require a
  signed build and manual verification; they join v1's interactive items in
  the README checklist.
- **A dedicated security review** of the XPC boundary before merge, separate
  from the per-task gates: the signing requirement string on both ends, the
  DEBUG enforcement asymmetry (§5), and the privilege boundary between app
  and helper.

## 16. Out of scope for v2

- Phone control of any kind (§14 documents the enabled paths).
- Auto-updates (Sparkle) — still deferred, but version skew handling (§9)
  is what will make it safe when it arrives.
- "While a file is downloading" as a session kind. Amphetamine has it;
  reliable detection is fragile (browser-specific partial-file conventions,
  no general API) and a session type that ends at the wrong moment is worse
  than an absent one. Revisit only with a concrete, reliable mechanism.
- Per-session persistence across app restarts, which would contradict the
  dead man's switch (§6). Sessions are in-memory by design.
