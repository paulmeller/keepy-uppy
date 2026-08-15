# Keepy Uppy

![Two laptops playing keepy-uppy with a red balloon](assets/keepy-uppy.png)

**Close the lid. Keep working.**

Your Mac sleeps the moment you shut the screen — and takes your build, your
deploy, your overnight render and your remote session with it. Keepy Uppy stops
that, without leaving your laptop cooking in a bag all night.

```sh
keepy-uppy on --while-process claude    # awake until Claude Code exits
```

Close the lid. Walk away.

---

## Why this one

**It works with the lid shut.** Not "keeps the screen on" — genuinely awake in
clamshell, on battery, with nothing plugged in. That takes a privileged daemon
and a system-level power setting, which is exactly what Keepy Uppy ships.

**It lives in your menu bar.** Drag, click Enable, done — every session, guard
and trigger is one click away, and you never have to open a terminal. Unless
you want to: underneath is a daemon, not an app, so all of it is just as
reachable from a script, from CI, from a Shortcut and over SSH.

**It knows when to stop.** Most keep-awake tools do what you tell them, right
up until your laptop is at 96°C in a backpack with 3% battery. Keepy Uppy has
guards that end sessions when it's overheating, when the battery is running
out, and when a session has simply been running too long — with tighter limits
when the lid is closed, because a closed Mac can't cool itself.

**It ends sessions when the work ends.** Not on a timer you guessed at.

## Built for AI coding agents

Long agent runs are exactly the workload that outlives your attention span. Set
it once and the Mac stays awake precisely as long as the tool does:

| Tool | Keeps awake while running | Fires your hook when done |
|---|---|---|
| Claude Code | ✅ | `SessionEnd` |
| Codex CLI | ✅ | `hooks.json` |
| Pi | ✅ | `session_shutdown` |
| Antigravity (`agy`) | ✅ | `hooks.json` |
| Cursor CLI | ✅ | `sessionEnd` |
| Grok | ✅ | *(no session-end hook upstream yet)* |

One click in Settings → Triggers adds any of them. Or wire a tool's own
completion hook straight into Keepy Uppy for exact task-level precision:

```json
{ "hooks": { "SessionEnd": [{ "hooks": [
  { "type": "command", "command": "keepy-uppy finished --tool claude-code" }
]}]}}
```

Then have it ping you, run a script, or POST a webhook the moment the work
finishes — whether that's a build, an agent run, or an eight-hour render.

## Get started

```sh
brew install --cask paulmeller/tap/keepy-uppy
```

Or grab the notarized `.dmg` from [Releases](../../releases) and drag it to
`/Applications`. Either way: open it and hit **Enable Keepy Uppy**. macOS asks
you to approve the background services once. That's it.

Headless box that'll never run the app? One command, over SSH:

```sh
curl -fsSL https://raw.githubusercontent.com/paulmeller/keepy-uppy/main/packaging/install.sh | bash
```

It downloads the latest release, **checks Gatekeeper's own verdict before
installing anything**, puts it in `/Applications` and registers the services.
It refuses to run under `sudo` — `setup` registers a per-user agent, and one
registered by root belongs to root. macOS asks for an administrator at the
point the daemon is installed, and not before.

Already have the app and just want the services registered:

```sh
"/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" setup
```

To type `keepy-uppy` instead of all that, Settings → CLI & Advanced links it
into `/usr/local/bin`. That directory is root-owned on a stock Mac, so the
button usually can't do it for you — it hands you the one `sudo` command that
can, with the space in "Keepy Uppy.app" already quoted, for you to read and
paste yourself. Every verb works through the link except `setup` and `reset`:
those two have to find the app bundle they were started from, a link on your
`PATH` isn't inside one, and they refuse there rather than report an uninstall
that didn't happen.

## The command line

The daemon is the product, so everything is reachable from a script, from CI,
from a Shortcut and over SSH:

```sh
keepy-uppy on                                # until you say otherwise
keepy-uppy on --for 2h                       # or --until 17:00
keepy-uppy on --while-process claude         # until the process exits
keepy-uppy on --while-schedule 'weekdays 09:00-18:00'
keepy-uppy off                               # stop yours
keepy-uppy status --json                     # {"keepingAwake": true}
```

Ten `--while-…` conditions in all — a process, an app, a display, the charger,
CPU load, a volume, a network, a VPN, a USB device, a recurring schedule — plus
flags for *how* awake (the lid, the screen, attached disks) and a `mode` verb
that changes a running session without restarting it.

**Settings → Triggers** turns any of those conditions into a standing rule, so
the Mac starts keeping itself awake without you asking. **The menu bar** lists
every live session and where each came from.

→ **[Full reference](docs/reference.md)** — every flag, all ten conditions, and
the caveats that matter: which modes survive a lid close, what `--while-vpn`
cannot see, and why network shares can't be covered.

## Safety, in detail

Configurable in Settings → Safety & Guards, and enforced by the daemon
regardless of which client asked for the session:

