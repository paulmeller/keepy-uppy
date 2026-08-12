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
menu bar is optional. Every session, every guard and every trigger is reachable
from a script, from CI, from a Shortcut and over SSH — because the CLI talks to
the same daemon the UI does.

```sh
ssh mac-mini 'zsh -lc "keepy-uppy on --for 8h"'
```

The login shell isn't decoration. A command sent over `ssh` runs in a non-login
shell whose `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, so a bare `keepy-uppy`
isn't found there no matter where you installed it. Ask for a login shell, as
above, or give the full path to the binary inside the app bundle.

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

To type `keepy-uppy` instead of all that, Settings → CLI & Advanced links it
into `/usr/local/bin`. That directory is root-owned on a stock Mac, so the
button usually can't do it for you — it hands you the one `sudo` command that
can, with the space in "Keepy Uppy.app" already quoted, for you to read and
paste yourself. Every verb works through the link except `setup` and `reset`:
those two have to find the app bundle they were started from, a link on your
`PATH` isn't inside one, and they refuse there rather than report an uninstall
that didn't happen.

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
keepy-uppy on --while-volume Backup          # until that drive is ejected
keepy-uppy on --while-subnet 192.168.1.0/24  # until you leave that network
keepy-uppy on --while-vpn                    # until the tunnel drops
keepy-uppy on --while-usb 05ac:024f          # until that device is unplugged
keepy-uppy off                               # stop yours
keepy-uppy off --all                         # stop everything
keepy-uppy status --json                     # {"keepingAwake": true}
keepy-uppy sessions
```

Every `--while-…` session lasts exactly as long as the thing it names, and two
things are checked before one starts rather than left to end it a tick later.
`--while-ac-power` wants the charger actually in. Every other `--while-…` wants
the per-user agent running, since a daemon with no login session can't see a
screen, a CPU, a volume, an address, a tunnel or a USB port.

`--while-cpu-busy` takes a whole percentage from 1 to 99 and needs two solid
minutes below it before it gives up — a lull between test runs won't end your
session. `--while-subnet` takes an address or a block, and matches Ethernet as
happily as Wi-Fi, so docking doesn't end it. `--while-usb` takes the vendor and
product ID `system_profiler SPUSBDataType` prints. `--while-vpn` sees any VPN
macOS itself knows about — System Settings, Tailscale, Cloudflare WARP, a work
client — but not a `wg-quick` or bare `openvpn` tunnel, which macOS never
models as a VPN at all.

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
every other respect. Settings → Display picks the mode for sessions you start
from the menu bar.

One more flag, on an axis of its own — it combines with any wake mode and any
`--while-…`:

```sh
keepy-uppy on --for 8h --keep-disks-awake    # …and keep attached disks spun up
```

It holds off macOS's spin-down timer for as long as the session runs, so an
external drive doesn't park itself in the middle of a backup. It's system-wide
rather than per-drive — there's no per-device version of it in the API at all —
and it can't overrule an enclosure that decides for itself when to spin down. A
disk already parked when the session starts stays parked.

**Network shares aren't covered, and can't be.** macOS offers nothing at any
layer that says "keep this SMB or AFP mount alive"; the only thing that works
is touching a file on the share every few minutes, which needs a Files and
Folders permission for a feature whose whole point is running while you're
away. So the flag means disks attached to this Mac, and nothing here pretends
otherwise.

The same switch sits under the mode picker on the Display tab, for the sessions
you start from the menu. A trigger's session always keeps this Mac awake with
the lid closed and never asks for disks, so a rule you saved before either axis
existed still does exactly what it always did.

**It can't stop your Mac asking for a password.** macOS only lets a
configuration profile change when the lock kicks in, and an app isn't allowed to
install one — the setting is yours to change in System Settings → Lock Screen.

