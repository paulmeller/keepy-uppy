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

## The whole CLI

```sh
keepy-uppy on                                # until you say otherwise (see the backstop)
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
keepy-uppy on --while-schedule 'weekdays 09:00-18:00'  # until the window closes
keepy-uppy off                               # stop yours
keepy-uppy off --all                         # stop everything
keepy-uppy mode --session <id>               # change a running session, see below
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

### Changing your mind, without restarting the session

```sh
keepy-uppy sessions                                   # find the id
keepy-uppy mode --session <id>                        # lid can be shut
keepy-uppy mode --session <id> --display-may-sleep    # lid open only
keepy-uppy mode --session <id> --keep-disks-awake     # …and hold the disks
```

`mode` sets a **running** session's whole request, which matters because
stopping and starting one is not the same thing: a `--while-volume` session
restarted is a new session that won't end when the *original* drive goes, and a
timed one starts its clock again.

It takes exactly the flags `on` takes, and they mean exactly what they mean
there — including when you leave one out. `mode --session <id>` with no flags
sets the lid-closed mode and stops holding disks awake, because it sets the
whole request rather than editing the one axis you mentioned. That's the same
rule as `on` and it bites harder here, so `keepy-uppy mode` with no flags is
worth reading twice.

You can change sessions **you** started from a terminal; sessions started from
the menu bar are the menu bar's, exactly as with `off --session`. The menu has a
row of its own for this, on any of its sessions that gave up the closed lid.

If the background service on this Mac is older than this build, `mode` says so
and changes nothing — restart the Mac to pick up the new one, or stop the
session and start a fresh one.

One more flag, on an axis of its own — it combines with any wake mode and any
`--while-…`:

```sh
keepy-uppy on --for 8h --keep-disks-awake    # …and keep attached disks spun up
```

It holds off macOS's spin-down timer for as long as the session runs, so an
external drive doesn't park itself in the middle of a backup. It's system-wide
rather than per-drive — there's no per-device version of it in the API at all —
and it can't overrule an enclosure that decides for itself when to spin down. A
disk already parked when the session starts stays parked. And if this Mac's
background service is older than the app — which it is after an update, until
you restart — it drops the request rather than failing it: the session runs, the
disks don't stay awake, and the menu is where that's owned up to.

**Network shares aren't covered, and can't be.** macOS offers nothing at any
layer that says "keep this SMB or AFP mount alive"; the only thing that works
is touching a file on the share every few minutes, which needs a Files and
Folders permission for a feature whose whole point is running while you're
away. So the flag means disks attached to this Mac, and nothing here pretends
otherwise.

The same switch sits under the mode picker on the Display tab, for the sessions
you start from the menu. A trigger ignores both of those and carries its own
answer, picked in the sheet that adds it — and the answer it starts with is the
one every trigger used to give unconditionally: keep this Mac awake with the lid
closed, and don't ask for disks. So a rule you saved before either axis existed
still does exactly what it always did.

**It can't stop your Mac asking for a password.** macOS only lets a
configuration profile change when the lock kicks in, and an app isn't allowed to
install one — the setting is yours to change in System Settings → Lock Screen.

CLI sessions outlive the shell that started them. Menu-bar sessions end when
you quit the app. That's deliberate — one is for automation, the other is for
you.

## Or don't type anything at all

Settings → Triggers turns a condition into a standing rule, so the Mac starts
keeping itself awake without you remembering to ask. Ten conditions, and they
fall into two groups that behave differently — which is the thing worth knowing
before you write a rule.

**Six start out holding a session open for exactly as long as the condition
lasts:** a process is running, a volume is mounted, this Mac is on a given
network, a VPN is connected, a USB device is attached, or the clock is inside a
recurring window you set — "weekdays, 09:00 to 18:00". Eject the drive, drop the
tunnel or unplug the dongle and the session goes with it, the same way
`--while-…` does from the command line.

**Four start out as a starting gun:** an app launches, an app comes to the
front, an external display connects, power is connected. The condition fires the
session; the session then runs for the duration you picked on the rule, and
unplugging the display doesn't end it.

Those are only where each rule *starts*. The Add sheet asks "Keep awake: while
it lasts, or for a set time?", so a volume rule can run for four hours and — new
here — a display, power or app-launch rule can hold the Mac awake until you
unplug, unplug, or quit. The defaults are what they are because of rules people
have already saved: a display rule somebody wrote last year means "start four
hours when I dock", and quietly turning it into "…and stop when I undock" would
change what their Mac does without them asking. Changing your own rule is a
different thing entirely.

The one condition that is *not* offered the choice is "an app comes to the
front", and that is deliberate rather than unfinished. Frontmost changes the
instant you glance at a browser window, so a session bound to it would end
because you looked away for ten seconds — worse than no session. The durable
version is "an app launches" with "while it lasts", which is exactly what the
sheet now offers.

The same sheet asks the other question a trigger could never answer for itself:
what it holds awake. A rule can pick any of the three wake modes and can hold
attached disks out of idle, instead of every trigger silently getting
lid-closed-and-no-disks. Leave both alone and that is still what you get.

**A rule that uses either of those two controls can't be read by an older Keepy
Uppy**, and that's worth knowing before you write one. Rules you leave alone are
stored exactly as they always were, so every build reads them — that's the
design, and it's what keeps a downgrade cheap. A rule that picks its own mode or
its own lifetime is stored differently, and what an older build does with it
depends on how old. Any build from `main` since the extra trigger conditions
arrived keeps it, hides it and counts it in the Triggers pane — *"1 trigger was
created by a newer version of Keepy Uppy … it has been kept"* — and hands it
straight back the moment you run the newer build again. **The download has none
of that machinery:** it shows no rules at all, and writes over them the next
time anything in that pane changes. That's already true of any rule using one of
the six conditions it never knew about, so it isn't a new hazard — but it's a
real one, and it's what a per-rule effect costs.

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

## The menu bar

It's the whole interface for most people, and it's where you watch what's
running — nothing here requires the terminal at all. The menu lists every live
session, and each row says where its session came from: you started it, one of
your own rules started it automatically, it came from a terminal, or it belongs
to another account on this Mac.

**A session your own rule started has a Stop button.** So does one you started
here. The daemon otherwise scopes every stop to the client that asked — that's
what stops one client ending another's work — and the one exception is this: the
app may end a session started by *your own* trigger rules, on this account. It
can't end one from `keepy-uppy on` (that's your terminal's, and `keepy-uppy off`
ends it), it can't end another account's anything, and it can't extend anything
it didn't start. Switching a rule off doesn't end a session it has already
started; stopping the session does.

**It can still show you a session it can't stop.** A `keepy-uppy on` session of
yours, and another account's sessions, are listed without a Stop button. End
your own with `keepy-uppy off`, or let the condition or the duration end them.

**One row changes a session instead of ending it.** A session of yours that gave
up the closed lid — the ones tagged "lid open only" — gets a second row that
switches it back, without restarting it. It only ever goes that way: switching
*to* the lid-closed mode can't cost you anything, and switching away from it by
a stray click can. `keepy-uppy mode` goes both ways, and it's also where to
change a session that's holding the screen on, since no single mode both holds
the screen and survives a shut lid.

**Three notifications, all off until you turn one on:** when nothing of yours is
keeping this Mac awake any more, when a trigger starts a session, and when a
safety guard stops your sessions. The app is what announces them, so a session
that ends while it's quit ends without a word. Stopping a session yourself in
the menu is never announced — you were there — but stopping one with
`keepy-uppy off` in a terminal is, because from the app that looks exactly like
a session expiring.

**The third one names the guard** — too hot, low battery, or the time limit —
and short of reading the daemon log it's the only place you're ever told *why* a
session ended. **A reason isn't always available**, and you're told so rather
than handed a guess: the daemon remembers a stop for five minutes and no
longer, a background service older than the app can't be asked for one at all,
and an ending no guard was behind has none to give. In each of those you get
the plain notice instead, if that one is switched on. A reason is matched to
the exact sessions that ended and never to whatever happened to end around the
same time, so a guard stopping one session while another expires on its own
clock is reported as neither.

**Two global keyboard shortcuts**, needing no permission of any kind: one
starts the session the menu's first row starts, the other stops the sessions
you started from the menu — only those, so a trigger's session and a
`keepy-uppy on` session keep running. That's deliberate, and it's narrower than
the menu: a trigger's session has its own Stop button up there, one at a time,
because a keystroke pressed inside another app shows you nothing and shouldn't
sweep away something you didn't name. macOS won't tell an app that another app
already owns a combination, so a shortcut that never fires is almost always one
that's already taken; pick another.

**It's in Shortcuts.** Three actions — keep awake for a chosen duration, stop
the sessions this app started, and ask whether anything is holding this Mac
awake — so a session can be a step in an Automation, a Focus filter or a
Shortcut you run from anywhere. They need no permission of any kind, and they
run as the app: a session a Shortcut starts appears in the menu with a Stop
button, and the stop shortcut ends it, exactly as if you had clicked the row.

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
by **1018 unit tests**.

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

**v0.1 — new, and moving fast.** Signed and notarized, 1018 tests, and a
privilege boundary that's been through three adversarial review passes. What
it hasn't had yet is months on other people's hardware. Closed-lid behaviour
over a real job is verified — a live session was watched surviving a genuine
lid close on real hardware, confirmed against macOS's own sleep/wake log
rather than taken on faith — but six other claims above have not:

- the thermal and battery guards actually firing;
- a VPN going *down* under a live session (there was exactly one VPN on the Mac
  this was written on and it was already up; planting a fake one needs root);
- a USB device appearing at all — nothing is plugged into that Mac, so the
  enumeration was verified against zero devices;
- a keyboard shortcut arriving: from inside the process, a registration that
  works and one the window server will never deliver to are the same `noErr`,
  so only a human pressing the key settles it;
- a notification appearing on screen — nothing here has ever asked for the
  grant that would let one, so the banner naming the guard that stopped your
  sessions has never been read off a real screen either;
- the newest session controls against a real background service: stopping a
  trigger's session from the menu, changing a running session's mode, and a rule
  carrying its own wake mode and lifetime. Each is covered by tests and by XPC
  round trips against a listener built for them, and none has been run against
  an installed service — the one on the machine this was written on is older
  than the requests it would have to answer.

All six are designed for and covered as far as a test process can reach, which
is not the same thing.
[`docs/manual-test-checklist.md`](docs/manual-test-checklist.md) is the list of
what only hardware can settle.

**This page describes the current download.** [Releases](../../releases) has
**v0.1.5**, and everything above is in it: all ten trigger conditions
including the scheduled one, the Shortcuts actions, wake modes,
`--keep-disks-awake`, `keepy-uppy mode`, per-rule wake mode and lifetime, the
five-tab Settings window with search, notifications, keyboard shortcuts, the
`PATH` install button, and the battery-time session backstop.

An earlier **v0.1.0** is also on Releases, for anyone who wants the smaller,
first-notarized build: `--for`, `--until`, `--while-app`, and three trigger
conditions only — none of the AI-coding-agent wiring, wake modes, or anything
else added since.

If something misbehaves, an issue with the daemon log is genuinely useful:

```sh
log show --predicate 'subsystem BEGINSWITH "au.com.workwireless.keepy-uppy"'
```

Settings → CLI & Advanced has a Copy button for that command, with the app's
version and the running daemon's beside it — the pair worth quoting in the
issue, since they can legitimately differ until the Mac is restarted.

## License

MIT — see [LICENSE](LICENSE).