- **Overheating** — ends sessions once the Mac is genuinely throttling.
  Tighter with the lid closed.
- **Battery** — ends sessions below your chosen percentage. Also tighter with
  the lid closed.
- **Maximum duration** — a backstop for the session you started and forgot,
  eight hours by default. **It spends battery time, not wall clock**: a Mac on
  mains is never stopped by it, and plugging in pauses the budget rather than
  refunding it. That's what lets `keepy-uppy on` mean what it says on a desk or
  a rack, while a laptop that walks off with a session still running is still
  caught.

When a guard fires it suppresses *automatic* restarts for a cooldown, so a
trigger can't fight it in a loop. Manual starts are always honoured — that's
your call to make.

The rule underneath it all: **no session outlives its evidence.** A timed
session ends on its clock. A condition-based one ends when the condition ends —
or when the process watching it disappears. An indefinite one runs until you
say otherwise, or until it has spent its backstop budget on battery. And the
daemon forces sleep back on at startup and if the app is deleted, so nothing
can strand your Mac awake.

## How it's built

Four executables, split by privilege:

| | runs as | does |
|---|---|---|
| `KeepyUppyHelper` | root `LaunchDaemon` | owns the power state; enforces every guard |
| `KeepyUppyAgent` | per-user `LaunchAgent` | watches what only a login session can see |
| `keepy-uppy` | you | the command line |
| `Keepy Uppy.app` | you | optional menu bar |

Only the daemon touches power state. Everything else asks over XPC.

**The XPC boundary is the design.** Each client role gets its own Mach service,
and each service pins a code-signing requirement admitting exactly one bundle
identifier. A caller's role isn't asserted by the caller and isn't looked up
from its PID — which would be a TOCTOU race, since PIDs get recycled between
accepting a connection and inspecting it. Role falls out of *which service
accepted the connection*, decided atomically by the OS.

Identity works the same way: `"<role>-<uid>"`, from the accepting listener plus
the peer's authenticated uid. Both are facts the daemon knows and the client
can't influence — which is how `keepy-uppy off` stops the session an earlier
`keepy-uppy on` started, while still refusing to touch another client's or
another user's.

**Where a behaviour lives follows from who enforces it.** The daemon serves
every logged-in user, so anything the daemon has to act on travels on the
session itself — which is why the wake mode and the disk switch are fields on a
session and not settings. A preference is for what a per-user process does with
it; it isn't something the daemon could ever see, let alone enforce.

The session and safety engines are pure reducers — `(state, event, now) →
state`, with time injected rather than read. An eight-hour session is tested in
a millisecond, which is why most of the logic inside a root daemon is covered
by **1021 unit tests**.

## Build it yourself

```sh
brew install xcodegen just
just test
just run
```

A Debug build can't talk to the daemon — signing enforcement is compiled out,
and the daemon refuses unauthenticated connections rather than quietly
accepting them. For the real thing you need a Developer ID certificate:

```sh
export KEEPY_UPPY_SIGNING_IDENTITY="Developer ID Application: You (TEAMID)"
export KEEPY_UPPY_TEAM_ID="TEAMID"
export KEEPY_UPPY_NOTARY_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8"
export KEEPY_UPPY_NOTARY_KEY_ID="XXXXXXXXXX"
export KEEPY_UPPY_NOTARY_ISSUER="your-issuer-uuid"
just notarize
```

An App Store Connect API key, rather than `notarytool`'s stored keychain
profile, because the profile has a failure mode worth avoiding: it can read
back stale or missing even when it worked an hour earlier, and when it does,
every call answers `HTTP 401 Invalid credentials … use the app-specific
password generated at appleid.apple.com`. That sentence sends you off to
rotate a password that was never the problem. `KEEPY_UPPY_NOTARY_PROFILE`
still works if you have one — it's just the second choice.

## Status

**v0.1 — new, and moving fast.** Signed and notarized, 1021 tests, and a
privilege boundary that has been through three adversarial review passes. What
it has not had is months on other people's hardware.

Verified on a real machine rather than only in tests: closed-lid behaviour over
a real job, checked against macOS's own sleep/wake log; a VPN dropping under a
live session; the disk-awake assertion; and changing a running session's mode
against an installed background service.

**Four things are still covered only as far as a test process can reach** — the
thermal and battery guards actually firing, a USB device appearing, a keyboard
shortcut arriving, and a notification appearing on screen. Each is designed for
and tested; none has been watched happen.
[`docs/manual-test-checklist.md`](docs/manual-test-checklist.md) is the list of
what only hardware can settle, and it is kept honest as things are ticked off.

[Releases](../../releases) has **v0.1.6**, which is what this page describes.

If something misbehaves, an issue with the daemon log is genuinely useful:

```sh
log show --predicate 'subsystem BEGINSWITH "au.com.workwireless.keepy-uppy"'
```

Settings → CLI & Advanced has a Copy button for that command, with the app's
version and the running daemon's beside it — the pair worth quoting, since they
can legitimately differ until the Mac is restarted.

## License

MIT — see [LICENSE](LICENSE).
