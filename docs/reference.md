# Reference

Everything the [README](../README.md) summarises, in full: every command and
flag, all ten trigger conditions and how they differ, and what each row of the
menu means.

It is a separate page because a README's job is to get somebody running in two
minutes, and this is the part you come back to afterwards — with the caveats
intact, because the caveats are the useful half.

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