*All three flags, the picker and that switch are on `main` only — the current
download predates them. See [Status](#status).*

CLI sessions outlive the shell that started them. Menu-bar sessions end when
you quit the app. That's deliberate — one is for automation, the other is for
you.

## Or don't type anything at all

Settings → Triggers turns a condition into a standing rule, so the Mac starts
keeping itself awake without you remembering to ask. Nine conditions, and they
fall into two groups that behave differently — which is the thing worth knowing
before you write a rule.

**Five hold a session open for exactly as long as the condition lasts:** a
process is running, a volume is mounted, this Mac is on a given network, a VPN
is connected, a USB device is attached. Eject the drive, drop the tunnel or
unplug the dongle and the session goes with it, the same way `--while-…` does
from the command line.

**Four are a starting gun:** an app launches, an app comes to the front, an
external display connects, power is connected. The condition fires the session;
the session then runs for the duration you picked on the rule, and unplugging
the display doesn't end it.

The split isn't waiting to be finished. "While this app is frontmost" sounds
coherent and isn't — frontmost changes the instant you glance at a browser
window, and a session that ends because you looked away for ten seconds is
worse than no session; the durable version is `--while-app`, and it's already
there. The display and power conditions could bind and deliberately don't,
because rules people have already saved mean "start four hours when I dock",
and quietly turning those into "…and stop when I undock" would change what
somebody's Mac does without them asking for it.

There's no Wi-Fi-network trigger and no Bluetooth-device one, and that's also a
decision. Each needs a privacy grant that a background agent with no window can
never obtain, and a refused grant doesn't produce an error — it produces a rule
that looks right and silently never fires. The network condition covers the
same "while I'm at the office" intent by address block instead, with no
permission at all, and it keeps working when you dock to Ethernet, which a
network name never could.

Which leaves something worth saying out loud: **nothing in Keepy Uppy needs a
privacy permission to work.** No Location, no Bluetooth, no Accessibility,
nothing to grant per-trigger — every trigger, every session and the whole
command line run without a single one. Exactly one optional feature asks for
anything: switching on a notification is what raises macOS's notification
prompt, at that moment and nowhere else, and saying no to it costs you the
notifications and nothing else. The one thing macOS asks you to approve to
*use* Keepy Uppy is still the pair of background Login Items, once, when you
enable it.

*Six of those nine conditions are on `main` only — the current download has
three. See [Status](#status).*

## The menu bar, if you want one

The app is optional, and it's where you watch what's running. The menu lists
every live session, and each row says where its session came from: you started
it, one of your own rules started it automatically, it came from a terminal, or
it belongs to another account on this Mac.

**It can show you a session it can't stop.** This app only ends sessions it
started itself — the daemon scopes every stop to the client that asked, which
is what stops one client ending another's work — so a session your own trigger
started has no Stop button, and neither does one from `keepy-uppy on`. End
those with `keepy-uppy off --all`, or let the condition or the duration end
them. Switching a rule off doesn't end a session it has already started.

**Two notifications, both off until you turn one on:** when nothing of yours is
keeping this Mac awake any more, and when a trigger starts a session. The app
is what announces them, so a session that ends while it's quit ends without a
word. Stopping a session yourself in the menu is never announced — you were
there — but stopping one with `keepy-uppy off` in a terminal is, because from
the app that looks exactly like a session expiring. And no notification ever
says *why* a session ended: only the daemon knows that, and it doesn't tell
anyone yet.

**Two global keyboard shortcuts**, needing no permission of any kind: one
starts the session the menu's first row starts, the other stops the sessions
you started from the menu — only those, so a trigger's session and a
`keepy-uppy on` session keep running. macOS won't tell an app that another app
already owns a combination, so a shortcut that never fires is almost always one
that's already taken; pick another.

*Notifications, the shortcuts and the Install button are on `main` only — the
current download has none of them. See [Status](#status).*

## Safety, in detail

Configurable in Settings → Safety & Guards, and enforced by the daemon
regardless of which client asked for the session:

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

**Where a behaviour lives follows from who enforces it.** The daemon serves
every logged-in user, so anything the daemon has to act on travels on the
session itself — which is why the wake mode and the disk switch are fields on a
session and not settings. A preference is for what a per-user process does with
it; it isn't something the daemon could ever see, let alone enforce.

The session and safety engines are pure reducers — `(state, event, now) →
state`, with time injected rather than read. An eight-hour session is tested in
a millisecond, which is why most of the logic inside a root daemon is covered
by **791 unit tests**.

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

**v0.1 — new, and moving fast.** Signed and notarized, 791 tests on `main`, and
a privilege boundary that's been through three adversarial review passes. What
it hasn't had yet is months on other people's hardware, and six claims above
have never been watched happen on a real machine:

- closed-lid behaviour over a long job — the headline claim;
- the thermal and battery guards actually firing;
- a VPN going *down* under a live session (there was exactly one VPN on the Mac
  this was written on and it was already up; planting a fake one needs root);
- a USB device appearing at all — nothing is plugged into that Mac, so the
  enumeration was verified against zero devices;
- a keyboard shortcut arriving: from inside the process, a registration that
  works and one the window server will never deliver to are the same `noErr`,
  so only a human pressing the key settles it;
- a notification appearing on screen — nothing here has ever asked for the
  grant that would let one.

All six are designed for and covered as far as a test process can reach, which
is not the same thing.
[`docs/manual-test-checklist.md`](docs/manual-test-checklist.md) is the list of
what only hardware can settle.

**Most of this page is `main`, not the download.** The build on
[Releases](../../releases) is **v0.1.0**, and `main` is more than sixty commits
past it — its own notes say 182 tests. It knows `--for`, `--until`,
`--while-app` and three trigger conditions, and that is the lot: no
`--while-process` and no `keepy-uppy finished`, so none of the AI-coding-agent
wiring above; no wake modes, no `--keep-disks-awake`, and neither of the
Settings controls that go with them; and none of
`--while-display`, `--while-ac-power`, `--while-cpu-busy`, `--while-volume`,
`--while-subnet`, `--while-vpn` or `--while-usb`, nor the six trigger
conditions that arrived with them. Its Settings window has three tabs rather
than five, and none of the app's newer surfaces: no notifications, no keyboard
shortcuts, and no button to put `keepy-uppy` on your `PATH`. Nothing since has
been notarized into a release, so build it yourself if you want any of it now.

If something misbehaves, an issue with the daemon log is genuinely useful:

```sh
log show --predicate 'subsystem BEGINSWITH "au.com.workwireless.keepy-uppy"'
```

Settings → CLI & Advanced has a Copy button for that command, with the app's
version and the running daemon's beside it — the pair worth quoting in the
issue, since they can legitimately differ until the Mac is restarted.

## License

MIT — see [LICENSE](LICENSE).
