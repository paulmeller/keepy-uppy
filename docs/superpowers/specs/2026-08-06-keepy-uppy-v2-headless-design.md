# Keepy Uppy v2 — Headless-First Architecture — Design

**Date:** 2026-08-06
**Status:** Approved
**Builds on:** `2026-08-06-keepy-uppy-swift-design.md` (v1, shipped). Anything
not mentioned here carries over from v1 unchanged.

**Supersedes** this document's own first draft, which treated the menu-bar app
as the product and the helper daemon as its privileged appendage. That shape
had a defect which only became visible once the CLI was specified: a session
held open by an XPC connection cannot survive its client exiting, so
`keepy-uppy on` would have enabled keep-awake and immediately disabled it
again on process exit. What follows fixes that class of problem rather than
patching the symptom.

## 1. What changed and why

Keepy Uppy is a **headless-first** product: a root daemon plus a per-user
agent deliver every guarantee between them, and the menu-bar UI is optional —
though in practice most users will treat it as the main interface. The UI is a
view onto the system, never the system itself.

Three consequences drive the whole design:

1. **Safety must live in the daemon.** If the thermal, battery, duration, and
   clamshell guards lived in the UI, a headless install would be a root daemon
   keeping a laptop awake in a closed bag with no guard at all — exactly
   inverting the feature this product is differentiated on. Safety belongs in
   the only component guaranteed to be running.
2. **A root daemon cannot observe a login session.** `NSWorkspace` and display
   configuration are per-session. Anything watching running apps or displays
   must live in a per-user agent, which is why the agent is its own component
   rather than folded into the UI.
3. **Sessions cannot be tied to connections.** A CLI invocation exits
   immediately and a UI can be quit; neither should silently destroy or
   silently orphan a session. Lifetime is governed by evidence, not sockets
   (§5).

The accepted cost of (1) is more logic running as root. It is mitigated by
keeping the safety engine a **pure reducer with no I/O of its own** (§7), so
privileged code stays small, deterministic, and heavily unit-tested.

## 2. Components

One signed bundle, four executables:

```
Keepy Uppy.app/Contents/
  MacOS/Keepy Uppy          — optional menu-bar UI
  MacOS/KeepyUppyHelper     — root LaunchDaemon    (SMAppService.daemon)
  MacOS/KeepyUppyAgent      — per-user LaunchAgent (SMAppService.agent), no UI
  MacOS/keepy-uppy          — CLI
  Library/LaunchDaemons/au.com.workwireless.keepy-uppy.helper.plist
  Library/LaunchAgents/au.com.workwireless.keepy-uppy.agent.plist
```

`SMAppService.daemon(plistName:)` and `SMAppService.agent(plistName:)` are
both available at macOS 13.0, verified in the SDK. The deployment floor does
not move.

The topology is a star with the daemon at the centre. Agent, UI, and CLI are
all XPC clients of the daemon; they never talk to each other.

**Daemon (root)** — the authority. Owns the privileged IOKit write, the
session table, time-based end conditions, lease expiry, every safety guard,
and a periodic check that its own bundle still exists (§6).

**Agent (per-user, no UI)** — the sensor. Observes user-session conditions
(running applications, display configuration), evaluates trigger rules, and
reports to the daemon. Runs whether or not the UI is ever launched, which is
what makes condition-based sessions work headlessly.

**UI (optional)** — pure view and controller. Displays sessions, starts and
stops them, hosts Settings. Owns no authoritative state.

**CLI** — a full client. Can do anything the UI can, including starting
condition-based sessions: the daemon records the condition, the agent
evaluates it.

## 3. Identifiers

| Component | Bundle identifier |
|---|---|
| App | `au.com.workwireless.keepy-uppy` |
| Daemon | `au.com.workwireless.keepy-uppy.helper` |
| Agent | `au.com.workwireless.keepy-uppy.agent` |
| CLI | `au.com.workwireless.keepy-uppy.cli` |

The daemon's Mach service is `au.com.workwireless.keepy-uppy.helper`.

## 4. Security

Both ends of every XPC connection pin with `setCodeSigningRequirement`
(macOS 13+, verified) before `resume`:

```
anchor apple generic
  and certificate leaf[subject.OU] = "<TEAM_ID>"
  and identifier = "au.com.workwireless.keepy-uppy*"
```

