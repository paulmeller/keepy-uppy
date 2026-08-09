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

**It's a command line first, an app second.** The daemon is the product. The
menu bar is optional. Everything works over SSH, from a script, from CI, from a
Shortcut — because the CLI talks to the same daemon the UI does.

```sh
ssh mac-mini 'keepy-uppy on --for 8h'
```

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
| Cursor CLI | ✅ | *(no session-end hook upstream yet)* |

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

Grab the notarized `.dmg` from [Releases](../../releases), drag it to
`/Applications`, open it, and hit **Enable Keepy Uppy**. macOS asks you to
approve the background services once. That's it.

Headless box that'll never run the app?

```sh
"/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy" setup
```

## The whole CLI

```sh
keepy-uppy on                                # until you say otherwise
keepy-uppy on --for 2h
keepy-uppy on --until 17:00
keepy-uppy on --while-app com.apple.dt.Xcode # until Xcode quits
keepy-uppy on --while-process claude         # until the process exits
keepy-uppy on --while-display                # until the external screen is unplugged
keepy-uppy on --while-ac-power               # until the charger comes out
keepy-uppy on --while-cpu-busy 30            # until the CPU drops under 30% for 2 min
keepy-uppy off                               # stop yours
keepy-uppy off --all                         # stop everything
keepy-uppy status --json                     # {"keepingAwake": true}
keepy-uppy sessions
```

The last three end when something stops being true, so they are refused up
front when it already isn't: `--while-ac-power` wants the charger in when you
start, and `--while-display` and `--while-cpu-busy` want the per-user agent
running, since a daemon with no login session can see neither a screen nor a
CPU. `--while-cpu-busy` takes a whole percentage from 1 to 99, and needs two
solid minutes below it before it gives up — a lull between test runs won't end
your session.

`on` also takes one flag saying *how* awake, and it combines with any of the
above:

```sh
keepy-uppy on --for 8h                       # lid can be shut (the default)
keepy-uppy on --for 8h --display-may-sleep   # lid open only
keepy-uppy on --for 8h --keep-display-awake  # lid open only, screen stays lit
```

**Only the default survives a lid close**, and that is the entire difference
between it and `--display-may-sleep`: both leave your screen free to go dark on
its usual idle timer. `--keep-display-awake` reads like the strongest of the
three and isn't — it adds a lit screen and gives up the closed lid just the
same. Neither name says so, which is why `on` says it on stderr the moment you
type one: a session in either mode does not keep this Mac awake with the lid
closed.

Sessions combine rather than compete, and the strongest request wins, so a
`--display-may-sleep` session running beside a default one doesn't make the Mac
unsafe to shut. The lid-closed guarantee lasts exactly as long as the last
default session does. `keepy-uppy sessions` prints every live session's mode,
and the menu bar tags the ones that aren't holding the lid.

Pick the default for a headless box or a docked laptop you'll shut; pick a flag
when the Mac is open in front of you and you'd rather it behaved normally in
every other respect. Settings → General picks the mode for sessions you start
from the menu bar.

*Both flags and that picker are on `main` only — the current download predates
them. See [Status](#status).*

CLI sessions outlive the shell that started them. Menu-bar sessions end when
you quit the app. That's deliberate — one is for automation, the other is for
you.

## Safety, in detail

Configurable in Settings → Safety, and enforced by the daemon regardless of
which client asked for the session:

- **Overheating** — ends sessions once the Mac is genuinely throttling.
  Tighter with the lid closed.
- **Battery** — ends sessions below your chosen percentage. Also tighter with
  the lid closed.
- **Maximum duration** — a backstop for the session you started and forgot.

When a guard fires it suppresses *automatic* restarts for a cooldown, so a
trigger can't fight it in a loop. Manual starts are always honoured — that's
your call to make.

The rule underneath it all: **no session outlives its evidence.** A timed
session ends on its clock. A condition-based one ends when the condition ends —
or when the process watching it disappears. An indefinite one hits the
backstop. And the daemon forces sleep back on at startup and if the app is
deleted, so nothing can strand your Mac awake.

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

The session and safety engines are pure reducers — `(state, event, now) →
state`, with time injected rather than read. An eight-hour session is tested in
a millisecond, which is why most of the logic inside a root daemon is covered
by **370 unit tests**.

Full design rationale, including the roads not taken:
[`docs/superpowers/specs/`](docs/superpowers/specs/).

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
export KEEPY_UPPY_NOTARY_PROFILE="your-notarytool-profile"
just notarize
```

## Status

**v0.1 — new, and moving fast.** Signed and notarized, 387 tests on `main`, and
a privilege boundary that's been through three adversarial review passes. What
it hasn't had yet is months on other people's hardware — and two claims above
are still unverified there specifically: closed-lid behaviour on real hardware
over a long job, and the thermal and battery guards actually firing. Both are
designed for and covered as pure logic; neither has been watched happen on a
machine in a bag.

The build on [Releases](../../releases) is **v0.1.0**, cut before wake modes
existed — no `--display-may-sleep`, no `--keep-display-awake`, no picker in
Settings, and none of `--while-display`, `--while-ac-power` or
`--while-cpu-busy`. Those are on `main` and haven't been notarized into a
release yet, so build it yourself if you want them now.

If something misbehaves, an issue with the daemon log is genuinely useful:

```sh
log show --predicate 'subsystem BEGINSWITH "au.com.workwireless.keepy-uppy"'
```

## License

MIT — see [LICENSE](LICENSE).