The Team ID plus bundle-prefix scoping — chosen in the first draft precisely
so a boundary would never need widening later — admits the new agent with no
change at all. Grammar verified with `csreq`; runtime matching needs a signed
build and is human-verified.

Bundle identifiers distinguish **role**, not authorisation: only the agent may
report condition observations, and the daemon ignores observation messages
from anything else. Every client is equally entitled to start and stop its own
sessions.

**Development asymmetry.** Ad-hoc builds have no Team ID, so enforcement is
compiled out under `#if DEBUG` with a loud `os.Logger` error on every
connection. A build that silently skipped verification would be far worse than
one that refuses to run. This asymmetry gets a dedicated security review
before merge (§10).

## 5. The session model

A **session** is a request to keep the Mac awake plus the evidence it should
continue. The daemon holds the authoritative table; sleep is disabled while at
least one session is alive.

Each session records:

- **Kind / end condition** — see below.
- **Owner** — the client that created it.
- **Persistence** — `clientBound` (ends when the owner disconnects) or
  `detached` (survives the owner exiting, still bounded by its end condition
  and the max-duration backstop).
- **Origin** — manual or trigger-started, so the UI can always show *why* the
  Mac is being kept awake.

Defaults follow least-surprise per client: **UI sessions are `clientBound`**,
so quitting the menu-bar app cleans up what you started there; **CLI sessions
are `detached`**, so `keepy-uppy on --for 2h` behaves as anyone would expect
over SSH.

### Kinds

| Kind | Ends when | Evaluated by |
|---|---|---|
| Indefinite | stopped, or the max-duration backstop fires | daemon |
| Duration | a wall-clock deadline passes | daemon |
| Until time | a specified time of day arrives | daemon |
| Lease | the lease expires unless renewed | daemon |
| While app running | the named app terminates | agent |
| While external display connected | the display disconnects | agent |
| While on AC power | the adapter is unplugged | daemon |
| While CPU busy | load stays below threshold for a sustained window | agent |

Deadlines are absolute `Date`s, never countdowns, so clock changes cannot
extend a session. CPU-busy ends only after a sustained quiet window (default
2 minutes) — a momentary lull mid-job must not kill the session, and a kind
that ends unpredictably is worse than one that does not exist.

### The governing rule: no session outlives its evidence

This replaces the first draft's connection-bound dead man's switch and is
strictly more general:

- A **time-based** session ends on its own clock.
- A **condition-based** session ends when the condition ends — **or when the
  agent observing it disappears.** If the evidence cannot be verified, the
  session stops. Fail safe.
- An **indefinite** session is bounded by the max-duration backstop.
- A **`clientBound`** session ends when its owner disconnects.
- **Any** session ends when a safety guard fires (§7).

The daemon also forces sleep enabled at its own startup, before accepting
connections, so a daemon crash converges to safe — which additionally rescues
anyone upgrading from v1, where `disablesleep` persisted across reboots.

## 6. Bundle self-check

Deleting the app must not strand the Mac awake. The daemon periodically
verifies its own bundle still exists on disk; if it does not, it restores
sleep and exits. Belt-and-braces alongside macOS's own handling of registered
services whose bundle has vanished.

## 7. Safety

All guards live in the daemon, all are independently configurable, all default
on. The engine is a **pure reducer** — `(thermal, battery, lid, session ages,
config) → (stops, warnings, trigger suppression)` — with observation and
actuation outside it, so root-side logic is fully unit-testable from synthetic
inputs.

- **Thermal.** `ProcessInfo.processInfo.thermalState` (public, verified) with
  `NSProcessInfoThermalStateDidChangeNotification`. At `.serious` or
  `.critical`, all sessions end. This answers the "a Mac running in a closed
  bag has nowhere to dump heat" warning that no competitor addresses.
- **Low battery.** Configurable cutoff (Off / 5 / 10 / 15 / 20%, default 10%)
  via the public `IOPSCopyPowerSourcesInfo` API.
- **Maximum duration backstop.** A global ceiling (default 8 hours) ending
  even indefinite sessions.
- **Lid-closed awareness.** `AppleClamshellState` from `IOPMrootDomain` via
  `IORegistryEntryCreateCFProperty` (verified on real hardware). Thermal and
  battery thresholds tighten when the lid is genuinely shut and the machine
  cannot breathe; they stay permissive when it is open.
- **Warn-then-act grace period.** Roughly 60 seconds' notice before a guard
  ends a session so an attended user can intervene — **skipped entirely when
  the lid is closed**, because nobody would see it and delaying a thermal stop
  for an invisible warning is backwards.

Every input above is readable from a root daemon, which is what makes putting
safety there possible at all.

### Safety suppresses triggers

Getting this wrong produces an app that fights its user: a thermal stop ends a
session, the still-connected external display re-triggers it, forever.

After any safety-initiated stop, trigger-driven starts are suppressed until
the triggering condition clears **with hysteresis** (thermal back to
`.nominal`; battery recovered several points above the cutoff) and never
before a minimum cooldown. Manual starts are always honoured and logged — a
user deliberately overriding a guard is their prerogative. Triggers never
override safety.

## 8. Triggers

A trigger is a rule: when a condition becomes true, start a session of a given
kind. Triggers are evaluated by the **agent** (they depend on user-session
conditions), stored in `UserDefaults`, managed in Settings, and **off by
default** — an app that starts keeping your Mac awake unasked is a bug, not a
feature. Trigger-started sessions are tagged so the UI can always explain
itself.

## 9. Interfaces

**CLI** — the headless surface, and the reason the Shortcuts/SSH path works
with no further Mac-side code:

```
keepy-uppy on [--for DURATION | --until TIME | --while-app NAME]
keepy-uppy off [--all | --session ID]
keepy-uppy status [--json]
keepy-uppy sessions
```

`--json` exists so scripts and the future iCloud/web layers consume state
without parsing prose.

**UI** — the menu shows each active session with its remaining time or
condition and why it started, plus a start-session submenu, per-session stop,
Settings, and Quit. Settings has three tabs: General (launch at login, default
session kind), Safety (every guard in §7), Triggers (the §8 rule list). An
`LSUIElement` app must call `NSApp.activate` when opening Settings, or the
window appears behind everything.

**Remote control** stays out of scope but is deliberately enabled: the CLI
plus the widened signing requirement mean an iOS Shortcut over SSH works on
day one — Home Screen icon, Control Centre, Action Button, or NFC tag, with no
iOS app. Documented future paths in preference order: iCloud Drive
desired-state sync (a Shortcut writes JSON, the agent converges; timestamped
so stale requests cannot resurrect a session), then a local web dashboard
served by the agent — never the daemon — behind a Tailscale interface and a
bearer token.

## 10. Testing

Nearly all new complexity is pure logic over injected inputs, deliberately so:

- **Session engine** — `(sessions, event, now) → (sessions, desired)`, with
  time always injected and never read inside the engine, so an eight-hour
  session is tested instantly. Covers every kind, multi-session union,
  owner-disconnect, detached survival, and the agent-disappearance fail-safe.
- **Safety engine** — every guard, the hysteresis and suppression rules, and
  an explicit regression test for the fight-the-user loop.
- **Session table** — the v1 client-table reducer generalised; removing the
  last session must restore sleep.
- **Observers** (`NSWorkspace`, screen parameters, IOPS, CPU, thermal,
  clamshell) sit behind protocols so engines see values, not frameworks. The
  thin observer implementations are manually verified.
- **Signed-build manual verification** — daemon and agent registration,
  approval, XPC handshake, real runtime signature matching, and the end-to-end
  toggle. Listed in the README checklist; not automatable here.
- **A dedicated security review** of the XPC boundary before merge, separate
  from per-task gates: the requirement string on both ends, the DEBUG
  asymmetry, role enforcement for observation messages, and the privilege
  boundary generally.

## 11. Build order

Plans are cut so the optional component is built last:

1. **Daemon core** — session table, engine, leases, time conditions, safety,
   XPC, security pinning.
2. **Agent + CLI** — condition observation, triggers, full command line. **At
   the end of this plan the headless product is complete and usable.**
3. **Menu-bar UI** — genuinely additive.

Work already completed against the first draft — project structure, IOKit
power layer, client-table reducer, XPC listener, signature pinning — all
carries forward; the client table becomes the basis of the session table.

## 12. Out of scope for v2

- Phone control (§9 documents the enabled paths).
- Auto-updates. Version-skew handling across app, agent, and daemon is in
  scope; Sparkle is not.
- "While a file is downloading" — reliable detection needs browser-specific
  partial-file conventions with no general API, and a kind that ends at the
  wrong moment is worse than an absent one.
- Multi-user arbitration beyond per-user agents; the daemon serves whichever
  users are logged in without refereeing between them.
